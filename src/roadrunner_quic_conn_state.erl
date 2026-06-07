-module(roadrunner_quic_conn_state).
-moduledoc false.

%% The pure decision core of the native QUIC connection (RFC 9000/9001).
%%
%% `roadrunner_quic_connection` is the thin proc_lib shell that owns the
%% socket, timers, and message loop; this module owns the whole `#state{}`
%% and every decision. Each entry takes the wall-clock `Now` (ms) and a
%% message and returns `{NewState, [effect()]}` for the shell to perform.
%% Keeping the brain pure (recv/send/crypto all run here, since the leaves
%% are pure) is what makes the connection eunit-reachable for the 100%
%% gate; the shell only does the irreducible I/O.
%%
%% Effects: `{send, Datagram}` (hand to the socket), `{arm_timer, Kind,
%% AtMs}` ((re)arm a timer). The owner events and control replies arrive
%% with the application phase.
%%
%% A connection keeps up to three packet-number spaces (Initial, Handshake,
%% Application). The server reads with the peer's keys and writes with its
%% own; CRYPTO is reassembled per space (a `roadrunner_quic_stream` with no
%% FIN). Initial state is discarded once a Handshake packet decrypts and
%% Handshake state once the handshake is confirmed (RFC 9001 §4.9), which
%% also keeps the send pass from ever coalescing an Initial with a 1-RTT
%% packet. The send pass collects, per space in order, an ACK frame, the
%% TLS flight / retransmits, and (at Application) HANDSHAKE_DONE, packs them
%% with `roadrunner_quic_send`, gates the datagram against the §8.1
%% anti-amplification budget, and records each sent packet for loss
%% recovery.
%%
%% Congestion control is deferred (the connection sends within the
%% anti-amplification and flow limits, the MUSTs); wiring NewReno needs the
%% loss layer to surface acked bytes / sent times, a separate follow-up.

-export([new/1, handle_datagram/3, handle_timeout/3, peername/1, phase/1]).

-export_type([t/0, config/0, effect/0]).

%% RFC 9000 §17.2: the server uses a fixed-length SCID so short headers demux.
-define(SCID_LEN, 8).
%% A CRYPTO slice budget that leaves room for the packet header, an ACK
%% frame, and the AEAD tag within the 1200-byte datagram (RFC 9000 §14).
-define(CRYPTO_BUDGET, 1000).
%% TLS handshake message types carried in CRYPTO (RFC 8446 §4).
-define(CLIENT_HELLO, 1).
-define(FINISHED, 20).

-type level() :: initial | handshake | application.

-record(space, {
    ack :: roadrunner_quic_ack:t(),
    loss :: roadrunner_quic_loss:t(),
    next_pn = 0 :: non_neg_integer(),
    %% CRYPTO reassembly + send buffering for this space (FIN unused).
    crypto :: roadrunner_quic_stream:t(),
    %% Contiguous CRYPTO bytes received but not yet deframed.
    crypto_in = <<>> :: binary(),
    %% Frames to (re)send: losses to retransmit, plus queued control frames.
    pending = [] :: [roadrunner_quic_frame:frame()]
}).

-record(state, {
    dcid :: binary(),
    scid :: binary(),
    peer :: {inet:ip_address(), inet:port_number()},
    phase = handshaking :: handshaking | connected | draining | closed,
    tls :: roadrunner_quic_tls_server:t(),
    %% Keys to decrypt incoming packets (the peer's), by level.
    recv_keys :: #{level() => roadrunner_quic_keys:keys()},
    %% Keys to protect outgoing packets (the server's), by level.
    send_keys :: #{level() => roadrunner_quic_keys:keys()},
    spaces :: #{level() => #space{}},
    amp :: roadrunner_quic_amp:t(),
    %% Cleared once a Handshake packet decrypts (address validated, §8.1).
    validated = false :: boolean()
}).

-opaque t() :: #state{}.

-type config() :: #{
    dcid := binary(),
    scid := binary(),
    peer := {inet:ip_address(), inet:port_number()},
    cert_chain := [binary()],
    priv_key := public_key:private_key(),
    alpn := binary(),
    transport_params := roadrunner_quic_transport_params:params(),
    eph_pub := binary(),
    eph_priv := binary(),
    server_random := binary()
}.

-type effect() :: {send, binary()} | {arm_timer, atom(), non_neg_integer()}.

%% =============================================================================
%% Construction
%% =============================================================================

-doc """
Build the connection state from the per-connection config. Bootstraps the
Initial keys from the client's Destination Connection ID, the TLS server
sequencer (the server transport parameters already carry the
original/initial connection ids), and the Initial and Handshake
packet-number spaces (the Application space appears once 1-RTT keys arm).
""".
-spec new(config()) -> t().
new(#{
    dcid := DCID,
    scid := SCID,
    peer := Peer,
    cert_chain := CertChain,
    priv_key := PrivKey,
    alpn := Alpn,
    transport_params := TransportParams,
    eph_pub := EphPub,
    eph_priv := EphPriv,
    server_random := ServerRandom
}) ->
    Tls = roadrunner_quic_tls_server:new(#{
        cert_chain => CertChain,
        priv_key => PrivKey,
        alpn => Alpn,
        transport_params => TransportParams,
        eph_pub => EphPub,
        eph_priv => EphPriv,
        server_random => ServerRandom
    }),
    #state{
        dcid = DCID,
        scid = SCID,
        peer = Peer,
        tls = Tls,
        recv_keys = #{initial => roadrunner_quic_keys:initial_client(DCID)},
        send_keys = #{initial => roadrunner_quic_keys:initial_server(DCID)},
        spaces = #{initial => new_space(), handshake => new_space()},
        amp = roadrunner_quic_amp:new()
    }.

-spec new_space() -> #space{}.
new_space() ->
    #space{
        ack = roadrunner_quic_ack:new(),
        loss = roadrunner_quic_loss:new(#{}),
        crypto = roadrunner_quic_stream:new()
    }.

-doc "The peer address, answerable from the handshaking phase onward.".
-spec peername(t()) -> {ok, {inet:ip_address(), inet:port_number()}}.
peername(#state{peer = Peer}) ->
    {ok, Peer}.

-doc "The connection's current phase.".
-spec phase(t()) -> handshaking | connected | draining | closed.
phase(#state{phase = Phase}) ->
    Phase.

%% =============================================================================
%% Inbound datagram
%% =============================================================================

-doc """
Process one received UDP datagram: account it against the anti-
amplification budget, decode and decrypt its packets, fold each packet's
frames into the connection state, then run a send pass. Returns the new
state and the effects to perform.
""".
-spec handle_datagram(non_neg_integer(), binary(), t()) -> {t(), [effect()]}.
handle_datagram(Now, Datagram, #state{amp = Amp, recv_keys = RecvKeys} = State0) ->
    State1 = State0#state{amp = roadrunner_quic_amp:received(byte_size(Datagram), Amp)},
    Outcomes = roadrunner_quic_recv:datagram(
        Datagram, ?SCID_LEN, RecvKeys, largest_map(State1)
    ),
    State2 = lists:foldl(fun(O, S) -> process_outcome(Now, O, S) end, State1, Outcomes),
    send_pass(Now, State2).

-spec process_outcome(non_neg_integer(), roadrunner_quic_recv:outcome(), t()) -> t().
process_outcome(
    Now, {ok, #{level := Level, pn := PN, frames := Frames}}, #state{spaces = Spaces} = State
) ->
    case Spaces of
        #{Level := _} ->
            State1 = validate_on_handshake(Level, State),
            State2 = lists:foldl(
                fun(Frame, S) -> process_frame(Now, Level, Frame, S) end, State1, Frames
            ),
            record_received(Level, PN, Frames, State2);
        #{} ->
            %% A packet for a discarded space (e.g. a late Initial); ignore.
            State
    end;
process_outcome(_Now, {drop, _Reason}, State) ->
    State;
process_outcome(_Now, {frame_error, _Level, _Reason}, State) ->
    State.

%% A decrypted Handshake packet proves the client received the server's
%% Initial: lift the 3x anti-amplification limit (RFC 9000 §8.1) and
%% discard the Initial space and keys (RFC 9001 §4.9.1).
-spec validate_on_handshake(level(), t()) -> t().
validate_on_handshake(handshake, #state{validated = false, amp = Amp} = State) ->
    discard_space(initial, State#state{validated = true, amp = roadrunner_quic_amp:validate(Amp)});
validate_on_handshake(_Level, State) ->
    State.

-spec record_received(level(), non_neg_integer(), [roadrunner_quic_frame:frame()], t()) -> t().
record_received(Level, PN, Frames, #state{spaces = Spaces} = State) ->
    case Spaces of
        #{Level := Space} ->
            Ack = roadrunner_quic_ack:record(
                PN, roadrunner_quic_send:ack_eliciting(Frames), Space#space.ack
            ),
            put_space(Level, Space#space{ack = Ack}, State);
        #{} ->
            %% The space was discarded while folding this packet's frames
            %% (the handshake just confirmed); there is nothing left to ack.
            State
    end.

%% =============================================================================
%% Per-frame handlers
%% =============================================================================

-spec process_frame(non_neg_integer(), level(), roadrunner_quic_frame:frame(), t()) -> t().
process_frame(_Now, Level, {crypto, Offset, Data}, State) ->
    process_crypto(Level, Offset, Data, State);
process_frame(Now, Level, {ack, _, _, _, _, _} = Ack, State) ->
    process_ack(Now, Level, Ack, State);
process_frame(_Now, _Level, _Frame, State) ->
    %% ping / padding / (other frames arrive with the application phase).
    State.

%% Reassemble CRYPTO, deframe complete handshake messages, and drive the
%% TLS sequencer.
-spec process_crypto(level(), non_neg_integer(), binary(), t()) -> t().
process_crypto(Level, Offset, Data, State) ->
    Space = space(Level, State),
    {ok, NewBytes, _Fin, Crypto} = roadrunner_quic_stream:receive_data(
        Offset, Data, false, Space#space.crypto
    ),
    Buffer = <<(Space#space.crypto_in)/binary, NewBytes/binary>>,
    {Messages, Rest} = deframe(Buffer),
    State1 = put_space(Level, Space#space{crypto = Crypto, crypto_in = Rest}, State),
    lists:foldl(fun(Message, S) -> process_handshake(Level, Message, S) end, State1, Messages).

%% Decode every complete handshake message, leaving trailing partial bytes.
-spec deframe(binary()) -> {[{byte(), binary()}], binary()}.
deframe(Buffer) ->
    case roadrunner_quic_tls_handshake:decode(Buffer) of
        {ok, {Type, Body}, Rest} ->
            {More, Tail} = deframe(Rest),
            {[{Type, Body} | More], Tail};
        {more, _} ->
            {[], Buffer}
    end.

-spec process_handshake(level(), {byte(), binary()}, t()) -> t().
process_handshake(initial, {?CLIENT_HELLO, Body}, #state{tls = Tls} = State) ->
    {ok, #{initial := InitialFlight, handshake := HandshakeFlight}, Installs, Tls1} =
        roadrunner_quic_tls_server:process_client_hello(Body, Tls),
    State1 = install_keys(Installs, State#state{tls = Tls1}),
    State2 = queue_crypto(initial, InitialFlight, State1),
    queue_crypto(handshake, HandshakeFlight, State2);
process_handshake(handshake, {?FINISHED, Body}, #state{tls = Tls} = State) ->
    ok = roadrunner_quic_tls_server:process_client_finished(Body, Tls),
    %% Handshake confirmed: discard the Handshake space (RFC 9001 §4.9.2),
    %% become connected, and send HANDSHAKE_DONE at the application level.
    State1 = discard_space(handshake, State#state{phase = connected}),
    queue_frame(application, handshake_done, State1).

%% Arm the keys the TLS flight produced: server installs protect outgoing
%% packets, client installs decrypt incoming ones; the Application space
%% appears with its keys.
-spec install_keys([roadrunner_quic_tls_server:install()], t()) -> t().
install_keys(Installs, State) ->
    lists:foldl(fun install_key/2, State, Installs).

-spec install_key(roadrunner_quic_tls_server:install(), t()) -> t().
install_key({Level, server, Keys}, #state{send_keys = SendKeys} = State) ->
    ensure_space(Level, State#state{send_keys = SendKeys#{Level => Keys}});
install_key({Level, client, Keys}, #state{recv_keys = RecvKeys} = State) ->
    ensure_space(Level, State#state{recv_keys = RecvKeys#{Level => Keys}}).

-spec ensure_space(level(), t()) -> t().
ensure_space(Level, #state{spaces = Spaces} = State) ->
    case Spaces of
        #{Level := _} -> State;
        #{} -> State#state{spaces = Spaces#{Level => new_space()}}
    end.

%% Forget a packet-number space and its keys (RFC 9001 §4.9).
-spec discard_space(level(), t()) -> t().
discard_space(Level, #state{spaces = Spaces, recv_keys = RK, send_keys = SK} = State) ->
    State#state{
        spaces = maps:remove(Level, Spaces),
        recv_keys = maps:remove(Level, RK),
        send_keys = maps:remove(Level, SK)
    }.

%% Buffer outbound CRYPTO bytes for a level (sent as CRYPTO frames).
-spec queue_crypto(level(), iolist(), t()) -> t().
queue_crypto(Level, Bytes, State) ->
    Space = space(Level, State),
    put_space(
        Level,
        Space#space{crypto = roadrunner_quic_stream:enqueue(Bytes, Space#space.crypto)},
        State
    ).

%% Queue a control frame to send at a level.
-spec queue_frame(level(), roadrunner_quic_frame:frame(), t()) -> t().
queue_frame(Level, Frame, State) ->
    Space = space(Level, State),
    put_space(Level, Space#space{pending = Space#space.pending ++ [Frame]}, State).

-spec process_ack(non_neg_integer(), level(), tuple(), t()) -> t().
process_ack(Now, Level, Ack, State) ->
    Space = space(Level, State),
    case roadrunner_quic_loss:on_ack_received(Ack, Now, Space#space.loss) of
        {error, _} ->
            State;
        {Loss, _Acked, Lost} ->
            put_space(
                Level,
                Space#space{loss = Loss, pending = Space#space.pending ++ retransmittable(Lost)},
                State
            )
    end.

%% =============================================================================
%% Outbound send pass
%% =============================================================================

-spec send_pass(non_neg_integer(), t()) -> {t(), [effect()]}.
send_pass(Now, State) ->
    {State1, SendEffects} = drain_send(Now, State, []),
    {State1, SendEffects ++ timer_effects(State1)}.

%% Build and send one datagram per iteration until nothing is pending or
%% the anti-amplification budget blocks; roll back the built state if the
%% datagram cannot be sent.
-spec drain_send(non_neg_integer(), t(), [effect()]) -> {t(), [effect()]}.
drain_send(Now, State, Acc) ->
    case build_packets(State) of
        none ->
            {State, lists:reverse(Acc)};
        {Entries, Built} ->
            #state{dcid = DCID, scid = SCID, amp = Amp} = State,
            {Datagram, Sent} = roadrunner_quic_send:datagram(Entries, DCID, SCID),
            case roadrunner_quic_amp:can_send(byte_size(Datagram), Amp) of
                false ->
                    {State, lists:reverse(Acc)};
                true ->
                    Recorded = record_sent(Now, Sent, Built),
                    Amp1 = roadrunner_quic_amp:sent(byte_size(Datagram), Amp),
                    drain_send(Now, Recorded#state{amp = Amp1}, [{send, Datagram} | Acc])
            end
    end.

%% Build ONE packet for the highest-priority present level that has
%% something to send, returned as a single-level datagram plus the
%% post-send state (CRYPTO popped, ACK marked sent, pending cleared,
%% next-PN advanced). Sending one level per datagram instead of coalescing
%% keeps every datagram within 1200 bytes: `roadrunner_quic_send` pads an
%% Initial up to 1200 but never caps, so a coalesced Initial+Handshake
%% flight would overflow. It also makes the forbidden Initial+1-RTT
%% coalescing structurally impossible. Coalescing Initial+Handshake is a
%% deferred optimization. Returns `none` when nothing is pending anywhere.
-spec build_packets(t()) -> none | {#{level() => map()}, t()}.
build_packets(State) ->
    build_first(present_levels(State), State).

-spec build_first([level()], t()) -> none | {#{level() => map()}, t()}.
build_first([], _State) ->
    none;
build_first([Level | Rest], State) ->
    case build_level(Level, State) of
        none -> build_first(Rest, State);
        {Entry, Built} -> {#{Level => Entry}, Built}
    end.

-spec build_level(level(), t()) -> none | {map(), t()}.
build_level(Level, State) ->
    Space = space(Level, State),
    {AckFrames, Ack} = take_ack(Space#space.ack),
    case Space#space.pending of
        [_ | _] = Pending ->
            %% Retransmits travel in their own packet (no fresh CRYPTO
            %% slice), so a replayed CRYPTO frame plus a new slice can
            %% never overflow the datagram.
            build_entry(Level, AckFrames ++ Pending, Space#space{ack = Ack, pending = []}, State);
        [] ->
            {CryptoFrames, Crypto} = take_crypto(Space#space.crypto),
            case AckFrames ++ CryptoFrames of
                [] -> none;
                Frames -> build_entry(Level, Frames, Space#space{ack = Ack, crypto = Crypto}, State)
            end
    end.

-spec build_entry(level(), [roadrunner_quic_frame:frame()], #space{}, t()) -> {map(), t()}.
build_entry(Level, Frames, #space{next_pn = PN} = Space, #state{send_keys = SendKeys} = State) ->
    #{Level := Keys} = SendKeys,
    Entry = #{frames => Frames, keys => Keys, pn => PN},
    {Entry, put_space(Level, Space#space{next_pn = PN + 1}, State)}.

-spec take_ack(roadrunner_quic_ack:t()) ->
    {[roadrunner_quic_frame:frame()], roadrunner_quic_ack:t()}.
take_ack(Ack) ->
    case roadrunner_quic_ack:needs_ack(Ack) of
        false ->
            {[], Ack};
        true ->
            {Largest, FirstRange, Ranges} = roadrunner_quic_ack:to_ack(Ack),
            {
                [{ack, Largest, 0, FirstRange, Ranges, undefined}],
                roadrunner_quic_ack:mark_ack_sent(Ack)
            }
    end.

-spec take_crypto(roadrunner_quic_stream:t()) ->
    {[roadrunner_quic_frame:frame()], roadrunner_quic_stream:t()}.
take_crypto(Crypto) ->
    case roadrunner_quic_stream:next_frame(?CRYPTO_BUDGET, Crypto) of
        nothing -> {[], Crypto};
        {Offset, Data, _Fin, Crypto1} -> {[{crypto, Offset, Data}], Crypto1}
    end.

-spec record_sent(non_neg_integer(), [roadrunner_quic_send:sent()], t()) -> t().
record_sent(Now, Sent, State) ->
    lists:foldl(fun(S, Acc) -> record_one_sent(Now, S, Acc) end, State, Sent).

-spec record_one_sent(non_neg_integer(), roadrunner_quic_send:sent(), t()) -> t().
record_one_sent(
    Now,
    #{level := Level, pn := PN, length := Len, ack_eliciting := AckEliciting, frames := Frames},
    State
) ->
    Space = space(Level, State),
    Loss = roadrunner_quic_loss:on_packet_sent(
        PN, Len, AckEliciting, Frames, Now, Space#space.loss
    ),
    put_space(Level, Space#space{loss = Loss}, State).

%% =============================================================================
%% Timers
%% =============================================================================

-doc """
Handle a fired loss/PTO timer: re-run loss detection on every space,
queueing lost frames to retransmit, then run a send pass so a dropped
handshake packet recovers.
""".
-spec handle_timeout(non_neg_integer(), atom(), t()) -> {t(), [effect()]}.
handle_timeout(Now, pto, State) ->
    State1 = lists:foldl(
        fun(Level, S) -> detect_loss(Now, Level, S) end, State, present_levels(State)
    ),
    send_pass(Now, State1).

-spec detect_loss(non_neg_integer(), level(), t()) -> t().
detect_loss(Now, Level, State) ->
    #space{loss = Loss0, pending = Pending} = Space = space(Level, State),
    {Loss, Lost} = roadrunner_quic_loss:detect_lost(Now, Loss0),
    put_space(
        Level,
        Space#space{loss = Loss, pending = Pending ++ retransmittable(Lost)},
        State
    ).

-spec timer_effects(t()) -> [effect()].
timer_effects(State) ->
    case earliest_loss_time(State) of
        undefined -> [];
        AtMs -> [{arm_timer, pto, AtMs}]
    end.

-spec earliest_loss_time(t()) -> non_neg_integer() | undefined.
earliest_loss_time(State) ->
    lists:foldl(
        fun(Level, Earliest) ->
            min_defined(Earliest, roadrunner_quic_loss:loss_time((space(Level, State))#space.loss))
        end,
        undefined,
        present_levels(State)
    ).

%% =============================================================================
%% Internal
%% =============================================================================

-spec largest_map(t()) -> #{level() => non_neg_integer()}.
largest_map(#state{spaces = Spaces}) ->
    maps:fold(
        fun(Level, #space{ack = Ack}, Acc) ->
            case roadrunner_quic_ack:largest(Ack) of
                undefined -> Acc;
                Largest -> Acc#{Level => Largest}
            end
        end,
        #{},
        Spaces
    ).

-spec present_levels(t()) -> [level()].
present_levels(#state{spaces = Spaces}) ->
    [Level || Level <- [initial, handshake, application], is_map_key(Level, Spaces)].

-spec space(level(), t()) -> #space{}.
space(Level, #state{spaces = Spaces}) ->
    #{Level := Space} = Spaces,
    Space.

-spec put_space(level(), #space{}, t()) -> t().
put_space(Level, Space, #state{spaces = Spaces} = State) ->
    State#state{spaces = Spaces#{Level => Space}}.

-spec min_defined(non_neg_integer() | undefined, non_neg_integer() | undefined) ->
    non_neg_integer() | undefined.
min_defined(undefined, B) -> B;
min_defined(A, undefined) -> A;
min_defined(A, B) -> min(A, B).

%% Flatten the per-packet frame lists a loss returns and keep only the
%% frames worth resending: ACK / PADDING / CONNECTION_CLOSE are regenerated
%% fresh or terminal, never replayed (RFC 9002 §13.3).
%% `roadrunner_quic_send:ack_eliciting/1` is the single source of truth for
%% which frames are ack-eliciting.
-spec retransmittable([[roadrunner_quic_frame:frame()]]) -> [roadrunner_quic_frame:frame()].
retransmittable(Lost) ->
    [Frame || Frame <- lists:append(Lost), roadrunner_quic_send:is_ack_eliciting(Frame)].
