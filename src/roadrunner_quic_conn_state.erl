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
%% AtMs}` ((re)arm a timer), `{emit, Owner, Event}` (async owner
%% notification, e.g. `{connected, Info}`), and `{reply, To, Ref, Result}`
%% (answer a synchronous control call).
%%
%% A connection keeps up to three packet-number spaces (Initial, Handshake,
%% Application). The server reads with the peer's keys and writes with its
%% own; CRYPTO is reassembled per space (a `roadrunner_quic_stream` with no
%% FIN). Initial state is discarded once a Handshake packet decrypts and
%% Handshake state once the handshake is confirmed (RFC 9001 §4.9), which
%% also keeps the send pass from ever coalescing an Initial with a 1-RTT
%% packet. The send pass collects, per space in order, an ACK frame, the
%% TLS flight / retransmits, and (at the Application level) HANDSHAKE_DONE
%% plus outbound STREAM data sliced within the send-flow windows, packs them
%% with `roadrunner_quic_send`, gates the datagram against the §8.1
%% anti-amplification budget, and records each sent packet for loss
%% recovery.
%%
%% Congestion control and probe transmission are deferred: the connection
%% sends within the anti-amplification and flow limits (the MUSTs) and a
%% probe timeout only re-checks for losses and backs off. Wiring NewReno and
%% sending an explicit probe both need the loss layer to surface acked bytes
%% / sent times / the oldest unacknowledged frames, a separate follow-up.

-export([
    new/2, handle_datagram/3, handle_timeout/3, handle_call/5, handle_send/7, peername/1, phase/1
]).

-export_type([t/0, config/0, effect/0, event/0, info/0]).

%% RFC 9000 §17.2: the server uses a fixed-length SCID so short headers demux.
-define(SCID_LEN, 8).
%% A CRYPTO slice budget that leaves room for the packet header, an ACK
%% frame, and the AEAD tag within the 1200-byte datagram (RFC 9000 §14).
-define(CRYPTO_BUDGET, 1000).
%% Default idle timeout (RFC 9000 §10.1): the connection silently closes after
%% this many ms with no packet received. Seeding it from the advertised / peer
%% max_idle_timeout is a follow-up.
-define(IDLE_TIMEOUT, 30000).
%% TLS handshake message types carried in CRYPTO (RFC 8446 §4).
-define(CLIENT_HELLO, 1).
-define(FINISHED, 20).

-type level() :: initial | handshake | application.
-type phase() :: handshaking | connected | draining | closed.

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
    %% The client's Initial Destination Connection ID: derives the Initial keys
    %% and echoes as original_destination_connection_id. NOT the reply wire DCID.
    dcid :: binary(),
    scid :: binary(),
    %% The client's Source Connection ID, which every server reply addresses as
    %% its Destination Connection ID (RFC 9000 §7.2/§17.2).
    peer_scid :: binary(),
    peer :: {inet:ip_address(), inet:port_number()},
    phase = handshaking :: phase(),
    tls :: roadrunner_quic_tls_server:t(),
    %% Keys to decrypt incoming packets (the peer's), by level.
    recv_keys :: #{level() => roadrunner_quic_keys:keys()},
    %% Keys to protect outgoing packets (the server's), by level.
    send_keys :: #{level() => roadrunner_quic_keys:keys()},
    spaces :: #{level() => #space{}},
    amp :: roadrunner_quic_amp:t(),
    %% Cleared once a Handshake packet decrypts (address validated, §8.1).
    validated = false :: boolean(),
    %% The application owner: the async sink for `{emit, _, _}` events,
    %% installed by the listener (via set_owner) during handshaking.
    owner :: pid() | undefined,
    %% The `connected` payload, built once at new/1.
    info :: info(),
    %% Application streams, each with its own reassembly + flow window, keyed
    %% by stream id (peer-initiated on receive; server-initiated and client
    %% request streams on send).
    streams = #{} :: #{non_neg_integer() => stream()},
    %% The subset of `streams` ids with unsent data or an unsent FIN, kept
    %% ascending (RFC 9000 stream priority: lowest id first). The send pass
    %% walks only these instead of re-sorting and scanning every stream
    %% (finished streams stay in `streams` but leave this set), so per-pass
    %% work is O(streams-with-pending-data), not O(all-streams-ever).
    sendable = [] :: ordsets:ordset(non_neg_integer()),
    %% Next server-initiated unidirectional stream id to hand out (RFC 9000
    %% §2.1: server uni ids are 3, 7, 11, ...); the owner opens its h3
    %% control stream this way.
    next_uni = 3 :: non_neg_integer(),
    %% The stream counts we advertised the peer may open
    %% (initial_max_streams_bidi/uni, RFC 9000 §4.6): a client-initiated stream
    %% whose ordinal (id div 4) is >= the limit for its type is a
    %% STREAM_LIMIT_ERROR.
    max_streams_bidi :: non_neg_integer(),
    max_streams_uni :: non_neg_integer(),
    %% Connection-level flow control (RFC 9000 §4).
    conn_flow :: roadrunner_quic_flow:t(),
    %% Owner events accumulated while folding a datagram's frames, drained in
    %% order at the end of handle_datagram (newest-first, reversed on drain).
    emits = [] :: [effect()],
    %% A locally-detected error to signal: {Level, WireErrorCode} for the one
    %% CONNECTION_CLOSE to transmit at that encryption level. `undefined` for a
    %% live connection or a peer-initiated close (which sends nothing back).
    pending_close = undefined :: undefined | {level(), non_neg_integer()},
    %% Absolute time (ms) the connection idle-times-out; reset to Now +
    %% ?IDLE_TIMEOUT on every received datagram (RFC 9000 §10.1). Always set
    %% (from new/2's birth time), so it is the timer floor when nothing is in
    %% flight. Also restarting it on the first ack-eliciting send since the
    %% last receive (§10.1) is a follow-up; receive-only is conservative
    %% (it closes no later than a strict implementation would).
    idle_deadline :: integer()
}).

-type stream() :: {roadrunner_quic_stream:t(), roadrunner_quic_flow:t()}.

-opaque t() :: #state{}.

-type config() :: #{
    dcid := binary(),
    scid := binary(),
    peer_scid := binary(),
    peer := {inet:ip_address(), inet:port_number()},
    cert_chain := [binary()],
    priv_key := public_key:private_key(),
    alpn := binary(),
    transport_params := roadrunner_quic_transport_params:params(),
    eph_pub := binary(),
    eph_priv := binary(),
    server_random := binary()
}.

%% A monotonic-clock millisecond, the same epoch `erlang:monotonic_time/1`
%% returns (negative on the BEAM), so an `arm_timer` deadline is `integer()`.
%% `{emit, Owner, Event}` is an async owner notification (the shell does
%% `Owner ! {quic, self(), Event}`); `{reply, To, Ref, Result}` answers a
%% synchronous control call.
-type effect() ::
    {send, binary()}
    | {arm_timer, atom(), integer()}
    | {emit, pid(), event()}
    | {reply, pid(), reference(), term()}.

%% Async owner notifications (conn -> owner). `stream_data` carries the
%% FIN-only end-of-stream as `{stream_data, Sid, <<>>, true}`. `closed` is the
%% terminal event: `{peer, ErrorCode}` is a peer CONNECTION_CLOSE, `{local,
%% Reason}` a connection error we detected (idle-timeout joins them later).
-type event() ::
    {connected, info()}
    | {stream_opened, non_neg_integer()}
    | {stream_data, non_neg_integer(), binary(), boolean()}
    | {stream_reset, non_neg_integer(), non_neg_integer()}
    | {closed, {peer, non_neg_integer()} | {local, atom()}}.

%% The `connected` payload. The h3 owner ignores it; it carries the
%% negotiated ALPN and the advertised transport params for forward-compat.
-type info() :: #{alpn := binary(), transport_params := roadrunner_quic_transport_params:params()}.

%% =============================================================================
%% Construction
%% =============================================================================

-doc """
Build the connection state from the per-connection config and the birth time
`Now` (ms). Bootstraps the Initial keys from the client's Destination
Connection ID (`dcid`), records the client's Source Connection ID (`peer_scid`)
as the destination every reply is addressed to (RFC 9000 §7.2), the TLS server
sequencer (the server transport parameters already carry the original/initial
connection ids), the Initial and Handshake packet-number spaces (the Application
space appears once 1-RTT keys arm), and the idle-timeout deadline anchored at
`Now`.
""".
-spec new(config(), integer()) -> t().
new(
    #{
        dcid := DCID,
        scid := SCID,
        peer_scid := PeerSCID,
        peer := Peer,
        cert_chain := CertChain,
        priv_key := PrivKey,
        alpn := Alpn,
        transport_params := TransportParams,
        eph_pub := EphPub,
        eph_priv := EphPriv,
        server_random := ServerRandom
    },
    Now
) ->
    Tls = roadrunner_quic_tls_server:new(#{
        cert_chain => CertChain,
        priv_key => PrivKey,
        alpn => Alpn,
        transport_params => TransportParams,
        eph_pub => EphPub,
        eph_priv => EphPriv,
        server_random => ServerRandom,
        peer_scid => PeerSCID
    }),
    %% Seed the connection receive window and the stream-count limits from the
    %% values we advertise, so what is enforced (RFC 9000 §4.1 / §4.6) is exactly
    %% what the peer was told it may use, never a hardcoded default.
    #{
        initial_max_data := ConnMaxData,
        initial_max_streams_bidi := MaxStreamsBidi,
        initial_max_streams_uni := MaxStreamsUni
    } = TransportParams,
    #state{
        dcid = DCID,
        scid = SCID,
        peer_scid = PeerSCID,
        peer = Peer,
        tls = Tls,
        recv_keys = #{initial => roadrunner_quic_keys:initial_client(DCID)},
        send_keys = #{initial => roadrunner_quic_keys:initial_server(DCID)},
        spaces = #{initial => new_space(), handshake => new_space()},
        amp = roadrunner_quic_amp:new(),
        owner = undefined,
        info = #{alpn => Alpn, transport_params => TransportParams},
        max_streams_bidi = MaxStreamsBidi,
        max_streams_uni = MaxStreamsUni,
        conn_flow = roadrunner_quic_flow:new(#{initial_max_data => ConnMaxData}),
        idle_deadline = Now + ?IDLE_TIMEOUT
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
-spec phase(t()) -> phase().
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
-spec handle_datagram(integer(), binary(), t()) -> {t(), [effect()]}.
handle_datagram(Now, Datagram, #state{amp = Amp, recv_keys = RecvKeys, phase = Before} = State0) ->
    State1 = State0#state{
        amp = roadrunner_quic_amp:received(byte_size(Datagram), Amp),
        idle_deadline = Now + ?IDLE_TIMEOUT
    },
    Outcomes = roadrunner_quic_recv:datagram(
        Datagram, ?SCID_LEN, RecvKeys, largest_map(State1)
    ),
    State2 = lists:foldl(fun(O, S) -> process_outcome(Now, O, S) end, State1, Outcomes),
    finish_datagram(Now, Before, State2).

%% After folding a datagram's frames: if a close fired during the fold,
%% transmit our CONNECTION_CLOSE for a locally-detected error (RFC 9000
%% §10.2.3) or send nothing for a peer CONNECTION_CLOSE (§10.2.2), then deliver
%% the {closed, _} emit. Otherwise run the send pass and drain owner events,
%% with {connected, _} ordered ahead of any stream events from the same
%% datagram so the owner opens its control stream before the first request.
-spec finish_datagram(integer(), phase(), t()) -> {t(), [effect()]}.
finish_datagram(_Now, _Before, #state{phase = closed, pending_close = undefined} = State) ->
    drain_emits(State);
finish_datagram(_Now, _Before, #state{phase = closed} = State) ->
    {State1, CloseEffects} = send_close(State),
    {State2, EmitEffects} = drain_emits(State1),
    case CloseEffects of
        [] -> {State2, EmitEffects};
        [Close] -> {State2, [Close | EmitEffects]}
    end;
finish_datagram(Now, Before, State) ->
    {State3, SendEffects} = send_pass(Now, State),
    {State4, Emits} = take_emits(State3),
    %% {connected, _} first (so the owner opens its control stream before the
    %% first request), then the datagram's owner events in arrival order, then
    %% the sends; reverse the newest-first emits onto the sends in one pass.
    {State4, connected_effects(Before, State4, lists:reverse(Emits, SendEffects))}.

%% Owner events accumulate (newest-first) in #state.emits while the
%% datagram's frames are folded; hand them back in arrival order and clear.
-spec drain_emits(t()) -> {t(), [effect()]}.
drain_emits(State) ->
    {State1, Emits} = take_emits(State),
    {State1, lists:reverse(Emits)}.

%% Take the owner events newest-first (as accumulated) and clear them, for a
%% caller that will reverse them onto a tail itself.
-spec take_emits(t()) -> {t(), [effect()]}.
take_emits(#state{emits = Emits} = State) ->
    {State#state{emits = []}, Emits}.

%% Queue an owner event for the current datagram (dropped if no owner yet).
-spec emit(event(), t()) -> t().
emit(_Event, #state{owner = undefined} = State) ->
    State;
emit(Event, #state{owner = Owner, emits = Emits} = State) ->
    State#state{emits = [{emit, Owner, Event} | Emits]}.

%% Emit `{connected, Info}` exactly when this datagram drove the
%% handshaking -> connected transition AND an owner is installed. With no
%% owner yet (the listener has not run set_owner), the emit is deferred to
%% install_owner. The two sites are mutually exclusive, so it fires once.
-spec connected_effects(phase(), t(), [effect()]) -> [effect()].
connected_effects(handshaking, #state{phase = connected, owner = Owner, info = Info}, Tail) when
    is_pid(Owner)
->
    [{emit, Owner, {connected, Info}} | Tail];
connected_effects(_Before, _State, Tail) ->
    Tail.

%% =============================================================================
%% Control calls (owner / listener -> conn, synchronous)
%% =============================================================================

-doc """
Answer a synchronous control call: the shell forwards `{quic_call, From,
Ref, Request}` here and performs the returned `{reply, From, Ref, Result}`
(plus any deferred `{emit, _, _}`). Owner and listener calls into the
connection are synchronous; the connection only ever notifies the owner
with async `{emit, _, _}` effects, so it never blocks on the owner.
""".
-spec handle_call(pid(), reference(), Request, integer(), t()) -> {t(), [effect()]} when
    Request ::
        peername
        | {set_owner, pid()}
        | open_uni
        | {reset_stream, non_neg_integer(), non_neg_integer()}
        | {stop_sending, non_neg_integer(), non_neg_integer()}
        | {close, non_neg_integer()}
        | {close, non_neg_integer(), binary()}.
handle_call(From, Ref, peername, _Now, #state{peer = Peer} = State) ->
    {State, [{reply, From, Ref, {ok, Peer}}]};
handle_call(From, Ref, {set_owner, Owner}, _Now, State) ->
    {State1, EmitEffects} = install_owner(Owner, State),
    {State1, [{reply, From, Ref, ok} | EmitEffects]};
handle_call(From, Ref, open_uni, _Now, #state{next_uni = Id} = State) ->
    %% Allocate the next server-initiated unidirectional stream id. The stream
    %% itself is created lazily on the first send_data; the h3 layer writes the
    %% stream-type byte + SETTINGS, never this layer.
    {State#state{next_uni = Id + 4}, [{reply, From, Ref, {ok, Id}}]};
handle_call(From, Ref, {reset_stream, Sid, ErrorCode}, Now, State) ->
    {State1, SendEffects} = do_reset_stream(Sid, ErrorCode, Now, State),
    {State1, [{reply, From, Ref, ok} | SendEffects]};
handle_call(From, Ref, {stop_sending, Sid, ErrorCode}, Now, State) ->
    {State1, SendEffects} = do_stop_sending(Sid, ErrorCode, Now, State),
    {State1, [{reply, From, Ref, ok} | SendEffects]};
handle_call(From, Ref, {close, ErrorCode}, _Now, State) ->
    {State1, CloseEffects} = owner_close(ErrorCode, <<>>, State),
    {State1, [{reply, From, Ref, ok} | CloseEffects]};
handle_call(From, Ref, {close, ErrorCode, Reason}, _Now, State) ->
    {State1, CloseEffects} = owner_close(ErrorCode, Reason, State),
    {State1, [{reply, From, Ref, ok} | CloseEffects]}.

%% The owner closes the connection (RFC 9000 §10.2.2): send one application
%% CONNECTION_CLOSE (0x1d, carrying the h3 error code and reason phrase) at the
%% 1-RTT level and mark the connection closed so the shell exits. The owner
%% triggered this, so no {closed, _} is emitted back; this runs only once the
%% connection is established (1-RTT keys present), which is the only state the
%% owner has a connection to close in. Distinct from connection_fatal/send_close
%% (a locally-detected transport error during datagram processing): this is the
%% application-variant close and never coalesces with other frames.
-spec owner_close(non_neg_integer(), binary(), t()) -> {t(), [effect()]}.
owner_close(ErrorCode, Reason, #state{send_keys = SendKeys} = State) ->
    case SendKeys of
        #{application := Keys} ->
            send_owner_close(ErrorCode, Reason, Keys, State);
        #{} ->
            %% The owner closed before the handshake completed (e.g. the
            %% connection_handler refusing on max_clients): there are no 1-RTT
            %% keys to carry an application CONNECTION_CLOSE, so close silently
            %% and let the client time out. The connection still ends.
            {State#state{phase = closed}, []}
    end.

-spec send_owner_close(non_neg_integer(), binary(), roadrunner_quic_keys:keys(), t()) ->
    {t(), [effect()]}.
send_owner_close(ErrorCode, Reason, Keys, #state{peer_scid = DCID, scid = SCID} = State) ->
    Space = space(application, State),
    PN = Space#space.next_pn,
    Frame = {connection_close, application, ErrorCode, undefined, Reason},
    Entry = #{application => #{frames => [Frame], keys => Keys, pn => PN}},
    {Datagram, _Sent} = roadrunner_quic_send:datagram(Entry, DCID, SCID),
    State1 = put_space(
        application, Space#space{next_pn = PN + 1}, State#state{phase = closed}
    ),
    {State1, [{send, Datagram}]}.

%% Abandon the send side of a stream and tell the peer with a RESET_STREAM (RFC
%% 9000 §19.4): discard the unsent buffer, record the bytes already sent as the
%% Final Size, queue the frame at the application level, and flush it. The h3
%% layer uses this to abort a response stream.
-spec do_reset_stream(non_neg_integer(), non_neg_integer(), integer(), t()) -> {t(), [effect()]}.
do_reset_stream(Sid, ErrorCode, Now, State) ->
    {Stream, Flow, State1} = stream_for_send(Sid, State),
    FinalSize = roadrunner_quic_stream:send_offset(Stream),
    Stream1 = roadrunner_quic_stream:stop_sending(Stream),
    State2 = put_stream(Sid, Stream1, Flow, State1),
    State3 = queue_frame(application, {reset_stream, Sid, ErrorCode, FinalSize}, State2),
    send_pass(Now, State3).

%% Ask the peer to stop sending on a stream with a STOP_SENDING (RFC 9000
%% §19.5): queue the frame at the application level and flush it. The h3 layer
%% uses this to decline a request body it will not read.
-spec do_stop_sending(non_neg_integer(), non_neg_integer(), integer(), t()) -> {t(), [effect()]}.
do_stop_sending(Sid, ErrorCode, Now, State) ->
    State1 = queue_frame(application, {stop_sending, Sid, ErrorCode}, State),
    send_pass(Now, State1).

%% Install the owner. When the handshake already completed before the owner
%% was set (the deferred path), emit the once-only `{connected, Info}` now;
%% normally the listener sets the owner during handshaking, so the emit
%% instead rides out of handle_datagram at the transition.
-spec install_owner(pid(), t()) -> {t(), [effect()]}.
install_owner(Owner, #state{phase = connected, info = Info} = State) ->
    {State#state{owner = Owner}, [{emit, Owner, {connected, Info}}]};
install_owner(Owner, State) ->
    {State#state{owner = Owner}, []}.

-doc """
Buffer outbound stream data and run a send pass: the shell forwards
`{quic_send, From, Ref, Sid, IoData, Fin}` here. The data is enqueued on the
stream's send buffer (the stream is created on first reference), an optional
FIN is flagged, then the queued bytes are flushed as STREAM frames within the
connection and per-stream send-flow credit. Always replies `ok`; rejecting a
send on a draining/closed connection is a teardown-slice follow-up.
""".
-spec handle_send(pid(), reference(), non_neg_integer(), iodata(), boolean(), integer(), t()) ->
    {t(), [effect()]}.
handle_send(From, Ref, Sid, IoData, Fin, Now, State) ->
    State1 = enqueue_send(Sid, IoData, Fin, State),
    {State2, SendEffects} = send_pass(Now, State1),
    {State2, [{reply, From, Ref, ok} | SendEffects]}.

%% Append outbound bytes to a stream's send buffer (creating the stream on
%% first reference) and flag the FIN when this is the final write.
-spec enqueue_send(non_neg_integer(), iodata(), boolean(), t()) -> t().
enqueue_send(Sid, IoData, Fin, State) ->
    {Stream0, Flow, State1} = stream_for_send(Sid, State),
    Stream1 = roadrunner_quic_stream:enqueue(IoData, Stream0),
    Stream2 =
        case Fin of
            true -> roadrunner_quic_stream:finish(Stream1);
            false -> Stream1
        end,
    put_stream(Sid, Stream2, Flow, State1).

%% Look up a stream for sending, or create it without announcing. Sends go to
%% the server's own streams or to existing client request streams, never to a
%% peer stream the owner has not already seen via {stream_opened, _}.
-spec stream_for_send(non_neg_integer(), t()) ->
    {roadrunner_quic_stream:t(), roadrunner_quic_flow:t(), t()}.
stream_for_send(Sid, #state{streams = Streams} = State) ->
    case Streams of
        #{Sid := {Stream, Flow}} -> {Stream, Flow, State};
        #{} -> {roadrunner_quic_stream:new(), roadrunner_quic_flow:new(#{}), State}
    end.

-spec process_outcome(integer(), roadrunner_quic_recv:outcome(), t()) -> t().
process_outcome(_Now, _Outcome, #state{phase = closed} = State) ->
    %% A close fired on an earlier packet in this datagram; skip the rest so we
    %% neither act on their frames nor discard (via validate_on_handshake) the
    %% space and keys a pending local close still needs to send its frame.
    State;
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

-spec process_frame(integer(), level(), roadrunner_quic_frame:frame(), t()) -> t().
process_frame(_Now, _Level, _Frame, #state{phase = closed} = State) ->
    %% A CONNECTION_CLOSE earlier in this packet already closed the connection;
    %% ignore the remaining frames (RFC 9000 §10.2.2).
    State;
process_frame(
    _Now, application, {connection_close, _Variant, ErrorCode, _FrameType, _Reason}, State
) ->
    process_close(ErrorCode, State);
process_frame(_Now, _Level, {connection_close, transport, ErrorCode, _FrameType, _Reason}, State) ->
    process_close(ErrorCode, State);
process_frame(
    _Now, Level, {connection_close, application, _ErrorCode, _FrameType, _Reason}, State
) ->
    %% The application CONNECTION_CLOSE (0x1d) is 0-RTT/1-RTT only (RFC 9000
    %% §19.19); one decoded from an Initial/Handshake packet is a protocol
    %% violation.
    connection_fatal(Level, protocol_violation, State);
process_frame(_Now, Level, {crypto, Offset, Data}, State) ->
    process_crypto(Level, Offset, Data, State);
process_frame(Now, Level, {ack, _, _, _, _, _} = Ack, State) ->
    process_ack(Now, Level, Ack, State);
process_frame(_Now, application, {stream, Sid, Offset, Data, Fin}, State) ->
    process_stream(Sid, Offset, Data, Fin, State);
process_frame(_Now, application, {reset_stream, Sid, ErrorCode, FinalSize}, State) ->
    process_reset_stream(Sid, ErrorCode, FinalSize, State);
process_frame(_Now, _Level, _Frame, State) ->
    %% ping / padding are no-ops. Peer flow-credit grants (MAX_DATA /
    %% MAX_STREAM_DATA) and MAX_STREAMS are accepted but not yet acted on, so
    %% the send side keeps the default window until that follow-up lands.
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
    case roadrunner_quic_tls_server:process_client_hello(Body, Tls) of
        {ok, #{initial := InitialFlight, handshake := HandshakeFlight}, Installs, Tls1} ->
            State1 = install_keys(Installs, State#state{tls = Tls1}),
            State2 = queue_crypto(initial, InitialFlight, State1),
            queue_crypto(handshake, HandshakeFlight, State2);
        {error, Reason} ->
            connection_fatal(initial, Reason, State)
    end;
process_handshake(handshake, {?FINISHED, Body}, #state{tls = Tls} = State) ->
    case roadrunner_quic_tls_server:process_client_finished(Body, Tls) of
        ok ->
            %% Handshake confirmed: discard the Handshake space (RFC 9001
            %% §4.9.2), become connected, and send HANDSHAKE_DONE at the
            %% application level.
            State1 = discard_space(handshake, State#state{phase = connected}),
            queue_frame(application, handshake_done, State1);
        {error, Reason} ->
            connection_fatal(handshake, Reason, State)
    end;
process_handshake(Level, {_Type, _Body}, State) ->
    %% An out-of-sequence or unknown handshake message (RFC 8446 unexpected
    %% message); connection-fatal like the other handshake failures.
    connection_fatal(Level, unexpected_message, State).

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

%% Queue a control frame to send at a level. The pending list is flushed into
%% one packet wholesale and frame order within a packet is irrelevant, so a
%% frame is consed on rather than appended.
-spec queue_frame(level(), roadrunner_quic_frame:frame(), t()) -> t().
queue_frame(Level, Frame, State) ->
    Space = space(Level, State),
    put_space(Level, Space#space{pending = [Frame | Space#space.pending]}, State).

-spec process_ack(integer(), level(), tuple(), t()) -> t().
process_ack(Now, Level, Ack, State) ->
    Space = space(Level, State),
    case roadrunner_quic_loss:on_ack_received(Ack, Now, Space#space.loss) of
        {error, _} ->
            State;
        {Loss, _Acked, Lost} ->
            put_space(
                Level,
                Space#space{
                    loss = Loss, pending = lists:reverse(retransmittable(Lost), Space#space.pending)
                },
                State
            )
    end.

%% =============================================================================
%% Application streams (peer-initiated, receive side)
%% =============================================================================

%% Reassemble a peer STREAM frame, charging the increase in its highest
%% received offset against the connection and per-stream receive windows
%% (RFC 9000 §4.1), so retransmitted or overlapping bytes never re-consume
%% the window. A STREAM frame on a server-initiated id is the peer writing to
%% a stream it cannot send on (RFC 9000 §19.8). A flow-control overrun, a
%% final-size violation, or that stream-state error is a peer-reachable
%% connection error: it closes the connection gracefully via connection_fatal/2
%% ({closed, {local, Reason}}), not a crash (transmitting a CONNECTION_CLOSE to
%% the peer is a later slice). Emits {stream_opened, Sid} on a peer stream's
%% first frame and {stream_data, Sid,
%% Bin, Fin} (including the FIN-only {<<>>, true}). Granting more credit
%% (MAX_DATA / MAX_STREAM_DATA) and seeding the windows from the advertised
%% transport parameters are send-side follow-ups.
-spec process_stream(non_neg_integer(), non_neg_integer(), binary(), boolean(), t()) -> t().
process_stream(Sid, _Offset, _Data, _Fin, State) when Sid rem 4 =:= 1; Sid rem 4 =:= 3 ->
    connection_fatal(application, stream_state_error, State);
process_stream(Sid, _Offset, _Data, _Fin, #state{max_streams_bidi = Max} = State) when
    Sid rem 4 =:= 0, Sid div 4 >= Max
->
    connection_fatal(application, stream_limit_error, State);
process_stream(Sid, _Offset, _Data, _Fin, #state{max_streams_uni = Max} = State) when
    Sid rem 4 =:= 2, Sid div 4 >= Max
->
    connection_fatal(application, stream_limit_error, State);
process_stream(Sid, Offset, Data, Fin, State) ->
    {Stream0, StreamFlow0, State1} = ensure_stream(Sid, State),
    #state{conn_flow = ConnFlow} = State1,
    Delta = max(0, Offset + byte_size(Data) - roadrunner_quic_flow:bytes_received(StreamFlow0)),
    maybe
        {ok, ConnFlow1} ?= roadrunner_quic_flow:on_data_received(Delta, ConnFlow),
        {ok, StreamFlow1} ?= roadrunner_quic_flow:on_data_received(Delta, StreamFlow0),
        {ok, Deliverable, FinReached, Stream1} ?=
            roadrunner_quic_stream:receive_data(Offset, Data, Fin, Stream0),
        State2 = put_stream(Sid, Stream1, StreamFlow1, State1#state{conn_flow = ConnFlow1}),
        deliver_stream(Sid, Deliverable, FinReached, State2)
    else
        {error, Reason} -> connection_fatal(application, Reason, State)
    end.

%% A RESET_STREAM aborts the peer's send side and surfaces the abort code. On
%% a server-initiated id it is the peer resetting a stream it cannot send on
%% (RFC 9000 §19.4 STREAM_STATE_ERROR).
-spec process_reset_stream(non_neg_integer(), non_neg_integer(), non_neg_integer(), t()) -> t().
process_reset_stream(Sid, _ErrorCode, _FinalSize, State) when Sid rem 4 =:= 1; Sid rem 4 =:= 3 ->
    connection_fatal(application, stream_state_error, State);
process_reset_stream(Sid, _ErrorCode, _FinalSize, #state{max_streams_bidi = Max} = State) when
    Sid rem 4 =:= 0, Sid div 4 >= Max
->
    connection_fatal(application, stream_limit_error, State);
process_reset_stream(Sid, _ErrorCode, _FinalSize, #state{max_streams_uni = Max} = State) when
    Sid rem 4 =:= 2, Sid div 4 >= Max
->
    connection_fatal(application, stream_limit_error, State);
process_reset_stream(Sid, ErrorCode, FinalSize, State) ->
    {Stream0, Flow, State1} = ensure_stream(Sid, State),
    case roadrunner_quic_stream:reset(FinalSize, Stream0) of
        {ok, Stream1} ->
            emit({stream_reset, Sid, ErrorCode}, put_stream(Sid, Stream1, Flow, State1));
        {error, Reason} ->
            connection_fatal(application, Reason, State)
    end.

%% A well-placed peer CONNECTION_CLOSE (transport at any level, or application
%% at 1-RTT) ends the connection: surface it to the owner and mark the
%% connection closed so the send pass is skipped and the shell exits. Lingering
%% in `draining` for 3x PTO to absorb the peer's reordered packets is a
%% follow-up; for now the listener drops late packets to the gone pid.
-spec process_close(non_neg_integer(), t()) -> t().
process_close(ErrorCode, State) ->
    emit({closed, {peer, ErrorCode}}, State#state{phase = closed}).

%% Close this single, isolated connection on a peer-reachable protocol error
%% (flow control §4.1, final size §4.5, stream state §19.8, an out-of-place
%% application CONNECTION_CLOSE §19.19, or a failed TLS handshake): record a
%% CONNECTION_CLOSE to transmit at the triggering packet's level (Level), mark
%% the connection closed so the fold short-circuits and the shell exits
%% cleanly (no crash, no slot leak), and surface a terminal {closed, {local,
%% Reason}} to the owner.
-spec connection_fatal(level(), atom(), t()) -> t().
connection_fatal(Level, Reason, State) ->
    State1 = State#state{phase = closed, pending_close = {Level, close_code(Reason)}},
    emit({closed, {local, Reason}}, State1).

%% Map a connection-error reason to its CONNECTION_CLOSE wire error code: a TLS
%% handshake failure becomes a CRYPTO_ERROR (RFC 9001 §4.8: 0x0100 + alert), a
%% transport error maps directly (RFC 9000 §20).
-spec close_code(atom()) -> non_neg_integer().
close_code(Reason) when
    Reason =:= flow_control_error;
    Reason =:= final_size_error;
    Reason =:= stream_state_error;
    Reason =:= stream_limit_error;
    Reason =:= protocol_violation;
    Reason =:= transport_parameter_error
->
    roadrunner_quic_error:code_int(Reason);
close_code(missing_transport_params) ->
    %% RFC 9001 §8.2: a ClientHello without the quic_transport_parameters
    %% extension MUST close with 0x016d, a CRYPTO_ERROR carrying the TLS
    %% missing_extension alert (109).
    roadrunner_quic_error:code_int({crypto_error, 109});
close_code(_TlsReason) ->
    %% Every other connection_fatal reason is a TLS handshake failure (a
    %% malformed or rejected ClientHello, a bad Finished, or an unexpected
    %% message); RFC 9001 §4.8 carries these as CRYPTO_ERROR (0x0100 + alert).
    %% TLS alert 40 (handshake_failure); a per-alert mapping is a refinement.
    roadrunner_quic_error:code_int({crypto_error, 40}).

%% Build and send exactly one CONNECTION_CLOSE at the recorded level (the
%% triggering packet's level, which the peer can decrypt), advancing that
%% space's packet number. Only the close travels (RFC 9000 §10.2.3); no other
%% queued frame is drained. The close always fits the §8.1 budget: it answers a
%% received packet, so 3x bytes-received covers a <=1200-byte close.
-spec send_close(t()) -> {t(), [effect()]}.
send_close(
    #state{
        pending_close = {Level, ErrorCode},
        peer_scid = DCID,
        scid = SCID,
        send_keys = SendKeys,
        amp = Amp
    } = State
) ->
    #{Level := Keys} = SendKeys,
    Space = space(Level, State),
    PN = Space#space.next_pn,
    Frame = {connection_close, transport, ErrorCode, 0, <<>>},
    Entry = #{Level => #{frames => [Frame], keys => Keys, pn => PN}},
    {Datagram, _Sent} = roadrunner_quic_send:datagram(Entry, DCID, SCID),
    case roadrunner_quic_amp:can_send(byte_size(Datagram), Amp) of
        false ->
            %% An Initial close is padded to 1200; for an undersized or spoofed
            %% peer Initial that would exceed the §8.1 3x budget, so drop it
            %% (no amplification reflector). The connection still closes and the
            %% owner still learns via the {closed, _} emit, same as a silent
            %% close.
            {State, []};
        true ->
            Amp1 = roadrunner_quic_amp:sent(byte_size(Datagram), Amp),
            State1 = put_space(Level, Space#space{next_pn = PN + 1}, State#state{amp = Amp1}),
            {State1, [{send, Datagram}]}
    end.

%% Look up a stream, or create it. The first frame of a peer-initiated stream
%% is announced with {stream_opened, Sid} (server-initiated ids never reach
%% here; process_stream/process_reset_stream reject them upstream). Returns
%% the stream, its flow, and the state carrying any queued event.
-spec ensure_stream(non_neg_integer(), t()) ->
    {roadrunner_quic_stream:t(), roadrunner_quic_flow:t(), t()}.
ensure_stream(Sid, #state{streams = Streams, info = #{transport_params := TP}} = State) ->
    case Streams of
        #{Sid := {Stream, Flow}} ->
            {Stream, Flow, State};
        #{} ->
            {
                roadrunner_quic_stream:new(),
                roadrunner_quic_flow:new(#{initial_max_data => stream_recv_window(Sid, TP)}),
                emit({stream_opened, Sid}, State)
            }
    end.

%% The receive window we advertised for a peer-initiated stream (RFC 9000
%% §18.2): client-initiated bidirectional streams (Sid rem 4 == 0) get
%% initial_max_stream_data_bidi_remote, client-initiated unidirectional streams
%% (Sid rem 4 == 2) get initial_max_stream_data_uni. Server-initiated ids never
%% reach here (process_stream/process_reset_stream reject them upstream).
-spec stream_recv_window(non_neg_integer(), roadrunner_quic_transport_params:params()) ->
    non_neg_integer().
stream_recv_window(Sid, #{initial_max_stream_data_bidi_remote := Bidi}) when Sid rem 4 =:= 0 ->
    Bidi;
stream_recv_window(_Sid, #{initial_max_stream_data_uni := Uni}) ->
    Uni.

-spec put_stream(non_neg_integer(), roadrunner_quic_stream:t(), roadrunner_quic_flow:t(), t()) ->
    t().
put_stream(Sid, Stream, Flow, #state{streams = Streams, sendable = Sendable} = State) ->
    %% The single writer of `streams`, so it is also where the `sendable`
    %% working set stays in step: a stream with unsent data/FIN joins it, a
    %% drained or finished one leaves it.
    Sendable1 =
        case roadrunner_quic_stream:send_pending(Stream) of
            true -> ordsets:add_element(Sid, Sendable);
            false -> ordsets:del_element(Sid, Sendable)
        end,
    State#state{streams = Streams#{Sid => {Stream, Flow}}, sendable = Sendable1}.

%% Emit {stream_data, ...} when there are newly-contiguous bytes OR the FIN
%% was reached (the FIN-only {<<>>, true} end-of-stream the h3 layer needs).
-spec deliver_stream(non_neg_integer(), binary(), boolean(), t()) -> t().
deliver_stream(Sid, Deliverable, FinReached, State) when Deliverable =/= <<>>; FinReached ->
    emit({stream_data, Sid, Deliverable, FinReached}, State);
deliver_stream(_Sid, _Deliverable, _FinReached, State) ->
    State.

%% =============================================================================
%% Outbound send pass
%% =============================================================================

-spec send_pass(integer(), t()) -> {t(), [effect()]}.
send_pass(Now, State) ->
    {State1, RevSends} = drain_send(Now, State, []),
    %% `drain_send` returns the send effects newest-first; reverse them into
    %% order and fold the (single) timer effect onto the end in the same pass,
    %% rather than a second traversal to append it.
    {State1, lists:reverse(RevSends, timer_effects(Now, State1))}.

%% Build and send one datagram per iteration until nothing is pending or
%% the anti-amplification budget blocks; roll back the built state if the
%% datagram cannot be sent. Returns the send effects newest-first (the caller
%% reverses them and adds the timer effect).
-spec drain_send(integer(), t(), [effect()]) -> {t(), [effect()]}.
drain_send(Now, State, Acc) ->
    %% The present encryption levels are invariant across a send burst (spaces
    %% are added or discarded only on the receive path), so resolve them once
    %% here rather than on every packet built in the loop.
    drain_send(Now, present_levels(State), State, Acc).

-spec drain_send(integer(), [level()], t(), [effect()]) -> {t(), [effect()]}.
drain_send(Now, Levels, State, Acc) ->
    case build_first(Levels, State) of
        none ->
            {State, Acc};
        {Entries, Built} ->
            #state{peer_scid = DCID, scid = SCID, amp = Amp} = State,
            {Datagram, Sent} = roadrunner_quic_send:datagram(Entries, DCID, SCID),
            case roadrunner_quic_amp:can_send(byte_size(Datagram), Amp) of
                false ->
                    {State, Acc};
                true ->
                    Recorded = record_sent(Now, Sent, Built),
                    Amp1 = roadrunner_quic_amp:sent(byte_size(Datagram), Amp),
                    drain_send(Now, Levels, Recorded#state{amp = Amp1}, [{send, Datagram} | Acc])
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
            %% Retransmits travel in their own packet (no fresh CRYPTO or
            %% STREAM slice), so a replayed frame plus a new slice can never
            %% overflow the datagram.
            build_entry(
                Level, prepend_ack(AckFrames, Pending), Space#space{ack = Ack, pending = []}, State
            );
        [] ->
            build_data(Level, AckFrames, Space#space{ack = Ack}, State)
    end.

%% With nothing pending to retransmit, fill the packet after any ACK with
%% fresh data: CRYPTO at the handshake levels, application STREAM frames at
%% the application level (which never carries CRYPTO).
-spec build_data(level(), [roadrunner_quic_frame:frame()], #space{}, t()) -> none | {map(), t()}.
build_data(application, AckFrames, #space{next_pn = PN} = Space, State) ->
    {StreamFrames, State1} = take_stream(AckFrames, PN, State),
    case prepend_ack(AckFrames, StreamFrames) of
        [] -> none;
        Frames -> build_entry(application, Frames, Space, State1)
    end;
build_data(Level, AckFrames, Space, State) ->
    {CryptoFrames, Crypto} = take_crypto(Space#space.crypto),
    case prepend_ack(AckFrames, CryptoFrames) of
        [] -> none;
        Frames -> build_entry(Level, Frames, Space#space{crypto = Crypto}, State)
    end.

%% Put the ACK frame (if any) ahead of the data frames. `take_ack` yields an
%% empty list or a single `[AckFrame]`, so this prepends without the traversal a
%% list append would cost on the hot send path.
-spec prepend_ack([roadrunner_quic_frame:frame()], [roadrunner_quic_frame:frame()]) ->
    [roadrunner_quic_frame:frame()].
prepend_ack([], Frames) -> Frames;
prepend_ack([Ack], Frames) -> [Ack | Frames].

%% Pull ONE outbound STREAM frame from the lowest-id stream that has data or a
%% FIN to send and the credit to send it, skipping streams blocked by send
%% flow control (a buffered-but-unsendable stream yields `nothing`; a pending
%% FIN-only frame costs no credit and is always emitted). The slice is bounded
%% by the connection and per-stream send windows and by the room left in the
%% datagram after the header, the same-packet ACK, the STREAM frame header, and
%% the AEAD tag (so the datagram fills the 1200-byte path limit without
%% exceeding it); the bytes are accounted against both windows. The same-packet
%% ACK frames and the packet number size the per-datagram room.
-spec take_stream([roadrunner_quic_frame:frame()], non_neg_integer(), t()) ->
    {[roadrunner_quic_frame:frame()], t()}.
take_stream(AckFrames, PN, #state{sendable = Sendable} = State) ->
    %% Only streams with pending send data are candidates, already ascending;
    %% finished/drained streams never enter the walk (see `put_stream/4`).
    take_stream(Sendable, AckFrames, PN, State).

-spec take_stream([non_neg_integer()], [roadrunner_quic_frame:frame()], non_neg_integer(), t()) ->
    {[roadrunner_quic_frame:frame()], t()}.
take_stream([], _AckFrames, _PN, State) ->
    {[], State};
take_stream(
    [Sid | Rest],
    AckFrames,
    PN,
    #state{streams = Streams, conn_flow = ConnFlow, peer_scid = DCID} = State
) ->
    #{Sid := {Stream0, StreamFlow0}} = Streams,
    Offset0 = roadrunner_quic_stream:send_offset(Stream0),
    Budget = lists:min([
        roadrunner_quic_send:stream_data_budget(DCID, PN, AckFrames, Sid, Offset0),
        roadrunner_quic_flow:send_window(ConnFlow),
        roadrunner_quic_flow:send_window(StreamFlow0)
    ]),
    case roadrunner_quic_stream:next_frame(Budget, Stream0) of
        nothing ->
            take_stream(Rest, AckFrames, PN, State);
        {Offset, Data, Fin, Stream1} ->
            Size = byte_size(Data),
            {_, ConnFlow1} = roadrunner_quic_flow:on_data_sent(Size, ConnFlow),
            {_, StreamFlow1} = roadrunner_quic_flow:on_data_sent(Size, StreamFlow0),
            State1 = put_stream(Sid, Stream1, StreamFlow1, State#state{conn_flow = ConnFlow1}),
            {[{stream, Sid, Offset, Data, Fin}], State1}
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

-spec record_sent(integer(), [roadrunner_quic_send:sent()], t()) -> t().
record_sent(Now, Sent, State) ->
    lists:foldl(fun(S, Acc) -> record_one_sent(Now, S, Acc) end, State, Sent).

-spec record_one_sent(integer(), roadrunner_quic_send:sent(), t()) -> t().
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
Handle a fired timer. A probe timeout (`pto`) re-runs loss detection on every
space (queueing any lost frames to retransmit), backs off the probe timeout
(so a probe that detects no loss re-arms strictly later, guaranteeing forward
progress), then runs a send pass. An idle timeout (`idle`) silently closes the
connection (RFC 9000 §10.1, no CONNECTION_CLOSE) and surfaces the terminal
`{closed, _}` event to the owner.
""".
-spec handle_timeout(integer(), atom(), t()) -> {t(), [effect()]}.
handle_timeout(Now, pto, State) ->
    State1 = lists:foldl(fun(Level, S) -> on_pto(Now, Level, S) end, State, present_levels(State)),
    send_pass(Now, State1);
handle_timeout(_Now, idle, State) ->
    drain_emits(emit({closed, {local, idle_timeout}}, State#state{phase = closed})).

%% On a probe timeout: queue any time-threshold losses to retransmit and
%% increment the space's probe-timeout backoff (RFC 9002 §6.2.1), so the
%% next deadline is strictly later. Sending an explicit probe when nothing
%% is detected as lost is deferred with congestion control (it needs the
%% loss layer to surface the oldest unacknowledged frames).
-spec on_pto(integer(), level(), t()) -> t().
on_pto(Now, Level, State) ->
    #space{loss = Loss0, pending = Pending} = Space = space(Level, State),
    {Loss1, Lost} = roadrunner_quic_loss:detect_lost(Now, Loss0),
    Loss2 = roadrunner_quic_loss:on_pto_expired(Loss1),
    put_space(
        Level,
        Space#space{loss = Loss2, pending = lists:reverse(retransmittable(Lost), Pending)},
        State
    ).

%% Arm ONE timer at the nearest deadline: the earliest per-space probe timeout
%% (across spaces with ack-eliciting bytes in flight) or the always-present
%% idle deadline, whichever is sooner. A single nearest-deadline timer keeps
%% the per-datagram re-arm to one timer operation; the loser is re-derived
%% after the winner fires (RFC 9000 §10.1, RFC 9002 §6.2).
-spec timer_effects(integer(), t()) -> [effect()].
timer_effects(Now, State) ->
    {Kind, AtMs} = earliest_deadline(Now, State),
    [{arm_timer, Kind, AtMs}].

-spec earliest_deadline(integer(), t()) -> {pto | idle, integer()}.
earliest_deadline(Now, #state{idle_deadline = Idle} = State) ->
    case earliest_pto(Now, State) of
        undefined -> {idle, Idle};
        PtoAt when PtoAt =< Idle -> {pto, PtoAt};
        _PtoAt -> {idle, Idle}
    end.

-spec earliest_pto(integer(), t()) -> integer() | undefined.
earliest_pto(Now, #state{spaces = Spaces}) ->
    %% The earliest PTO across all spaces; fold the map directly (order is
    %% irrelevant to a min) rather than rebuilding the level list and looking
    %% each space up again.
    maps:fold(
        fun(_Level, Space, Earliest) -> min_defined(Earliest, space_pto(Now, Space)) end,
        undefined,
        Spaces
    ).

-spec space_pto(integer(), #space{}) -> integer() | undefined.
space_pto(Now, #space{loss = Loss}) ->
    case roadrunner_quic_loss:bytes_in_flight(Loss) of
        0 -> undefined;
        _ -> Now + roadrunner_quic_loss:get_pto(Loss)
    end.

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

-spec min_defined(integer() | undefined, integer() | undefined) -> integer() | undefined.
min_defined(undefined, B) -> B;
min_defined(A, undefined) -> A;
min_defined(A, B) -> min(A, B).

%% Flatten the per-packet frame lists a loss returns and keep only the
%% frames worth resending: ACK / PADDING / CONNECTION_CLOSE are regenerated
%% fresh or terminal, never replayed (RFC 9002 §13.3).
%% `roadrunner_quic_send:ack_eliciting/1` is the single source of truth for
%% which frames are ack-eliciting. Callers fold the result onto the existing
%% pending list with `lists:reverse/2` (order within the flushed packet is
%% irrelevant), so no list append is needed.
-spec retransmittable([[roadrunner_quic_frame:frame()]]) -> [roadrunner_quic_frame:frame()].
retransmittable(Lost) ->
    [Frame || Frame <- lists:append(Lost), roadrunner_quic_send:is_ack_eliciting(Frame)].
