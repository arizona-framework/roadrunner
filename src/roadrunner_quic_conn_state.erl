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
%% Exported for direct eunit branch coverage of the idle-timeout negotiation.
-export([negotiated_idle_timeout/2]).
%% Exported so tests can observe the congestion window's growth and backoff.
-export([cwnd/1]).

-export_type([t/0, config/0, effect/0, event/0, info/0]).

%% RFC 9000 §17.2: the server uses a fixed-length SCID so short headers demux.
-define(SCID_LEN, 8).
%% A CRYPTO slice budget that leaves room for the packet header, an ACK
%% frame, and the AEAD tag within the 1200-byte datagram (RFC 9000 §14).
-define(CRYPTO_BUDGET, 1000).
%% Idle-timeout fallback (RFC 9000 §10.1): used only when neither endpoint
%% advertises a max_idle_timeout, so a dead peer cannot pin the connection. The
%% live value is the negotiated minimum of the two advertised limits.
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
    %% walks only these instead of re-sorting and scanning every stream, so
    %% per-pass work is O(streams-with-pending-data); a fully-terminal stream
    %% leaves both this set and `streams` (pruned in `put_stream`).
    sendable = [] :: ordsets:ordset(non_neg_integer()),
    %% Deferred send replies, one per stream id: a synchronous `send_data`
    %% whose bytes did not fully flush this pass (closed flow / congestion
    %% window) is parked here instead of replied, so the stream worker (and
    %% the loop handler's Push) blocks until the buffer drains — the HTTP/3
    %% analogue of h2's defer-ack backpressure. At most one entry per stream:
    %% the worker blocks in `roadrunner_quic:await/3`, so it cannot have a
    %% second `send_data` outstanding. Released by `release_drained/1` (drain
    %% or abort) and `release_all/2` (connection teardown).
    parked = #{} :: #{non_neg_integer() => {pid(), reference()}},
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
    %% Per-type count of peer-initiated stream ordinals opened so far (1 + the
    %% highest ordinal seen). A peer frame for an ordinal below this that is no
    %% longer in `streams` is a late/reordered frame for a pruned stream
    %% (RFC 9000 §3): it is ignored, not recreated as a fresh stream.
    bidi_opened = 0 :: non_neg_integer(),
    uni_opened = 0 :: non_neg_integer(),
    %% Connection-level flow control (RFC 9000 §4).
    conn_flow :: roadrunner_quic_flow:t(),
    %% Connection-wide congestion control (RFC 9002 §7): bounds the bytes in
    %% flight across all spaces by the congestion window, grown on ACK and halved
    %% on loss.
    cc :: roadrunner_quic_cc_newreno:t(),
    %% The client's advertised transport parameters, captured from the
    %% ClientHello. The send windows (connection and per-stream) are seeded from
    %% these so the server never sends past what the peer granted (RFC 9000 §4.1);
    %% empty until the handshake delivers them.
    peer_params = #{} :: roadrunner_quic_transport_params:params(),
    %% Owner events accumulated while folding a datagram's frames, drained in
    %% order at the end of handle_datagram (newest-first, reversed on drain).
    emits = [] :: [effect()],
    %% A locally-detected error to signal: {Level, WireErrorCode} for the one
    %% CONNECTION_CLOSE to transmit at that encryption level. `undefined` for a
    %% live connection or a peer-initiated close (which sends nothing back).
    pending_close = undefined :: undefined | {level(), non_neg_integer()},
    %% The negotiated idle timeout in ms (RFC 9000 §10.1): the minimum of our
    %% advertised max_idle_timeout and the peer's, set from our value at birth and
    %% lowered to the negotiated minimum once the ClientHello delivers the peer's.
    idle_timeout :: non_neg_integer(),
    %% Absolute time (ms) the connection idle-times-out; reset to Now +
    %% idle_timeout on every received datagram (RFC 9000 §10.1). Always set
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
    %% Until the ClientHello delivers the peer's value, the idle timeout is our
    %% own advertised one (RFC 9000 §10.1).
    IdleTimeout = negotiated_idle_timeout(TransportParams, #{}),
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
        cc = roadrunner_quic_cc_newreno:new(),
        idle_timeout = IdleTimeout,
        idle_deadline = Now + IdleTimeout
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

%% The congestion window in bytes (RFC 9002 §7), for tests to observe its
%% slow-start growth and on-loss backoff.
-doc false.
-spec cwnd(t()) -> non_neg_integer().
cwnd(#state{cc = Cc}) ->
    roadrunner_quic_cc_newreno:cwnd(Cc).

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
handle_datagram(
    Now,
    Datagram,
    #state{amp = Amp, recv_keys = RecvKeys, phase = Before, idle_timeout = IdleTimeout} = State0
) ->
    State1 = State0#state{
        amp = roadrunner_quic_amp:received(byte_size(Datagram), Amp),
        idle_deadline = Now + IdleTimeout
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
finish_datagram(_Now, draining, #state{phase = draining} = State) ->
    %% A packet arrived during an established connection's drain window: absorb it
    %% silently (RFC 9000 §10.2.2). Send nothing and arm no timer, so the drain
    %% timer set on entry keeps running in the shell.
    drain_emits(State);
finish_datagram(Now, _Before, #state{phase = draining, pending_close = undefined} = State) ->
    %% Just entered draining via a peer CONNECTION_CLOSE: release any parked
    %% send replies (the send pass is skipped here, so a parked worker would
    %% otherwise stall the whole drain window), deliver {closed, _}, and arm
    %% the drain timer; send nothing.
    {State1, Releases} = release_all({error, closed}, State),
    {State2, EmitEffects} = drain_emits(State1),
    {State2, [{arm_timer, drain, drain_deadline(Now, State2)} | Releases ++ EmitEffects]};
finish_datagram(Now, _Before, #state{phase = draining} = State) ->
    %% Just entered draining via a locally-detected error: send our one
    %% CONNECTION_CLOSE, release any parked send replies, deliver {closed, _},
    %% and arm the drain timer. An established connection's address is
    %% validated, so the close always fits the §8.1 budget (send_close emits
    %% exactly one datagram).
    {State1, [Close]} = send_close(State),
    {State2, Releases} = release_all({error, closed}, State1),
    {State3, EmitEffects} = drain_emits(State2),
    {State3, [Close, {arm_timer, drain, drain_deadline(Now, State3)} | Releases ++ EmitEffects]};
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
handle_call(From, Ref, {close, ErrorCode}, Now, State) ->
    {State1, CloseEffects} = owner_close(ErrorCode, <<>>, Now, State),
    {State1, [{reply, From, Ref, ok} | CloseEffects]};
handle_call(From, Ref, {close, ErrorCode, Reason}, Now, State) ->
    {State1, CloseEffects} = owner_close(ErrorCode, Reason, Now, State),
    {State1, [{reply, From, Ref, ok} | CloseEffects]}.

%% The owner closes the connection (RFC 9000 §10.2.2): send one application
%% CONNECTION_CLOSE (0x1d, carrying the h3 error code and reason phrase) at the
%% 1-RTT level and linger in `draining` for 3x PTO so the peer's reordered
%% packets are absorbed before the shell tears down. The owner triggered this, so
%% no {closed, _} is emitted back; this runs only once the connection is
%% established (1-RTT keys present), which is the only state the owner has a
%% connection to close in. Distinct from connection_fatal/send_close (a
%% locally-detected transport error during datagram processing): this is the
%% application-variant close and never coalesces with other frames.
-spec owner_close(non_neg_integer(), binary(), integer(), t()) -> {t(), [effect()]}.
owner_close(ErrorCode, Reason, Now, #state{send_keys = SendKeys} = State) ->
    case SendKeys of
        #{application := Keys} ->
            send_owner_close(ErrorCode, Reason, Keys, Now, State);
        #{} ->
            %% The owner closed before the handshake completed (e.g. the
            %% connection_handler refusing on max_clients): there are no 1-RTT
            %% keys to carry an application CONNECTION_CLOSE, so close silently
            %% and let the client time out. No 1-RTT packets exist to drain.
            {State#state{phase = closed}, []}
    end.

-spec send_owner_close(non_neg_integer(), binary(), roadrunner_quic_keys:keys(), integer(), t()) ->
    {t(), [effect()]}.
send_owner_close(ErrorCode, Reason, Keys, Now, #state{peer_scid = DCID, scid = SCID} = State) ->
    Space = space(application, State),
    PN = Space#space.next_pn,
    Frame = {connection_close, application, ErrorCode, undefined, Reason},
    Entry = #{application => #{frames => [Frame], keys => Keys, pn => PN}},
    {Datagram, _Sent} = roadrunner_quic_send:datagram(Entry, DCID, SCID),
    State1 = put_space(
        application, Space#space{next_pn = PN + 1}, State#state{phase = draining}
    ),
    %% Release any parked send reply: a streaming worker can be mid-Push when
    %% the owner closes, and this path skips the send pass.
    {State2, Releases} = release_all({error, closed}, State1),
    {State2, [{send, Datagram}, {arm_timer, drain, drain_deadline(Now, State2)} | Releases]}.

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
connection and per-stream send-flow credit. Replies `ok`, or `{error, closed}`
on a draining connection, which sends no application data (RFC 9000 §10.2.2).
""".
-spec handle_send(pid(), reference(), non_neg_integer(), iodata(), boolean(), integer(), t()) ->
    {t(), [effect()]}.
handle_send(From, Ref, _Sid, _IoData, _Fin, _Now, #state{phase = draining} = State) ->
    {State, [{reply, From, Ref, {error, closed}}]};
handle_send(From, Ref, Sid, IoData, Fin, Now, State) ->
    State1 = enqueue_send(Sid, IoData, Fin, State),
    {State2, SendEffects} = send_pass(Now, State1),
    case park_send(Sid, From, Ref, State2) of
        {parked, State3} ->
            %% Backpressure: the bytes did not fully flush, so withhold the
            %% reply. The worker blocks in `await/3` until `release_drained/1`
            %% (from a later send pass once the window opens, or on abort)
            %% emits it. Bytes already went out in SendEffects.
            {State3, SendEffects};
        {reply, Result} ->
            {State2, [{reply, From, Ref, Result} | SendEffects]}
    end.

%% Decide a send's reply: park (withhold) it iff this is a client-initiated
%% bidi request stream (`Sid rem 4 =:= 0`, where response workers write) that
%% is still present, not abandoned, and did not fully drain this pass —
%% mirroring `release_result/2`. An abandoned stream (peer reset / STOP_SENDING)
%% replies `{error, closed}` at once so the worker does not park on a dead
%% stream. A fully-drained or pruned send, or a server-uni control send
%% (`Sid rem 4 =/= 0`, which the conn-loop owner makes synchronously and must
%% never block), replies `ok`.
-spec park_send(non_neg_integer(), pid(), reference(), t()) ->
    {parked, t()} | {reply, ok | {error, closed}}.
park_send(Sid, From, Ref, #state{streams = Streams, parked = Parked} = State) when
    Sid rem 4 =:= 0
->
    case Streams of
        #{Sid := {Stream, _Flow}} ->
            case roadrunner_quic_stream:send_abandoned(Stream) of
                true ->
                    {reply, {error, closed}};
                false ->
                    case roadrunner_quic_stream:send_pending(Stream) of
                        true -> {parked, State#state{parked = Parked#{Sid => {From, Ref}}}};
                        false -> {reply, ok}
                    end
            end;
        #{} ->
            {reply, ok}
    end;
park_send(_Sid, _From, _Ref, _State) ->
    {reply, ok}.

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
stream_for_send(
    Sid,
    #state{streams = Streams, info = #{transport_params := TP}, peer_params = PeerParams} = State
) ->
    case Streams of
        #{Sid := {Stream, Flow}} ->
            {Stream, Flow, State};
        #{} ->
            %% A server-first stream (response on a client request stream, or a
            %% server control / QPACK stream): seed its send window from what the
            %% client granted for that stream type, like the receive path does.
            Flow = roadrunner_quic_flow:new(#{
                initial_max_data => stream_recv_window(Sid, TP),
                peer_initial_max_data => peer_stream_send_window(Sid, PeerParams)
            }),
            {roadrunner_quic_stream:new(), Flow, State}
    end.

-spec process_outcome(integer(), roadrunner_quic_recv:outcome(), t()) -> t().
process_outcome(_Now, _Outcome, #state{phase = Phase} = State) when
    Phase =:= closed; Phase =:= draining
->
    %% A close fired on an earlier packet in this datagram, or a packet arrived
    %% during the drain window: skip the rest so we neither act on their frames
    %% nor discard (via validate_on_handshake) the space and keys a pending local
    %% close still needs to send its frame.
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
process_frame(_Now, _Level, _Frame, #state{phase = Phase} = State) when
    Phase =:= closed; Phase =:= draining
->
    %% A CONNECTION_CLOSE earlier in this packet already closed the connection, or
    %% the packet arrived during the drain window; ignore the remaining frames
    %% (RFC 9000 §10.2.2).
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
process_frame(_Now, application, {max_data, Max}, #state{conn_flow = ConnFlow} = State) ->
    %% Peer raised the connection-level send limit (RFC 9000 §4.1): grow the
    %% send window so a transfer past the initial grant keeps flowing. The send
    %% pass at the end of the datagram serves any stream this unblocks.
    State#state{conn_flow = roadrunner_quic_flow:on_max_data_received(Max, ConnFlow)};
process_frame(_Now, application, {max_stream_data, Sid, Max}, State) ->
    on_max_stream_data(Sid, Max, State);
process_frame(_Now, application, {stop_sending, Sid, ErrorCode}, State) ->
    process_stop_sending(Sid, ErrorCode, State);
process_frame(_Now, _Level, _Frame, State) ->
    %% ping / padding are no-ops. MAX_STREAMS is accepted but not yet acted on
    %% (the server never opens enough streams to need the raised limit).
    State.

%% Raise a stream's send limit from a received MAX_STREAM_DATA (RFC 9000 §4.1).
%% Only a tracked stream can have unsent data to unblock; a grant for an unknown
%% id is ignored.
-spec on_max_stream_data(non_neg_integer(), non_neg_integer(), t()) -> t().
on_max_stream_data(Sid, Max, #state{streams = Streams} = State) ->
    case Streams of
        #{Sid := {Stream, Flow}} ->
            put_stream(Sid, Stream, roadrunner_quic_flow:on_max_data_received(Max, Flow), State);
        #{} ->
            State
    end.

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
process_handshake(
    initial,
    {?CLIENT_HELLO, Body},
    #state{tls = Tls, info = #{transport_params := #{initial_max_data := OurMaxData} = OurParams}} =
        State
) ->
    case roadrunner_quic_tls_server:process_client_hello(Body, Tls) of
        {ok, #{initial := InitialFlight, handshake := HandshakeFlight}, Installs, PeerParams, Tls1} ->
            %% Seed the connection send window from the client's advertised
            %% initial_max_data (absent -> 0, RFC 9000 §18.2), not a default. Safe
            %% to re-create conn_flow here: no 1-RTT data flows before the
            %% handshake completes.
            ConnFlow = roadrunner_quic_flow:new(#{
                initial_max_data => OurMaxData,
                peer_initial_max_data => maps:get(initial_max_data, PeerParams, 0)
            }),
            %% Lower the idle timeout to the negotiated minimum (RFC 9000 §10.1)
            %% now that the peer's advertised value is known.
            IdleTimeout = negotiated_idle_timeout(OurParams, PeerParams),
            State1 = install_keys(
                Installs,
                State#state{
                    tls = Tls1,
                    peer_params = PeerParams,
                    conn_flow = ConnFlow,
                    idle_timeout = IdleTimeout
                }
            ),
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
process_ack(Now, Level, Ack, #state{cc = Cc} = State) ->
    Space = space(Level, State),
    case roadrunner_quic_loss:on_ack_received(Ack, Now, Space#space.loss) of
        {error, _} ->
            State;
        {Loss, _Acked, Lost} ->
            Cc1 = apply_cc_signal(roadrunner_quic_loss:cc_signal(Loss), Now, Cc),
            put_space(
                Level,
                Space#space{
                    loss = Loss, pending = lists:reverse(retransmittable(Lost), Space#space.pending)
                },
                State#state{cc = Cc1}
            )
    end.

%% Feed the loss layer's per-ACK congestion signal to NewReno: grow the window
%% for the acknowledged bytes first, then react to any loss (RFC 9002 §7.3, ack
%% before loss). A defined largest-acked send time means the largest acked was
%% ack-eliciting, so the acked bytes are positive; `undefined` (nothing newly
%% acked, or a non-ack-eliciting largest) skips the growth.
-spec apply_cc_signal(roadrunner_quic_loss:cc_signal(), integer(), roadrunner_quic_cc_newreno:t()) ->
    roadrunner_quic_cc_newreno:t().
apply_cc_signal(
    #{acked_bytes := AckedBytes, largest_acked_time := AckedTime, largest_lost_time := LostTime},
    Now,
    Cc
) ->
    Grown =
        case AckedTime of
            undefined -> Cc;
            _ -> roadrunner_quic_cc_newreno:on_packets_acked(AckedBytes, AckedTime, Cc)
        end,
    case LostTime of
        undefined -> Grown;
        _ -> roadrunner_quic_cc_newreno:on_congestion_event(LostTime, Now, Grown)
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
    case ensure_stream(Sid, State) of
        closed ->
            %% Late/reordered STREAM frame for a pruned stream (RFC 9000 §3): the
            %% packet is still acknowledged, but the frame is ignored.
            State;
        {ok, Stream0, StreamFlow0, State1} ->
            #state{conn_flow = ConnFlow} = State1,
            Delta = max(
                0, Offset + byte_size(Data) - roadrunner_quic_flow:bytes_received(StreamFlow0)
            ),
            maybe
                {ok, ConnFlow1} ?= roadrunner_quic_flow:on_data_received(Delta, ConnFlow),
                {ok, StreamFlow1} ?= roadrunner_quic_flow:on_data_received(Delta, StreamFlow0),
                {ok, Deliverable, FinReached, Stream1} ?=
                    roadrunner_quic_stream:receive_data(Offset, Data, Fin, Stream0),
                {ConnFlow2, State2} = grant_conn_credit(ConnFlow1, State1),
                {StreamFlow2, State3} = grant_stream_credit(Sid, StreamFlow1, State2),
                State4 = put_stream(Sid, Stream1, StreamFlow2, State3#state{conn_flow = ConnFlow2}),
                deliver_stream(Sid, Deliverable, FinReached, State4)
            else
                {error, Reason} -> connection_fatal(application, Reason, State)
            end
    end.

%% Refill the connection-level receive window as the peer consumes it (RFC 9000
%% §4.1): once more than the refill threshold is used, advertise a fresh window
%% with a MAX_DATA frame so a large upload keeps flowing instead of stalling at
%% the initial grant.
-spec grant_conn_credit(roadrunner_quic_flow:t(), t()) -> {roadrunner_quic_flow:t(), t()}.
grant_conn_credit(ConnFlow, State) ->
    case roadrunner_quic_flow:should_send_max_data(ConnFlow) of
        true ->
            {NewMax, ConnFlow1} = roadrunner_quic_flow:grant_max_data(ConnFlow),
            {ConnFlow1, queue_frame(application, {max_data, NewMax}, State)};
        false ->
            {ConnFlow, State}
    end.

%% Refill a stream's receive window the same way, with MAX_STREAM_DATA.
-spec grant_stream_credit(non_neg_integer(), roadrunner_quic_flow:t(), t()) ->
    {roadrunner_quic_flow:t(), t()}.
grant_stream_credit(Sid, StreamFlow, State) ->
    case roadrunner_quic_flow:should_send_max_data(StreamFlow) of
        true ->
            {NewMax, StreamFlow1} = roadrunner_quic_flow:grant_max_data(StreamFlow),
            {StreamFlow1, queue_frame(application, {max_stream_data, Sid, NewMax}, State)};
        false ->
            {StreamFlow, State}
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
    case ensure_stream(Sid, State) of
        closed ->
            %% Late/reordered RESET_STREAM for a pruned stream (RFC 9000 §3).
            State;
        {ok, Stream0, Flow, State1} ->
            case roadrunner_quic_stream:reset(FinalSize, Stream0) of
                {ok, Stream1} ->
                    emit({stream_reset, Sid, ErrorCode}, put_stream(Sid, Stream1, Flow, State1));
                {error, Reason} ->
                    connection_fatal(application, Reason, State)
            end
    end.

%% Peer STOP_SENDING (RFC 9000 §3.5): the peer will not read more of our
%% response on this stream. Abandon our send side — `stop_sending/1` discards
%% the unsent buffer and marks the stream send-stopped, so a parked send reply
%% releases with `{error, closed}` (via `release_drained/1` at the end of this
%% datagram) instead of `ok` — and surface it to the owner as a stream reset so
%% a response worker stops (reusing the reset routing) rather than buffering more
%% onto a stopped stream. A frame for a stream we hold no send state for is
%% ignored, like a late RESET_STREAM.
-spec process_stop_sending(non_neg_integer(), non_neg_integer(), t()) -> t().
process_stop_sending(Sid, ErrorCode, #state{streams = Streams} = State) ->
    case Streams of
        #{Sid := {Stream0, Flow}} ->
            Stream1 = roadrunner_quic_stream:stop_sending(Stream0),
            State1 = put_stream(Sid, Stream1, Flow, State),
            emit({stream_reset, Sid, ErrorCode}, State1);
        #{} ->
            State
    end.

%% A well-placed peer CONNECTION_CLOSE (transport at any level, or application
%% at 1-RTT) ends the connection: surface it to the owner and move to the
%% terminal phase so the send pass is skipped. An established connection lingers
%% in `draining` (closing_phase/1) to absorb the peer's reordered 1-RTT packets;
%% a handshake-phase close ends at once.
-spec process_close(non_neg_integer(), t()) -> t().
process_close(ErrorCode, State) ->
    emit({closed, {peer, ErrorCode}}, State#state{phase = closing_phase(State)}).

%% Close this single, isolated connection on a peer-reachable protocol error
%% (flow control §4.1, final size §4.5, stream state §19.8, an out-of-place
%% application CONNECTION_CLOSE §19.19, or a failed TLS handshake): record a
%% CONNECTION_CLOSE to transmit at the triggering packet's level (Level), move to
%% the terminal phase so the fold short-circuits and the shell tears down cleanly
%% (no crash, no slot leak), and surface a terminal {closed, {local, Reason}} to
%% the owner. An established connection lingers in `draining` (closing_phase/1).
-spec connection_fatal(level(), atom(), t()) -> t().
connection_fatal(Level, Reason, State) ->
    State1 = State#state{
        phase = closing_phase(State), pending_close = {Level, close_code(Reason)}
    },
    emit({closed, {local, Reason}}, State1).

%% The terminal phase a close moves to (RFC 9000 §10.2): an established
%% connection lingers in `draining` for 3x PTO so the peer's reordered 1-RTT
%% packets are absorbed before its connection id is freed; a close during the
%% handshake has no 1-RTT packets to absorb, so it ends immediately (and a
%% handshake flood cannot accrue lingering draining connections).
-spec closing_phase(t()) -> phase().
closing_phase(#state{phase = connected}) -> draining;
closing_phase(_State) -> closed.

%% The absolute time the drain window ends: three PTOs from now (RFC 9000 §10.2),
%% the largest across the still-present spaces.
-spec drain_deadline(integer(), t()) -> integer().
drain_deadline(Now, State) ->
    Now + 3 * max_pto(State).

-spec max_pto(t()) -> non_neg_integer().
max_pto(#state{spaces = Spaces}) ->
    maps:fold(
        fun(_Level, #space{loss = Loss}, Acc) -> max(Acc, roadrunner_quic_loss:get_pto(Loss)) end,
        0,
        Spaces
    ).

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

%% Look up a peer stream and return `{ok, Stream, Flow, State}`: an existing
%% entry, or a fresh one for a genuinely new id (announced with
%% {stream_opened, Sid}). A first frame of a new id advances the per-type
%% high-water; an id at or below the high-water that is no longer tracked was
%% opened and pruned, so `closed` is returned and the frame ignored (RFC 9000
%% §3). Server-initiated ids never reach here (rejected upstream).
-spec ensure_stream(non_neg_integer(), t()) ->
    {ok, roadrunner_quic_stream:t(), roadrunner_quic_flow:t(), t()} | closed.
ensure_stream(Sid, #state{streams = Streams} = State) ->
    case Streams of
        #{Sid := {Stream, Flow}} ->
            {ok, Stream, Flow, State};
        #{} ->
            case opened_before(Sid, State) of
                true -> closed;
                false -> open_stream(Sid, State)
            end
    end.

%% Whether `Sid`'s ordinal is below the per-type high-water: it was opened
%% earlier and, since it is no longer in `streams`, has been pruned.
-spec opened_before(non_neg_integer(), t()) -> boolean().
opened_before(Sid, #state{bidi_opened = Opened}) when Sid rem 4 =:= 0 ->
    Sid div 4 < Opened;
opened_before(Sid, #state{uni_opened = Opened}) ->
    Sid div 4 < Opened.

%% Create a fresh peer stream, advance the per-type high-water past its ordinal,
%% and announce it with {stream_opened, Sid}.
-spec open_stream(non_neg_integer(), t()) ->
    {ok, roadrunner_quic_stream:t(), roadrunner_quic_flow:t(), t()}.
open_stream(Sid, #state{info = #{transport_params := TP}, peer_params = PeerParams} = State) ->
    Stream = roadrunner_quic_stream:new(),
    Flow = roadrunner_quic_flow:new(#{
        initial_max_data => stream_recv_window(Sid, TP),
        peer_initial_max_data => peer_stream_send_window(Sid, PeerParams)
    }),
    {ok, Stream, Flow, emit({stream_opened, Sid}, bump_opened(Sid, State))}.

%% The send window for a stream the server writes to: the limit the client
%% advertised for that stream type (RFC 9000 §18.2; absent -> 0). A
%% client-initiated bidi (request) stream where the server sends the response
%% uses initial_max_stream_data_bidi_local; a server-initiated uni (control /
%% QPACK) stream uses initial_max_stream_data_uni. A client uni stream is
%% receive-only for the server, so 0.
-spec peer_stream_send_window(non_neg_integer(), roadrunner_quic_transport_params:params()) ->
    non_neg_integer().
peer_stream_send_window(Sid, PeerParams) when Sid rem 4 =:= 0 ->
    maps:get(initial_max_stream_data_bidi_local, PeerParams, 0);
peer_stream_send_window(Sid, PeerParams) when Sid rem 4 =:= 3 ->
    maps:get(initial_max_stream_data_uni, PeerParams, 0);
peer_stream_send_window(_Sid, _PeerParams) ->
    0.

%% The effective idle timeout (RFC 9000 §10.1): the minimum of the two advertised
%% max_idle_timeout values, or the only non-zero one. A zero or absent value on a
%% side means "no limit from me"; with neither side advertising one we fall back
%% to ?IDLE_TIMEOUT so a dead peer cannot pin the connection open.
-spec negotiated_idle_timeout(
    roadrunner_quic_transport_params:params(), roadrunner_quic_transport_params:params()
) -> non_neg_integer().
negotiated_idle_timeout(OurParams, PeerParams) ->
    Ours = maps:get(max_idle_timeout, OurParams, 0),
    Peer = maps:get(max_idle_timeout, PeerParams, 0),
    case {Ours, Peer} of
        {0, 0} -> ?IDLE_TIMEOUT;
        {0, P} -> P;
        {O, 0} -> O;
        {O, P} -> min(O, P)
    end.

%% Advance the per-type high-water past `Sid`'s ordinal. Opening a bidi stream
%% also tops up the peer's bidi-stream credit.
-spec bump_opened(non_neg_integer(), t()) -> t().
bump_opened(Sid, #state{bidi_opened = Opened} = State) when Sid rem 4 =:= 0 ->
    grant_max_streams_bidi(State#state{bidi_opened = max(Opened, Sid div 4 + 1)});
bump_opened(Sid, #state{uni_opened = Opened} = State) ->
    State#state{uni_opened = max(Opened, Sid div 4 + 1)}.

%% Keep the peer in bidi-stream credit (RFC 9000 §4.6): once the opened count is
%% within a quarter-window of the advertised limit, raise the limit to a fresh
%% window above what is opened and queue a MAX_STREAMS so the peer can keep
%% opening request streams. Mirrors the receive-flow MAX_DATA refill
%% (`roadrunner_quic_flow`, the 3/4 threshold); the window is the originally
%% advertised `initial_max_streams_bidi`.
-spec grant_max_streams_bidi(t()) -> t().
grant_max_streams_bidi(
    #state{
        bidi_opened = Opened,
        max_streams_bidi = Max,
        info = #{transport_params := #{initial_max_streams_bidi := Window}}
    } = State
) ->
    case Opened > Max - Window * 3 div 4 of
        true ->
            NewMax = Opened + Window,
            queue_frame(
                application, {max_streams, bidi, NewMax}, State#state{max_streams_bidi = NewMax}
            );
        false ->
            State
    end.

%% Our advertised receive window for a stream by type (RFC 9000 §18.2):
%% client-initiated bidirectional streams (Sid rem 4 == 0) get
%% initial_max_stream_data_bidi_remote; every other type gets
%% initial_max_stream_data_uni. The receive path passes only client-initiated
%% ids; the send path (stream_for_send) also passes server uni ids, where the
%% receive window is moot since the server never receives there.
-spec stream_recv_window(non_neg_integer(), roadrunner_quic_transport_params:params()) ->
    non_neg_integer().
stream_recv_window(Sid, #{initial_max_stream_data_bidi_remote := Bidi}) when Sid rem 4 =:= 0 ->
    Bidi;
stream_recv_window(_Sid, #{initial_max_stream_data_uni := Uni}) ->
    Uni.

-spec put_stream(non_neg_integer(), roadrunner_quic_stream:t(), roadrunner_quic_flow:t(), t()) ->
    t().
put_stream(Sid, Stream, Flow, #state{streams = Streams, sendable = Sendable} = State) ->
    %% The single writer of `streams`. A fully-terminal stream (both directions
    %% finished) is pruned so the map stays bounded to live streams; the
    %% high-water keeps a late frame for its id from recreating it. Otherwise it
    %% is stored and the `sendable` working set kept in step (unsent data/FIN
    %% joins it, a drained one leaves it). An abandoned send side (peer
    %% RESET_STREAM left `aborted`, or STOP_SENDING / local reset set
    %% `send_stopped`) leaves `sendable` even with buffered bytes, so the send
    %% pass never emits STREAM frames on a stream the peer reset.
    case roadrunner_quic_stream:is_terminal(Stream) of
        true ->
            State#state{
                streams = maps:remove(Sid, Streams),
                sendable = ordsets:del_element(Sid, Sendable)
            };
        false ->
            Sendable1 =
                case
                    roadrunner_quic_stream:send_pending(Stream) andalso
                        not roadrunner_quic_stream:send_abandoned(Stream)
                of
                    true -> ordsets:add_element(Sid, Sendable);
                    false -> ordsets:del_element(Sid, Sendable)
                end,
            State#state{streams = Streams#{Sid => {Stream, Flow}}, sendable = Sendable1}
    end.

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
    %% Release any parked send reply whose stream drained (or was aborted)
    %% this pass. The release effects ride AFTER the reversed sends so the
    %% bytes are on the wire before the worker is told it may send more
    %% (`perform/3` folds effects left-to-right). This is the single choke
    %% point: every flow / congestion relief (MAX_STREAM_DATA, MAX_DATA, an
    %% ACK growing cwnd) runs in the datagram fold before `finish_datagram`
    %% calls `send_pass`, so the scan here catches them all.
    {State2, Releases} = release_drained(State1),
    %% `drain_send` returns the send effects newest-first; reverse them into
    %% order and fold the releases + the (single) timer effect onto the end in
    %% the same pass, rather than a second traversal to append them.
    {State2, lists:reverse(RevSends, Releases ++ timer_effects(Now, State2))}.

%% Release each parked reply whose stream can no longer make progress toward
%% draining: the stream is gone (pruned after its FIN flushed -> `ok`), its
%% send side was abandoned by a reset / STOP_SENDING (`send_abandoned/1` ->
%% `{error, closed}`, so a streaming worker does not treat the data as sent
%% and re-send to a dead stream), or it fully drained (`ok`). A stream still
%% holding unsent bytes stays parked. Each released entry is removed from
%% `parked`, so a later scan in the same datagram cannot double-reply.
-spec release_drained(t()) -> {t(), [effect()]}.
release_drained(#state{parked = Parked, streams = Streams} = State) ->
    {Parked1, Effects} = maps:fold(
        fun(Sid, {From, Ref}, {Acc, Eff}) ->
            case release_result(Sid, Streams) of
                keep -> {Acc#{Sid => {From, Ref}}, Eff};
                Result -> {Acc, [{reply, From, Ref, Result} | Eff]}
            end
        end,
        {#{}, []},
        Parked
    ),
    {State#state{parked = Parked1}, Effects}.

%% The reply value for a parked stream id, or `keep` to leave it parked.
-spec release_result(non_neg_integer(), #{non_neg_integer() => stream()}) ->
    ok | {error, closed} | keep.
release_result(Sid, Streams) ->
    case Streams of
        #{Sid := {Stream, _Flow}} ->
            case roadrunner_quic_stream:send_abandoned(Stream) of
                true ->
                    {error, closed};
                false ->
                    case roadrunner_quic_stream:send_pending(Stream) of
                        true -> keep;
                        false -> ok
                    end
            end;
        #{} ->
            %% Pruned (terminal: its FIN flushed) — the send completed.
            ok
    end.

%% Release every parked reply with `Result`, clearing the map. Used by the
%% connection-teardown paths (draining / closed / owner close / idle) that
%% skip `send_pass`, so a parked worker unblocks promptly instead of stalling
%% until its conn monitor fires on the eventual process exit.
-spec release_all(term(), t()) -> {t(), [effect()]}.
release_all(Result, #state{parked = Parked} = State) ->
    Effects = [{reply, From, Ref, Result} || {From, Ref} <- maps:values(Parked)],
    {State#state{parked = #{}}, Effects}.

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
            #state{peer_scid = DCID, scid = SCID, amp = Amp, cc = Cc} = State,
            {Datagram, Sent} = roadrunner_quic_send:datagram(Entries, DCID, SCID),
            %% Gate ack-eliciting datagrams on the congestion window (RFC 9002
            %% §7); ACK-only datagrams are not congestion-controlled and always
            %% pass. On a block, return the pre-build State so the consumed ACK /
            %% stream slice stays pending for the next pass.
            AckEliciting = lists:any(fun(#{ack_eliciting := Elicit}) -> Elicit end, Sent),
            CcOk =
                not AckEliciting orelse
                    roadrunner_quic_cc_newreno:can_send(total_bytes_in_flight(State), Cc),
            case roadrunner_quic_amp:can_send(byte_size(Datagram), Amp) andalso CcOk of
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
    %% Release any parked send reply before the shell tears down, so a parked
    %% worker unblocks and runs its disconnect path cleanly rather than only
    %% crashing on the conn-process exit its monitor sees.
    {State1, Releases} = release_all({error, closed}, State),
    {State2, EmitEffects} = drain_emits(
        emit({closed, {local, idle_timeout}}, State1#state{phase = closed})
    ),
    {State2, Releases ++ EmitEffects};
handle_timeout(_Now, drain, State) ->
    %% The drain window elapsed (RFC 9000 §10.2): become closed so the shell
    %% tears the connection down. The owner already learned of the close on entry.
    {State#state{phase = closed}, []}.

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

%% The congestion-controlled bytes in flight across every space, the value the
%% congestion window bounds (RFC 9002 §B.2 keeps one count per connection). A
%% discarded space leaves the map, so its in-flight cannot count stale.
-spec total_bytes_in_flight(t()) -> non_neg_integer().
total_bytes_in_flight(#state{spaces = Spaces}) ->
    maps:fold(
        fun(_Level, #space{loss = Loss}, Total) ->
            Total + roadrunner_quic_loss:bytes_in_flight(Loss)
        end,
        0,
        Spaces
    ).

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
