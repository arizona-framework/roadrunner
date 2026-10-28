-module(roadrunner_conn_loop).
-moduledoc false.

%% Tail-recursive per-connection process for HTTP/1.1.
%%
%% The lifecycle (`awaiting_shoot → reading_request → reading_body →
%% dispatching → finishing → loop or close`) is expressed as direct
%% function calls between phase functions. No `gen_statem` dispatch,
%% no per-request timer arms in the steady state.
%%
%% ## Recv paths
%%
%% Waiting for the **first byte** of a request (`recv_idle/2`) is
%% active-mode: `{active, once}` + `receive`, parked until bytes, a close
%% or a drain arrive. A conn can sit here for the whole keep-alive
%% window, so it must cost nothing while it does — and a drain is seen
%% the moment it is sent. The deadline rides the receive's own `after`,
%% so there is still no `start_timer` / `cancel_timer` per request.
%%
%% Reading the **rest of a request already in flight** is **passive
%% recv** — `gen_tcp:recv(Socket, 0, ChunkTimeout)`, which bypasses
%% `gen_tcp_socket`'s gen_statem dispatch (saves ~7 % CPU on the hot
%% path: `gen:do_call/4`, `recv_data_deliver/4`, `gen_statem:loop/3`,
%% `nif_getopt/3`). Passive recv cannot see the mailbox, so it wakes
%% every `roadrunner_conn:drain_check_interval_ms/0` (100 ms) to look
%% for a drain; that only applies mid-request, where the peer is already
%% sending and a graceful drain would let the request finish regardless.
%% The body read in `roadrunner_conn:recv_body_chunk/4` is the same
%% shape for the same reason.
%%
%% Keeping the poll off the idle path matters because its cost scales
%% with *connections* rather than requests: 1024 idle keep-alive conns
%% polling at 100 ms burned ~1.2 cores doing nothing, which is invisible
%% at saturation but dominates a mostly-idle server.
%%
%% When the listener sets `hibernate_after => Ms > 0`, the first-byte
%% wait instead uses `recv_active/3`, whose `after Ms` clause has
%% a window to call `erlang:hibernate/3` between keep-alive iterations so
%% the conn's heap GCs and shrinks — only `receive` supports hibernation;
%% passive recv blocks the process inside a NIF.
%%
%% ## Phase introspection vs hot-path cost
%%
%% The label set on the conn process via `proc_lib:set_label/1` is
%% written **at most twice per conn** on plain TCP, three times on TLS:
%% once at `init_loop` time (`{roadrunner_conn, awaiting_shoot,
%% ListenerName}`), once more on a TLS listener when `shoot` starts the
%% handshake (`{roadrunner_conn, tls_handshake, ListenerName}` — the one
%% pre-serve phase that can park for up to `tls_handshake_timeout` on a
%% silent peer, so an `observer` snapshot must tell it apart from a conn
%% that was never shot), and once in `refine_conn_label/2`, which
%% rewrites it to include the peer. The phases AFTER that (read_request,
%% read_body, dispatching, finishing) run in microseconds on the happy
%% path — too fast for an operator's `observer` snapshot to catch a
%% specific phase anyway. Per-phase label updates measured ~1.2 % CPU on
%% hello (4 writes/req, each touching the process dictionary) and
%% contributed to run-to-run variance. Stuck conns still surface via the
%% conn-entry label and the `reading_request` idle window (where
%% hibernation parks the process).
%%
%% ## Stability features preserved
%%
%% Drain via registry broadcast, slot tracking via atomics, full event
%% pairing (`request_start` then `request_stop | request_exception` on
%% one span), HEAD body suppression, `Expect: 100-continue`,
%% anti-Slowloris rate-check on the request-read phase, all five
%% response shapes (buffered, `{stream, ...}`, `{loop, ...}`,
%% `{sendfile, ...}`, `{websocket, ...}`).

-export([start/2]).

%% Internal entries — invoked via `proc_lib:start/3` and via
%% `erlang:hibernate/3`. Must stay exported so the runtime can
%% re-enter them after wake-from-hibernate.
-export([init_loop/3, recv_request_bytes_hib/3]).

%% Loop-state record carried through every phase. Allocated once on
%% the transition out of `awaiting_shoot` and pattern-matched (not
%% reconstructed) thereafter, so the per-request hot path stays
%% allocation-light.
-record(loop_state, {
    socket :: roadrunner_transport:socket(),
    proto_opts :: roadrunner_conn:proto_opts(),
    listener_name :: atom(),
    %% The event handler's span from `roadrunner_event:listener_accept/2`,
    %% fired once the peer is settled. Paired with `listener_conn_close`
    %% in `exit_clean/5`.
    conn_span :: roadrunner_event_handler:span(),
    peer :: {inet:ip_address(), inet:port_number()} | undefined,
    %% The connection queries each request carries (`roadrunner_req:sockname/1`
    %% and the rest), built once per connection.
    conn_info :: roadrunner_req:conn_info(),
    scheme = http :: http | https,
    %% `first` for the first request on a fresh conn; `keep_alive` for
    %% subsequent loop-back iterations. Drives the timeout selection
    %% (request_timeout vs keep_alive_timeout) and the silent-vs-408
    %% behavior in `recv_request_bytes/2`'s `after` clause.
    phase = first :: first | keep_alive,
    %% Cumulative successfully-served requests on this conn. Bumped
    %% in `run_pipeline/4` after each successful dispatch; checked in
    %% `finishing_phase/3` against `max_keep_alive_requests`.
    requests_served = 0 :: non_neg_integer(),
    %% Bytes received but not yet parsed. Empty on first iteration;
    %% populated mid-recv when `parse_request/1` returns `{more, _}`,
    %% AND on the keep-alive loop-back when a prior request's body
    %% drain leaves post-body bytes (RFC 9112 §9.3.2 pipelining).
    buffered = <<>> :: binary(),
    %% Pre-generated `request_id`s. Filled lazily (on first request)
    %% by `roadrunner_conn:generate_request_id/1` — 256 random bytes
    %% hex-encoded per batch, 16 characters sliced per request. Empty
    %% buffer triggers a refill. Threaded via the loop_state to
    %% avoid process-dictionary writes.
    req_id_buffer = <<>> :: binary(),
    %% Conn-stable values pulled from `proto_opts` once at `shoot`
    %% time so the per-request hot path doesn't re-`maps:get` them.
    %% Saves ~8 hash lookups per request.
    requests_counter :: atomics:atomics_ref() | undefined,
    dispatch :: roadrunner_conn:dispatch() | undefined,
    middlewares = [] :: roadrunner_middleware:middleware_list(),
    max_content_length = 0 :: non_neg_integer(),
    max_keep_alive_requests = 1 :: pos_integer(),
    %% Read-phase deadlines: `request_timeout` for the first request on a
    %% fresh conn, `keep_alive_timeout` for keep-alive loop-backs. Picked
    %% by `phase_timeout/1` per `phase`.
    request_timeout = 0 :: non_neg_integer(),
    keep_alive_timeout = 0 :: non_neg_integer(),
    %% `auto` reads the full body synchronously; `manual` builds a
    %% body_reader the handler pulls from. Drives `read_body_phase/3`.
    body_buffering = auto :: auto | manual,
    %% How `recv_request_bytes/2` waits for bytes: the socket's read mode
    %% (`read_mode/2`), paired with `proto_opts.hibernate_after` when that
    %% is set. `once` arms the socket before each request and reads the
    %% rest of one passively; with hibernation the whole request is read
    %% in `receive`. `N` arms it with `{active, N}` once per connection,
    %% takes every read from the mailbox, and arms it again on the passive
    %% message, so a request costs no socket call: on TLS each is a call
    %% into the TLS connection process. Writer-owned responses get a
    %% passive socket (`disarm/1`). One field for both keeps the record,
    %% copied on every update, at its size: an extra field measured as a
    %% higher GC share and fewer requests per second on plain TCP.
    recv_mode = once :: recv_mode(),
    %% Precomputed `Alt-Svc` value (h3 co-serving), or `undefined`.
    %% Prepended to every response, by `roadrunner_http1:response/4` for
    %% the keep-alive shapes and `roadrunner_http:auto_headers/2` for
    %% stream / loop.
    alt_svc = undefined :: binary() | undefined,
    %% HTTP/1 inbound size limits as the
    %% `{max_request_line, max_header_line, max_header_block, max_header_count}`
    %% tuple `roadrunner_http1:parse_request/2` takes. Cached from the
    %% `http1_*` proto_opts keys at `shoot` (defaults match the parser's
    %% own `?MAX_*` macros).
    http1_limits = {8192, 8192, 10240, 100} ::
        {pos_integer(), pos_integer(), pos_integer(), pos_integer()},
    %% Anti-slowloris on the request-read phase. `min_rate` is cached
    %% from `proto_opts.min_bytes_per_second` at `shoot`. When > 0,
    %% `recv_passive/2` tracks bytes received since `recv_phase_start`
    %% and closes the conn if the running average drops below
    %% `min_rate` after a 1 s grace (matches `roadrunner_conn:rate_ok/3`).
    %% `recv_phase_bytes` is reset to 0 at every `read_request_phase`
    %% entry; `recv_phase_start` is then anchored at the first byte of
    %% that request (per-request window, idle keep-alive gap excluded).
    min_rate = 0 :: non_neg_integer(),
    recv_phase_start = 0 :: integer(),
    recv_phase_bytes = 0 :: non_neg_integer(),
    %% Per-peer rate-limit guard resolved from `proto_opts` + peer once at
    %% `shoot` (`undefined` when off — the common case, a single branch in
    %% `dispatch_phase/3`).
    rate_limit = undefined :: roadrunner_conn:rate_limit_state(),
    %% The listener's in-flight ceiling, which an HTTP/1 request joins only
    %% in `shed` overload mode (`undefined` otherwise, the common case, a
    %% single branch per request). `idle` between requests, `held` from the
    %% slot's acquire in `admit/3` until the request ends, so an exit path
    %% knows whether it has a slot to hand back.
    request_slot = undefined ::
        undefined
        | {idle | held, pos_integer(), counters:counters_ref(), roadrunner_conn:overload()},
    %% The `real_ip` trust config when the peer is a trusted proxy, decided
    %% once per connection (`roadrunner_real_ip:peer_trust/2`); `undefined`
    %% otherwise, the common case, so the request path resolves nothing.
    real_ip = undefined :: undefined | roadrunner_real_ip:config(),
    %% Encoded buffered responses queued while the keep-alive loop spins
    %% on pipelined requests already sitting in `buffered`, written in
    %% ONE send by `flush_out/1` the moment the loop is about to touch
    %% the socket (next-request recv, an interim 100, a body drain, a
    %% writer-owned response, an error send) or exit. Non-empty only
    %% between a queued response and that next socket boundary.
    out = [] :: iodata()
}).

-type recv_mode() ::
    once | {once, pos_integer()} | 1..32767 | {1..32767, pos_integer()}.

-spec start(roadrunner_transport:socket(), roadrunner_conn:proto_opts()) ->
    {ok, pid()}.
start(
    Socket, #{handler_spawn_opts := SpawnOpts, handler_start_timeout := StartTimeout} = ProtoOpts
) ->
    %% Unlinked from the acceptor — a single-conn crash never propagates
    %% to the acceptor pool. Mirrors `gen_statem:start/3` (NOT start_link)
    %% so existing acceptor handoff (`controlling_process` then `! shoot`)
    %% works without modification.
    Parent = self(),
    proc_lib:start(?MODULE, init_loop, [Parent, Socket, ProtoOpts], StartTimeout, SpawnOpts).

-doc false.
-spec init_loop(pid(), roadrunner_transport:socket(), roadrunner_conn:proto_opts()) ->
    no_return().
init_loop(Parent, Socket, ProtoOpts) ->
    ListenerName = maps:get(listener_name, ProtoOpts, undefined),
    proc_lib:set_label({roadrunner_conn, awaiting_shoot, ListenerName}),
    ok = roadrunner_conn:register_for_drain(ProtoOpts),
    proc_lib:init_ack(Parent, {ok, self()}),
    awaiting_shoot(Socket, ProtoOpts, ListenerName).

-spec awaiting_shoot(roadrunner_transport:socket(), roadrunner_conn:proto_opts(), atom()) ->
    no_return().
awaiting_shoot(Socket0, ProtoOpts, ListenerName) ->
    receive
        shoot ->
            %% Socket ownership has just transferred from the acceptor. Three
            %% things happen before the first request is read, in this order.
            %% If the listener enabled the PROXY protocol, the header an L4
            %% balancer prepended is read off the raw stream first, because it
            %% arrives in plaintext before any TLS bytes. Then, on a TLS
            %% listener, the handshake runs here, in the connection it belongs
            %% to, so a slow or silent peer costs only this process and never
            %% parks an acceptor (see `roadrunner_transport:handshake/2,3`);
            %% plain TCP passes straight through. Then the peer is served.
            OsPeer = roadrunner_conn:peer(Socket0),
            case proxy_protocol_stage(Socket0, ProtoOpts, OsPeer) of
                {ok, Peer, Buffered} ->
                    ok = label_handshake(Socket0, ProtoOpts, ListenerName),
                    case tls_handshake(Socket0, ProtoOpts) of
                        {ok, Socket} ->
                            serve(Socket, ProtoOpts, ListenerName, Peer, Buffered);
                        {error, {handshake, _} = Reason} ->
                            handshake_failed(ProtoOpts, ListenerName, Reason)
                    end;
                {close, Reason} ->
                    %% Malformed/absent PROXY header on a proxy_protocol
                    %% listener, or a peer gone before sending one: a
                    %% misconfigured upstream, or a direct client on a port
                    %% meant for the balancer. Report it the way a failed
                    %% handshake is reported, so it is visible rather than a
                    %% silent close, then release the slot. No accept telemetry
                    %% has fired yet (it pairs with the real peer in serve/5),
                    %% so no conn_close either.
                    ok = roadrunner_event:listener_accept_error(
                        ListenerName, {proxy_protocol, Reason}
                    ),
                    exit_unaccepted(Socket0, ProtoOpts)
            end;
        {roadrunner_drain, _Deadline} ->
            %% Drain before `shoot` — no telemetry was fired yet (accept
            %% pairs with `shoot`), so no listener_conn_close either. Just
            %% release the slot and close the socket.
            exit_unaccepted(Socket0, ProtoOpts);
        _Stray ->
            %% Stray-msg tolerance — gen_statem drops unmatched info events
            %% silently; we do the same so a buggy library can't crash the
            %% conn with a typo'd message.
            awaiting_shoot(Socket0, ProtoOpts, ListenerName)
    end.

%% A TLS listener behind a PROXY-protocol balancer accepts plain TCP and
%% carries the TLS options in `tls_upgrade`; every other TLS listener hands
%% out a pre-handshake `ssl` socket. Plain TCP passes through unchanged.
-spec tls_handshake(roadrunner_transport:socket(), roadrunner_conn:proto_opts()) ->
    {ok, roadrunner_transport:socket()} | {error, {handshake, term()}}.
tls_handshake(Socket, #{tls_upgrade := TlsOpts, tls_handshake_timeout := HsTimeout}) ->
    roadrunner_transport:handshake(Socket, TlsOpts, HsTimeout);
tls_handshake(Socket, #{tls_handshake_timeout := HsTimeout}) ->
    roadrunner_transport:handshake(Socket, HsTimeout).

-spec handshake_failed(roadrunner_conn:proto_opts(), atom(), {handshake, term()}) -> no_return().
handshake_failed(ProtoOpts, ListenerName, Reason) ->
    %% A garbage ClientHello, a TLS alert, a peer gone mid-handshake, or the
    %% `tls_handshake_timeout` bound — routine noise on an internet-facing
    %% TLS port. Surface it as the same accept_error event the acceptor pool
    %% emits for its own failures, then release the slot. No accept
    %% telemetry has fired (it pairs with the peer in serve/5), so no
    %% conn_close either. The socket is not closed here: `handshake/2`
    %% already closed a timed-out one, and on any other failure (every
    %% failure, for the `handshake/3` upgrade) `ssl` tore the connection
    %% down itself.
    ok = roadrunner_event:listener_accept_error(ListenerName, Reason),
    ok = roadrunner_conn:unregister_for_drain(ProtoOpts),
    ok = roadrunner_conn:release_slot(ProtoOpts),
    exit(normal).

%% The handshake is the one pre-serve phase that can block for a while (up
%% to `tls_handshake_timeout` on a silent peer), so a TLS conn is relabelled
%% for its duration; `refine_conn_label/2` takes over once the peer is being
%% served. A TLS conn is either a pre-handshake `ssl` socket or, behind a
%% PROXY-protocol balancer, a plain socket about to be upgraded. Plain TCP
%% has no handshake and keeps the `awaiting_shoot` label until then.
-spec label_handshake(roadrunner_transport:socket(), roadrunner_conn:proto_opts(), atom()) ->
    ok.
label_handshake(Socket, ProtoOpts, ListenerName) ->
    case is_map_key(tls_upgrade, ProtoOpts) orelse roadrunner_conn:scheme(Socket) =:= https of
        true -> proc_lib:set_label({roadrunner_conn, tls_handshake, ListenerName});
        false -> ok
    end.

%% Begin serving a connection once the peer is settled (the real client when
%% the PROXY protocol is on). Fires the accept telemetry, refines the proc_lib
%% label, then forks to HTTP/2 (ALPN `h2` or prior-knowledge h2c) or HTTP/1.
%% `Buffered` seeds the read buffer with any bytes a coalesced segment carried
%% after a stripped PROXY header (empty on the normal path).
-spec serve(
    roadrunner_transport:socket(),
    roadrunner_conn:proto_opts(),
    atom(),
    {inet:ip_address(), inet:port_number()} | undefined,
    binary()
) -> no_return().
serve(Socket, ProtoOpts, ListenerName, Peer, Buffered) ->
    ok = roadrunner_conn:refine_conn_label(ProtoOpts, Peer),
    Scheme = roadrunner_conn:scheme(Socket),
    ConnSpan = roadrunner_event:listener_accept(ListenerName, Peer),
    case http2_negotiated(Socket) orelse h2c_only(ProtoOpts) of
        true ->
            %% Either ALPN landed on `h2` (TLS listener) or the listener is in
            %% prior-knowledge h2c mode (plain TCP with `protocols => [http2]`).
            %% The HTTP/2 path takes over; slot release and `listener_conn_close`
            %% happen inside the h2 module.
            roadrunner_conn_loop_http2:enter(
                Socket, ProtoOpts, ListenerName, Peer, ConnSpan, Buffered
            );
        false ->
            #{
                requests_counter := RequestsCounter,
                dispatch := Dispatch,
                middlewares := Middlewares,
                max_content_length := MaxContentLength,
                max_keep_alive_requests := MaxKeepAliveRequests,
                min_bytes_per_second := MinRate,
                request_timeout := RequestTimeout,
                keep_alive_timeout := KeepAliveTimeout,
                body_buffering := BodyBuffering
            } = ProtoOpts,
            S = #loop_state{
                socket = Socket,
                proto_opts = ProtoOpts,
                listener_name = ListenerName,
                conn_span = ConnSpan,
                peer = Peer,
                conn_info = roadrunner_conn:conn_info(Socket),
                scheme = Scheme,
                buffered = Buffered,
                requests_counter = RequestsCounter,
                dispatch = Dispatch,
                middlewares = Middlewares,
                max_content_length = MaxContentLength,
                max_keep_alive_requests = MaxKeepAliveRequests,
                min_rate = MinRate,
                request_timeout = RequestTimeout,
                keep_alive_timeout = KeepAliveTimeout,
                body_buffering = BodyBuffering,
                recv_mode = recv_mode(
                    read_mode(maps:get(http1_active, ProtoOpts, undefined), Socket),
                    maps:get(hibernate_after, ProtoOpts, 0)
                ),
                alt_svc = maps:get(alt_svc, ProtoOpts, undefined),
                http1_limits = {
                    maps:get(http1_max_request_line, ProtoOpts, 8192),
                    maps:get(http1_max_header_line, ProtoOpts, 8192),
                    maps:get(http1_max_header_block, ProtoOpts, 10240),
                    maps:get(http1_max_header_count, ProtoOpts, 100)
                },
                rate_limit = roadrunner_conn:resolve_rate_limit(ProtoOpts, Peer),
                real_ip = roadrunner_conn:resolve_real_ip(ProtoOpts, Peer),
                request_slot = request_slot(ProtoOpts)
            },
            start_reading(S)
    end.

%% `{http1, #{active => ...}}`, or by transport when unset: `{active, 16}`
%% on TLS, where every arm is a call into the TLS connection process, and
%% `once` on plain TCP, where `{active, N}` measured no faster.
-spec read_mode(once | 1..32767 | undefined, roadrunner_transport:socket()) ->
    once | 1..32767.
read_mode(undefined, {ssl, _}) -> 16;
read_mode(undefined, _Socket) -> once;
read_mode(Mode, _Socket) -> Mode.

-spec recv_mode(once | 1..32767, non_neg_integer()) -> recv_mode().
recv_mode(Mode, 0) -> Mode;
recv_mode(Mode, HibernateAfter) -> {Mode, HibernateAfter}.

%% The socket's read mode, without the hibernation it may be paired with.
-spec active_count(recv_mode()) -> once | 1..32767.
active_count({Mode, _HibernateAfter}) -> Mode;
active_count(Mode) -> Mode.

%% `{active, N}` is armed once, here, and again only on the socket's
%% passive message; `once` arms before each request instead.
-spec start_reading(#loop_state{}) -> no_return().
start_reading(#loop_state{recv_mode = Mode} = S) ->
    case active_count(Mode) of
        once -> ok;
        N -> ok = arm_active_n(S, N)
    end,
    read_request_phase(S).

%% HTTP/1 requests count against `max_concurrent_requests` only when the
%% listener sheds over it: in `refuse` and `queue` modes the ceiling bounds
%% the multiplexed protocols' handler processes, which `max_clients`
%% already does for HTTP/1, while a shed budget that HTTP/1 traffic could
%% run past would shed nothing.
-spec request_slot(roadrunner_conn:proto_opts()) ->
    undefined | {idle, pos_integer(), counters:counters_ref(), roadrunner_conn:overload()}.
request_slot(#{
    overload := {shed, _} = Overload,
    max_concurrent_requests := Max,
    inflight_counter := Counter
}) ->
    {idle, Max, Counter, Overload};
request_slot(_ProtoOpts) ->
    undefined.

%% Read and strip a PROXY-protocol header when the listener enabled it. Returns
%% `{ok, Peer, Leftover}` — the real client peer on a PROXY command, the OS peer
%% on a LOCAL/UNKNOWN one — or `{close, Reason}` on a malformed header or read
%% error, with the parser's or the transport's reason. With the opt off the OS
%% peer passes straight through and no bytes are read.
%%
%% On a TLS listener (`tls_upgrade` set) the header is followed by the
%% ClientHello, and bytes read past the header cannot be handed back to `ssl`,
%% so the header is read exactly and `Leftover` is always empty. On plain TCP
%% whatever arrived with the header is kept as the start of the first request.
-spec proxy_protocol_stage(
    roadrunner_transport:socket(),
    roadrunner_conn:proto_opts(),
    {inet:ip_address(), inet:port_number()} | undefined
) -> {ok, {inet:ip_address(), inet:port_number()} | undefined, binary()} | {close, term()}.
proxy_protocol_stage(_Socket, #{proxy_protocol := false}, OsPeer) ->
    {ok, OsPeer, <<>>};
proxy_protocol_stage(
    Socket, #{proxy_protocol := true, tls_upgrade := _, tls_handshake_timeout := Timeout}, OsPeer
) ->
    %% The header read is connection setup like the handshake that follows
    %% it, so it shares the handshake bound rather than `request_timeout`:
    %% a peer that connects and sends nothing holds its slot no longer here
    %% than on a TLS listener without the PROXY protocol.
    case read_proxy_header_exact(Socket, Timeout) of
        {ok, Peer, <<>>} -> {ok, Peer, <<>>};
        {local, <<>>} -> {ok, OsPeer, <<>>};
        {error, Reason} -> {close, Reason}
    end;
proxy_protocol_stage(Socket, #{proxy_protocol := true} = ProtoOpts, OsPeer) ->
    read_proxy_header(Socket, ProtoOpts, OsPeer, <<>>).

%% A v1 header (CRLF included) never exceeds 107 bytes (HAProxy spec §2.1).
-define(PROXY_V1_MAX, 107).

%% Exact read for the TLS case. Six bytes tell v1 (`PROXY `) from v2 (the
%% first six bytes of its signature); a v2 prefix then declares the length of
%% the rest, while a v1 line is read in one call with the socket in `line`
%% packet mode, bounded at the spec's 107 bytes.
-spec read_proxy_header_exact(roadrunner_transport:socket(), timeout()) ->
    {ok, {inet:ip_address(), inet:port_number()}, binary()}
    | {local, binary()}
    | more
    | {error, term()}.
read_proxy_header_exact(Socket, Timeout) ->
    maybe
        {ok, Head} ?= roadrunner_transport:recv(Socket, 6, Timeout),
        {ok, Header} ?= read_proxy_header_rest(Head, Socket, Timeout),
        roadrunner_proxy_protocol:parse(Header)
    end.

-spec read_proxy_header_rest(binary(), roadrunner_transport:socket(), timeout()) ->
    {ok, binary()} | {error, term()}.
read_proxy_header_rest(~"PROXY ", Socket, Timeout) ->
    read_proxy_v1_line(Socket, Timeout);
read_proxy_header_rest(Head, Socket, Timeout) ->
    maybe
        {ok, Rest} ?= roadrunner_transport:recv(Socket, 10, Timeout),
        Prefix = <<Head/binary, Rest/binary>>,
        {ok, Len} ?= roadrunner_proxy_protocol:v2_body_length(Prefix),
        {ok, Body} ?= recv_exact(Socket, Len, Timeout),
        {ok, <<Prefix/binary, Body/binary>>}
    end.

%% `recv(_, 0, _)` would return whatever is buffered, which here could be the
%% first bytes of the ClientHello; a header with no address block has nothing
%% more to read.
-spec recv_exact(roadrunner_transport:socket(), non_neg_integer(), timeout()) ->
    {ok, binary()} | {error, term()}.
recv_exact(_Socket, 0, _Timeout) ->
    {ok, <<>>};
recv_exact(Socket, Len, Timeout) ->
    roadrunner_transport:recv(Socket, Len, Timeout).

%% The rest of a v1 line after `PROXY `, up to and including its LF, in one
%% read: `{packet, line}` makes the driver stop at the newline, so the
%% ClientHello behind it stays buffered for the upgrade, and `packet_size`
%% caps the line at the spec's bound (a longer one fails with `emsgsize`).
%% Raw mode is restored either way; on a failure the conn closes anyway.
-spec read_proxy_v1_line(roadrunner_transport:socket(), timeout()) ->
    {ok, binary()} | {error, term()}.
read_proxy_v1_line(Socket, Timeout) ->
    ok = roadrunner_transport:setopts(Socket, [{packet, line}, {packet_size, ?PROXY_V1_MAX - 6}]),
    Result = roadrunner_transport:recv(Socket, 0, Timeout),
    ok = roadrunner_transport:setopts(Socket, [{packet, raw}, {packet_size, 0}]),
    case Result of
        {ok, Line} when
            byte_size(Line) >= 2, binary_part(Line, byte_size(Line) - 2, 2) =:= ~"\r\n"
        ->
            {ok, <<"PROXY ", Line/binary>>};
        {ok, _LfOnly} ->
            %% The spec's line ends in CRLF; a bare LF is not a header.
            {error, v1_malformed};
        {error, _} = E ->
            E
    end.

%% Plain TCP: the socket is passive at this phase, so read synchronously,
%% accumulating until `roadrunner_proxy_protocol:parse/1` decides. The parser
%% bounds the header size (v1 107 bytes, v2 by its declared length), so `Acc`
%% cannot grow without bound, and each recv carries the per-request timeout
%% against a dribbling sender. Over-reading is fine here: leftover bytes are
%% the start of the first request and are threaded into its parse.
-spec read_proxy_header(
    roadrunner_transport:socket(),
    roadrunner_conn:proto_opts(),
    {inet:ip_address(), inet:port_number()} | undefined,
    binary()
) -> {ok, {inet:ip_address(), inet:port_number()} | undefined, binary()} | {close, term()}.
read_proxy_header(Socket, #{request_timeout := Timeout} = ProtoOpts, OsPeer, Acc) ->
    case roadrunner_transport:recv(Socket, 0, Timeout) of
        {ok, Bytes} ->
            Buf = <<Acc/binary, Bytes/binary>>,
            case roadrunner_proxy_protocol:parse(Buf) of
                {ok, Peer, Rest} -> {ok, Peer, Rest};
                {local, Rest} -> {ok, OsPeer, Rest};
                more -> read_proxy_header(Socket, ProtoOpts, OsPeer, Buf);
                {error, Reason} -> {close, Reason}
            end;
        {error, Reason} ->
            {close, Reason}
    end.

%% True iff the TLS handshake negotiated `h2`. Plain TCP and TLS
%% sessions where the client picked `http/1.1` (or sent no ALPN)
%% fall through to HTTP/1.1. h2 ALPN is advertised when the listener
%% lists `http2` in its `protocols` opt — that derivation runs in
%% `roadrunner_transport:build_tls_opts/2` (or the user can override
%% `alpn_preferred_protocols` explicitly inside `tls`).
-spec http2_negotiated(roadrunner_transport:socket()) -> boolean().
http2_negotiated(Socket) ->
    case roadrunner_transport:negotiated_alpn(Socket) of
        {ok, ~"h2"} -> true;
        _ -> false
    end.

%% True iff this listener accepts HTTP/2 only (`protocols => [http2]`).
%% On plain TCP this forces h2c prior-knowledge dispatch (RFC 7540
%% §3.4). On TLS the ALPN handshake already drove the dispatch via
%% `http2_negotiated/1`; this short-circuit is a no-op there.
-spec h2c_only(roadrunner_conn:proto_opts()) -> boolean().
h2c_only(#{protocols := [http2]}) -> true;
h2c_only(_) -> false.

%% --- read_request phase ---
%%
%% Active-mode header read. Each iteration:
%%
%%   1. `setopts({active, once})` so the next inbound packet arrives
%%      as a `{TcpTag, Sock, Bytes}` info event.
%%   2. `receive` matches the data tag (accumulate + parse), the
%%      closed/error tags (clean exit), `{roadrunner_drain, _}`
%%      (clean exit), or stray messages (drop and re-loop).
%%   3. The receive's `after RequestTimeout` clause handles
%%      slowloris — no `start_timer` / `cancel_timer` per iteration.
%%
%% Re-entered for every keep-alive iteration; pipelined leftover from
%% the previous request is already in `buffered` and parsed first
%% before any new recv.
-spec read_request_phase(#loop_state{}) -> no_return().
read_request_phase(#loop_state{buffered = Buf} = S) ->
    Timeout = phase_timeout(S),
    %% Compute an *absolute* deadline once. Each iteration's `after`
    %% clause decays it — `recv_request_bytes/2` recomputes
    %% `Deadline - now` so a slow client that drips bytes can NOT keep
    %% extending the receive's timeout. Mirrors gen_statem's one-shot
    %% `state_timeout` semantics in a hand-rolled receive.
    Now = erlang:monotonic_time(millisecond),
    Deadline = Now + Timeout,
    %% Reset the per-request byte counter. The slowloris rate window is
    %% anchored at the first byte actually received (in `recv_passive/2`
    %% and `recv_active/3`), NOT at phase entry — so an idle
    %% keep-alive gap before a reused connection's next request is not
    %% counted as slow transmission. `recv_phase_bytes =:= 0` is the
    %% "no byte yet this request" signal those paths key off to anchor.
    S1 = S#loop_state{recv_phase_bytes = 0},
    case Buf of
        <<>> ->
            recv_request_bytes(S1, Deadline);
        _ ->
            %% Pipelined leftover from a prior keep-alive iteration —
            %% try parsing it before reading more bytes. If the parse
            %% returns `{more, _}` we'll fall back to recv_request_bytes.
            handle_request_bytes(S1, Deadline)
    end.

%% First requests use `request_timeout`; keep-alive loop-backs use
%% `keep_alive_timeout` (typically shorter — connections that have
%% nothing to do drop faster).
-spec phase_timeout(#loop_state{}) -> non_neg_integer().
phase_timeout(#loop_state{phase = first, request_timeout = T}) ->
    T;
phase_timeout(#loop_state{phase = keep_alive, keep_alive_timeout = T}) ->
    T.

-spec recv_request_bytes(#loop_state{}, integer()) -> no_return().
recv_request_bytes(S0, Deadline) ->
    %% About to block on the socket for the next request — everything
    %% queued during the pipelined drain goes out in one write first.
    case flush_out(S0) of
        #loop_state{recv_mode = once, recv_phase_bytes = 0} = S ->
            %% Waiting for the first byte of a request: the conn may sit
            %% here for the whole keep-alive window, so block in `receive`
            %% rather than poll. Passive recv cannot see the mailbox, so
            %% that path has to wake every `?DRAIN_CHECK_INTERVAL_MS` just
            %% to look for a drain — a cost per *connection* rather than
            %% per request, which idle keep-alive connections pay forever.
            recv_idle(S, Deadline);
        #loop_state{recv_mode = once} = S ->
            %% Mid-request: the peer is already sending and the remaining
            %% bytes are in flight, so passive recv blocks briefly. A drain
            %% must not cut an in-flight request short anyway.
            recv_passive(S, Deadline);
        #loop_state{recv_mode = {once, Ms}} = S ->
            arm_active_once(S),
            recv_active(S, Deadline, Ms);
        #loop_state{recv_mode = {_N, Ms}} = S ->
            %% `{active, N}`: the socket is already armed, every read is a
            %% message.
            recv_active(S, Deadline, Ms);
        S ->
            recv_active(S, Deadline, infinity)
    end.

%% Idle wait for the next request on a keep-alive connection. Armed
%% active-once and parked in `receive`, so the process costs nothing until
%% bytes, a close or a drain arrive — and a drain is picked up the instant
%% it is sent instead of on the next poll tick. The deadline rides the
%% receive's own `after` clause: no `send_after` / `cancel_timer` pair per
%% request, which is what kept the passive path cheap.
-spec recv_idle(#loop_state{}, integer()) -> no_return().
recv_idle(#loop_state{socket = Socket, buffered = Buf} = S, Deadline) ->
    arm_active_once(S),
    {DataTag, ClosedTag, ErrorTag} = roadrunner_transport:messages(Socket),
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {DataTag, _Sock, Bytes} ->
            %% Anchor the anti-slowloris window at this first byte rather
            %% than at phase entry, so the idle keep-alive gap that just
            %% ended is not counted as slow transmission. No rate check
            %% here: the window is zero-length at its own anchor, so the
            %% first chunk always passes. `recv_passive/2` measures every
            %% chunk after it.
            handle_request_bytes(
                S#loop_state{
                    buffered = roadrunner_bin:append(Buf, Bytes),
                    recv_phase_bytes = byte_size(Bytes),
                    recv_phase_start = erlang:monotonic_time(millisecond)
                },
                Deadline
            );
        {ClosedTag, _Sock} ->
            exit_normal(S, peer_closed);
        {ErrorTag, _Sock, Reason} ->
            exit_normal(S, {transport, Reason});
        {roadrunner_drain, _DrainDeadline} ->
            exit_normal(S, drained);
        _Stray ->
            recv_idle(S, Deadline)
    after Remaining ->
        timeout_response(S),
        exit_normal(S, timeout_reason(S))
    end.

%% Passive-mode recv path — reads the remainder of a request whose first
%% byte `recv_idle/2` already took. Bypasses `gen_tcp_socket`'s gen_statem
%% dispatch entirely — direct `gen_tcp:recv` call into the kernel via the
%% prim_socket NIF.
%%
%% Drain detection: zero-timeout receive before each blocking recv
%% drains pending `{roadrunner_drain, _}` and stray messages from the
%% mailbox. Each recv is capped at
%% `roadrunner_conn:drain_check_interval_ms/0` so a drain delivered
%% while we're blocked surfaces within ~100 ms.
%%
%% That cap looks removable now that the idle wait parks in `receive`
%% and sees a drain immediately, since a drain should not cut an
%% in-flight request short anyway. It is not. It bounds how long a conn
%% stalled MID-request takes to notice: a peer that sent half its
%% headers and went away would otherwise sit here for the whole
%% `request_timeout`, outlive the drain deadline, and be hard-killed by
%% `roadrunner_listener:drain/2` instead of exiting cleanly — turning a
%% graceful drain into a forced one and reporting `{timeout, N}` rather
%% than `{ok, drained}`. The body read takes the same cap, for the same
%% reason, in `roadrunner_conn:recv_body_chunk/4`. Normal traffic never
%% pays for it: the next chunk of a request already in flight arrives in
%% microseconds, so the cap only fires for a client that stopped
%% sending.
%%
%% Request-timeout: tracked via the absolute `Deadline`. `{error,
%% timeout}` from recv with `Remaining =< ChunkTimeout` means the
%% request_timeout actually fired; otherwise it's a drain-check tick
%% and we loop.
-spec recv_passive(#loop_state{}, integer()) -> no_return().
recv_passive(
    #loop_state{
        socket = Socket,
        buffered = Buf,
        min_rate = MinRate,
        recv_phase_start = PhaseStart,
        recv_phase_bytes = PhaseBytes
    } = S,
    Deadline
) ->
    case drain_mailbox_check() of
        drain ->
            exit_normal(S, drained);
        ok ->
            Now = erlang:monotonic_time(millisecond),
            Remaining = max(0, Deadline - Now),
            ChunkTimeout = min(Remaining, roadrunner_conn:drain_check_interval_ms()),
            case roadrunner_transport:recv(Socket, 0, ChunkTimeout) of
                {ok, Bytes} ->
                    %% Anti-slowloris: track running bytes/sec and drop
                    %% the conn if `min_rate` isn't met after the 1 s
                    %% grace. Cheap when `min_rate = 0` because
                    %% `roadrunner_conn:rate_ok/3` short-circuits at
                    %% `MinRate * Elapsed = 0`. The window is already
                    %% anchored at the request's first byte by
                    %% `recv_idle/2`, which is the only way into this
                    %% path, so every chunk measured here is a genuine
                    %% continuation of a request already in flight.
                    NewBytes = PhaseBytes + byte_size(Bytes),
                    case roadrunner_conn:rate_ok(Now - PhaseStart, NewBytes, MinRate) of
                        true ->
                            handle_request_bytes(
                                S#loop_state{
                                    buffered = roadrunner_bin:append(Buf, Bytes),
                                    recv_phase_bytes = NewBytes,
                                    recv_phase_start = PhaseStart
                                },
                                Deadline
                            );
                        false ->
                            %% Slowloris — silent close. No 408; the peer
                            %% wasn't going to read it anyway.
                            exit_normal(S, slow_client)
                    end;
                {error, timeout} when Remaining =< ChunkTimeout ->
                    %% True request/keep-alive timeout — the deadline
                    %% has elapsed.
                    timeout_response(S),
                    exit_normal(S, timeout_reason(S));
                {error, timeout} ->
                    %% Drain-check tick. Loop back to the mailbox
                    %% drain + recv.
                    recv_passive(S, Deadline);
                {error, Reason} ->
                    %% Peer close, kernel error, etc. Silent exit.
                    exit_normal(S, transport_reason(Reason))
            end
    end.

%% Zero-timeout drain of the mailbox. Returns `drain` if a drain
%% message was queued, otherwise drops every other message and
%% returns `ok`. Stray messages don't queue forever — drained on
%% every recv iteration. Safe to discard them here because this runs
%% before any handler code; the body read's check
%% (`roadrunner_conn:recv_body_chunk/4`) matches selectively instead,
%% since by then the mailbox can hold messages meant for the handler.
-spec drain_mailbox_check() -> drain | ok.
drain_mailbox_check() ->
    receive
        {roadrunner_drain, _Deadline} -> drain;
        _Stray -> drain_mailbox_check()
    after 0 ->
        ok
    end.

%% Recv path in `receive`: every read of an `{active, N}` socket, and
%% every read of an `{active, once}` one when the conn hibernates. The
%% receive's `after` covers both the hibernate trigger and the
%% request/keep-alive deadline: it waits `min(HibernateAfter, Remaining)`,
%% and on firing either times the conn out (the deadline came first) or
%% hibernates (`infinity` never does). A busy conn therefore
%% arms no timer per recv. Only a conn about to hibernate arms one, an
%% absolute `start_timer` at the deadline, because a hibernated process
%% only wakes on a message: without it an idle conn would outlive its
%% `keep_alive_timeout` / `request_timeout` for as long as the peer
%% stays silent. On wake the function re-enters via
%% `recv_request_bytes_hib/3`, which drops that timer first.
-spec recv_active(#loop_state{}, integer(), pos_integer() | infinity) -> no_return().
recv_active(
    #loop_state{
        socket = Socket,
        buffered = Buf,
        min_rate = MinRate,
        recv_phase_start = PhaseStart,
        recv_phase_bytes = PhaseBytes
    } = S,
    Deadline,
    HibernateAfter
) ->
    {DataTag, ClosedTag, ErrorTag} = roadrunner_transport:messages(Socket),
    PassiveTag = roadrunner_transport:passive_message(Socket),
    Active = active_count(S#loop_state.recv_mode),
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {DataTag, _Sock, Bytes} ->
            Now = erlang:monotonic_time(millisecond),
            %% Anchor the slowloris window at the first byte of the
            %% request (`PhaseBytes =:= 0`), not at phase entry, so an
            %% idle keep-alive gap before a reused connection's next
            %% request is not counted as slow transmission.
            PhaseStart1 =
                case PhaseBytes of
                    0 -> Now;
                    _ -> PhaseStart
                end,
            NewBytes = PhaseBytes + byte_size(Bytes),
            case roadrunner_conn:rate_ok(Now - PhaseStart1, NewBytes, MinRate) of
                true ->
                    handle_request_bytes(
                        S#loop_state{
                            buffered = roadrunner_bin:append(Buf, Bytes),
                            recv_phase_bytes = NewBytes,
                            recv_phase_start = PhaseStart1
                        },
                        Deadline
                    );
                false ->
                    exit_normal(S, slow_client)
            end;
        {ClosedTag, _Sock} ->
            exit_normal(S, peer_closed);
        {ErrorTag, _Sock, Reason} ->
            exit_normal(S, {transport, Reason});
        {PassiveTag, _Sock} when Active =/= once ->
            %% Only an `{active, N}` socket goes passive.
            ok = arm_active_n(S, Active),
            recv_active(S, Deadline, HibernateAfter);
        {roadrunner_drain, _Deadline} ->
            exit_normal(S, drained);
        _Stray ->
            ok = rearm_after_stray(S, Active),
            recv_active(S, Deadline, HibernateAfter)
    after min(HibernateAfter, Remaining) ->
        case Remaining =< HibernateAfter of
            true ->
                timeout_response(S),
                exit_normal(S, timeout_reason(S));
            false ->
                %% Idle window elapsed with the deadline still ahead.
                %% The heap GCs and shrinks; the next inbound packet,
                %% or the deadline timer, wakes the conn.
                TRef = erlang:start_timer(Deadline, self(), ?MODULE, [{abs, true}]),
                erlang:hibernate(?MODULE, recv_request_bytes_hib, [S, Deadline, TRef])
        end
    end.

%% Hibernate continuation. Drops the deadline timer armed before
%% hibernating, then re-enters `recv_request_bytes/2` so the next
%% iteration picks up wherever the recv shape demands. If the timer is
%% what woke the conn, its message is consumed here and the deadline,
%% now in the past, times the conn out on the next receive.
-doc false.
-spec recv_request_bytes_hib(#loop_state{}, integer(), reference()) -> no_return().
recv_request_bytes_hib(S, Deadline, TRef) ->
    case erlang:cancel_timer(TRef) of
        false ->
            %% Already fired: its message is queued or on its way, and
            %% nothing else consumes it, so wait for it here.
            receive
                {timeout, TRef, ?MODULE} -> ok
            end;
        _Left ->
            ok
    end,
    recv_request_bytes(S, Deadline).

%% Slowloris on first request → 408. Idle keep-alive timeout →
%% silent close (peer wasn't waiting on bytes).
-spec timeout_response(#loop_state{}) -> ok.
timeout_response(#loop_state{phase = first, socket = Socket}) ->
    _ = roadrunner_conn:send_request_timeout(Socket),
    ok;
timeout_response(#loop_state{phase = keep_alive}) ->
    ok.

%% Try parsing the accumulated buffer. On `{more, _}` we re-arm and
%% wait for more bytes; on `{ok, Req, Rest}` we've parsed a full
%% request and dispatch into the body/handler phase; on `{error, _}`
%% we send 400 and exit.
-spec handle_request_bytes(#loop_state{}, integer()) -> no_return().
handle_request_bytes(
    #loop_state{
        socket = Socket,
        listener_name = ListenerName,
        peer = Peer,
        conn_info = ConnInfo,
        scheme = Scheme,
        requests_counter = ReqCounter,
        http1_limits = Http1Limits
    } = S,
    Deadline
) ->
    Buf = S#loop_state.buffered,
    case roadrunner_http1:parse_request(Buf, Http1Limits) of
        {ok, Req0, Rest} ->
            _ = atomics:add(ReqCounter, 1, 1),
            {RequestId, NewBuffer} = roadrunner_conn:generate_request_id(
                S#loop_state.req_id_buffer
            ),
            Req1 = Req0#{
                peer => Peer,
                conn_info => ConnInfo,
                scheme => Scheme,
                request_id => RequestId,
                listener_name => ListenerName
            },
            Req = roadrunner_conn:with_client_ip(Req1, S#loop_state.real_ip, Peer),
            ok = roadrunner_conn:set_request_logger_metadata(Req),
            read_body_phase(
                S#loop_state{buffered = Rest, req_id_buffer = NewBuffer}, Req, Deadline
            );
        {more, _} ->
            %% Need more bytes to complete the request line/headers.
            %% `recv_request_bytes/2` dispatches to passive (default)
            %% or active+hibernate; either path arms whatever it
            %% needs. Don't call `arm_active_once` here — passive
            %% mode would silently leak the resulting `{tcp, _, _}`
            %% delivery into the mailbox.
            recv_request_bytes(S, Deadline);
        {error, Reason} ->
            logger:debug(#{
                msg => "roadrunner rejecting malformed request",
                peer => Peer,
                listener_name => ListenerName,
                reason => Reason
            }),
            ok = roadrunner_event:request_rejected(ListenerName, Peer, Reason),
            %% Size-limit overruns get the RFC-specific status (414 for an
            %% over-long request line, 431 for oversized/too-many headers);
            %% other malformed input is a generic 400. Queued pipelined
            %% responses go out first so the client attributes the error
            %% to the right request.
            S2 = flush_out(S),
            _ = roadrunner_conn:send_status(Socket, roadrunner_conn:parse_error_status(Reason)),
            exit_lingering(S2, rejected)
    end.

%% --- read_body phase ---
%%
%% Auto-buffering reads the full body synchronously via the recv
%% closure (passive `gen_tcp:recv` with the request_timeout deadline).
%% Manual buffering builds a body_reader the handler will pull from
%% via `roadrunner_req:read_body/1,2`.
%%
%% The framing is decided once, up front. An auto-mode request without
%% `Content-Length` or `Transfer-Encoding` has no body (RFC 9112 §6.3),
%% so it skips the recv closure entirely: the bodyless GET is the
%% common request, and nothing about it reads the socket. Any bytes
%% already buffered are the next pipelined request and stay in
%% `buffered`.
%%
%% The per-peer rate limit is checked first, from the headers alone, so a
%% request over its rate is answered 429 before any of its body is read.
%% A shed listener's in-flight ceiling comes next, the same way: a request
%% over it is answered 503 before its body is read or a handler runs.
%% The request is then routed, once, before its body is read: the match is
%% the one dispatch uses, and a matched route's own `max_content_length`
%% caps the body in place of the listener's, for the read itself, the
%% `100 Continue` decision and the early 413 alike.
-spec read_body_phase(#loop_state{}, roadrunner_req:request(), integer()) -> no_return().
read_body_phase(
    #loop_state{rate_limit = RateLimit, listener_name = ListenerName} = S, Req, Deadline
) ->
    case roadrunner_conn:rate_limit(RateLimit, Req, ListenerName) of
        allow ->
            admit(S, Req, Deadline);
        {deny, RetryAfter} ->
            refuse_retry_later(S, 429, RetryAfter, roadrunner_conn:body_framing(Req))
    end.

%% Take the request's in-flight slot when HTTP/1 is under the ceiling
%% (shed mode), or shed it: 503 + `Retry-After`, counted and reported as a
%% throttled request, as the multiplexed protocols do.
-spec admit(#loop_state{}, roadrunner_req:request(), integer()) -> no_return().
admit(#loop_state{request_slot = undefined} = S, Req, Deadline) ->
    route_and_read(S, Req, Deadline);
admit(#loop_state{request_slot = {idle, Max, Counter, Overload}} = S, Req, Deadline) ->
    case roadrunner_conn:acquire_request_slot(Max, Counter, Overload, h1) of
        true ->
            route_and_read(
                S#loop_state{request_slot = {held, Max, Counter, Overload}}, Req, Deadline
            );
        {shed, RetryAfter} ->
            #loop_state{proto_opts = #{throttled_counter := Throttled}, listener_name = Name} = S,
            ok = roadrunner_conn:throttled_telemetry(Name, Throttled, max_concurrent_requests),
            refuse_retry_later(S, 503, RetryAfter, roadrunner_conn:body_framing(Req))
    end.

%% Hand the request's in-flight slot back once it has ended: before the
%% next request on a kept-alive connection, on the way out, or as a
%% WebSocket session starts.
-spec release_request_slot(#loop_state{}) -> #loop_state{}.
release_request_slot(#loop_state{request_slot = {held, Max, Counter, Overload}} = S) ->
    ok = roadrunner_conn:release_request_slot(Max, Counter, Overload),
    S#loop_state{request_slot = {idle, Max, Counter, Overload}};
release_request_slot(S) ->
    S.

%% Over its rate (429) or shed (503): queued pipelined responses go out
%% first so the response + close cannot overtake them, and the close
%% lingers over a body the client may be sending.
-spec refuse_retry_later(
    #loop_state{},
    429 | 503,
    pos_integer(),
    none
    | chunked
    | {content_length, non_neg_integer()}
    | {error, bad_content_length | bad_transfer_encoding}
) -> no_return().
refuse_retry_later(#loop_state{socket = Socket} = S, Status, RetryAfter, Framing) ->
    S1 = flush_out(S),
    _ = roadrunner_conn:send_retry_later(Socket, Status, RetryAfter),
    case Framing of
        none -> exit_normal(S1, rejected);
        _ -> exit_lingering(S1, rejected)
    end.

-spec route_and_read(#loop_state{}, roadrunner_req:request(), integer()) -> no_return().
route_and_read(#loop_state{body_buffering = BodyMode, dispatch = Dispatch} = S, Req, Deadline) ->
    Resolved = roadrunner_conn:resolve_handler(Dispatch, Req),
    case {BodyMode, roadrunner_conn:body_framing(Req)} of
        {auto, none} ->
            dispatch_phase(S, Req#{body => <<>>}, Resolved);
        {manual, {error, FramingReason}} ->
            S2 = flush_out(S),
            ok = rejection(S2, FramingReason),
            _ = roadrunner_conn:send_bad_request(S2#loop_state.socket),
            exit_lingering(S2, rejected);
        {_, Framing} ->
            MaxCL = roadrunner_conn:body_cap(Resolved, S#loop_state.max_content_length),
            case expect_answer(S, Req, Framing, MaxCL) of
                too_large ->
                    %% The client holds back a body over its cap for a 100:
                    %% the 413 goes out before it sends a byte of it, so
                    %% there is nothing to drain.
                    refuse_too_large(S);
                Answer ->
                    read_body(BodyMode, Answer, S, Req, Framing, MaxCL, Resolved, Deadline)
            end
    end.

%% RFC 9110 §10.1.1: how a request is answered for its `Expect` field before
%% its body is read. A client holding its body back for `Expect:
%% 100-continue` (no body bytes came with the headers, so it did wait) is
%% sent `too_large`, the 413 its body would earn, when its declared length is
%% over the body cap `MaxCL`, or else `continue`, the 100 that asks for it,
%% when the framing promises a body. `none` for everything else.
-spec expect_answer(
    #loop_state{},
    roadrunner_req:request(),
    none
    | chunked
    | {content_length, non_neg_integer()}
    | {error, bad_content_length | bad_transfer_encoding},
    non_neg_integer()
) -> continue | too_large | none.
expect_answer(#loop_state{buffered = ~""}, Req, Framing, MaxCL) ->
    case roadrunner_conn:expects_continue(Req) of
        true ->
            case Framing of
                chunked -> continue;
                {content_length, N} when N > MaxCL -> too_large;
                {content_length, N} when N > 0 -> continue;
                _ -> none
            end;
        false ->
            none
    end;
expect_answer(_S, _Req, _Framing, _MaxCL) ->
    none.

%% Read the body (auto mode) or hand the handler its reader (manual mode),
%% with the request's `Expect` answered. Auto mode asks for the body now.
%% Manual mode lets the middlewares and the handler decide from the
%% request's headers whether its body is wanted: the 100 goes out when the
%% handler first reads it (`roadrunner_conn:consume_body_reader/2` sends it,
%% from the body reader's `continue`). A handler that answers without
%% reading never asks: the client sends nothing, and the connection closes
%% after the response, as the client may still send the body once it stops
%% waiting. Queued pipelined responses go out ahead of the 100 either way.
%% The manual read's slow-client rate window starts with the 100, when the
%% client can start sending, so `continue` carries what its recv is made of.
-spec read_body(
    auto | manual,
    continue | none,
    #loop_state{},
    roadrunner_req:request(),
    none
    | chunked
    | {content_length, non_neg_integer()}
    | {error, bad_content_length | bad_transfer_encoding},
    non_neg_integer(),
    roadrunner_conn:resolved(),
    integer()
) -> no_return().
read_body(
    auto, continue, #loop_state{socket = Socket} = S, Req, Framing, MaxCL, Resolved, Deadline
) ->
    S1 = flush_out(S),
    ok = roadrunner_conn:send_continue(Socket),
    read_auto_body(S1, Req, Framing, MaxCL, Resolved, Deadline);
read_body(auto, none, S, Req, Framing, MaxCL, Resolved, Deadline) ->
    read_auto_body(S, Req, Framing, MaxCL, Resolved, Deadline);
read_body(manual, Answer, S, Req, Framing, MaxCL, Resolved, Deadline) ->
    BodyState = roadrunner_conn:make_body_reader(
        Framing, S#loop_state.buffered, body_recv(S, Deadline), MaxCL, trailer_limits(S)
    ),
    case Answer of
        continue ->
            #loop_state{socket = Socket, min_rate = MinRate} = S,
            Owed = atomics:new(1, []),
            Reader = BodyState#{continue => {Socket, Deadline, MinRate, Owed}},
            dispatch_phase(flush_out(S), Req#{body_reader => Reader}, Resolved);
        none ->
            dispatch_phase(S, Req#{body_reader => BodyState}, Resolved)
    end.

%% Auto mode with a body (or a framing error the read reports): read it
%% all before dispatch, under the request's body cap `MaxCL`; `Resolved` is
%% the request's routing, for dispatch.
-spec read_auto_body(
    #loop_state{},
    roadrunner_req:request(),
    chunked
    | {content_length, non_neg_integer()}
    | {error, bad_content_length | bad_transfer_encoding},
    non_neg_integer(),
    roadrunner_conn:resolved(),
    integer()
) -> no_return().
read_auto_body(
    #loop_state{socket = Socket, buffered = Buffered} = S, Req, Framing, MaxCL, Resolved, Deadline
) ->
    Recv = body_recv(S, Deadline),
    case roadrunner_conn:read_body(Framing, Buffered, Recv, MaxCL, trailer_limits(S)) of
        {ok, Body, Leftover} ->
            %% Leftover is bytes past the body — feed it
            %% back to the next read_request_phase iteration
            %% as pipelined leftover.
            dispatch_phase(S#loop_state{buffered = Leftover}, Req#{body => Body}, Resolved);
        {error, content_length_too_large} ->
            refuse_too_large(S);
        {error, request_timeout} ->
            S2 = flush_out(S),
            _ = roadrunner_conn:send_request_timeout(Socket),
            exit_normal(S2, request_timeout);
        {error, slow_client} ->
            exit_normal(S, slow_client);
        {error, drained} ->
            %% Listener draining while the peer was still
            %% uploading. No response: the request never
            %% completed, and the conn is going away anyway.
            exit_normal(S, drained);
        {error, BodyReason} ->
            S2 = flush_out(S),
            ok = rejection(S2, BodyReason),
            %% A chunked body's trailer block obeys the same header
            %% limits as request headers, so an oversized/too-many
            %% trailer reason maps to 431 the same way.
            _ = roadrunner_conn:send_status(
                Socket, roadrunner_conn:parse_error_status(BodyReason)
            ),
            exit_lingering(S2, rejected)
    end.

%% The body's recv closure: passive reads bounded by the request
%% deadline, with the anti-slowloris rate anchored at this call.
-spec body_recv(#loop_state{}, integer()) ->
    fun(() -> {ok, binary()} | {error, term()}).
body_recv(#loop_state{socket = Socket, min_rate = MinRate}, Deadline) ->
    roadrunner_conn:make_recv(Socket, Deadline, MinRate).

%% Trailer headers (chunked bodies) obey the same caps as request
%% headers; the request-line cap doesn't apply to a trailer block.
-spec trailer_limits(#loop_state{}) -> {pos_integer(), pos_integer(), pos_integer()}.
trailer_limits(#loop_state{http1_limits = {_ReqLine, MaxHdrLine, MaxHdrBlock, MaxHdrCount}}) ->
    {MaxHdrLine, MaxHdrBlock, MaxHdrCount}.

%% --- dispatch phase ---
%%
%% Take the request's resolved handler (routed in `read_body_phase/3`),
%% run its middleware pipeline bracketed by request_start / request_stop |
%% request_exception telemetry. The 5 returned response shapes (buffered,
%% stream, loop, sendfile, websocket) dispatch to their respective
%% writers via `dispatch_response/4`; a `{send, ...}` fun writes its
%% own response (`send_phase/6`).
-spec dispatch_phase(#loop_state{}, roadrunner_req:request(), roadrunner_conn:resolved()) ->
    no_return().
dispatch_phase(#loop_state{socket = Socket} = S, Req, Resolved) ->
    case Resolved of
        {ok, Handler, Bindings, Pipeline, _State, _Limits} ->
            run_pipeline(S, Handler, Req#{bindings => Bindings}, Pipeline);
        {method_not_allowed, Allowed} ->
            %% Path matched but no route answers this method: 405 + Allow
            %% before any pipeline runs (the method gate is a routing
            %% decision, ahead of per-route middleware).
            S1 = flush_out(S),
            _ = roadrunner_conn:send_method_not_allowed(Socket, Allowed),
            exit_unread(S1, Req);
        not_found ->
            S1 = flush_out(S),
            _ = roadrunner_conn:send_not_found(Socket),
            exit_unread(S1, Req)
    end.

-spec run_pipeline(
    #loop_state{},
    module(),
    roadrunner_req:request(),
    roadrunner_middleware:next()
) -> no_return().
run_pipeline(#loop_state{socket = Socket} = S, Handler, Req, Pipeline) ->
    Span = roadrunner_event:request_start(Req),
    try Pipeline(Req) of
        {{send, Headers, Fun}, Req2} when is_list(Headers), is_function(Fun, 1), is_map(Req2) ->
            S2 = S#loop_state{requests_served = S#loop_state.requests_served + 1},
            send_phase(S2, Handler, Req2, Headers, Fun, Span);
        {Response0, Req2} when is_map(Req2) ->
            S2 = S#loop_state{requests_served = S#loop_state.requests_served + 1},
            %% Decide keep-alive-vs-close BEFORE the response is sent so a
            %% server-initiated close (count ceiling) lands on the wire as
            %% `Connection: close` — see `ensure_close_signaled/3`.
            %% A handler-returned 1xx becomes a 500 first, so the close
            %% signal, the response sent and telemetry all see the 500.
            Response = ensure_close_signaled(
                S2, Req2, roadrunner_conn:final_response(h1, Handler, Response0)
            ),
            case dispatch_response(S2, Handler, Req2, Response) of
                {ws_upgrade, Run, S3} ->
                    %% The 101 is out: the WebSocket session now runs in
                    %% this process until it ends and calls the close path
                    %% `ws_finish/4` builds. `request_stop` fires there, so
                    %% its timing (response writer finished) matches the
                    %% other writer-owned shapes.
                    Run(ws_finish(release_request_slot(S3), Req2, Span, Response));
                #loop_state{} = S3 ->
                    ok = roadrunner_event:request_stop(
                        Span,
                        roadrunner_conn:response_status(Response),
                        roadrunner_conn:response_kind(Response)
                    ),
                    finishing_phase(S3, Req2, Response)
            end
    catch
        Class:Reason:Stack ->
            ok = roadrunner_event:request_exception(Span, Class, Reason, Stack),
            logger:error(#{
                msg => "roadrunner handler crashed",
                handler => Handler,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            S9 = flush_out(S),
            _ = roadrunner_conn:send_internal_error(Socket),
            exit_unread(S9, Req)
    end.

%% A `{send, Headers, Fun}` response: the fun writes the wire itself, as
%% it runs, through `send_emit/2`; this process then finishes the
%% request on what it sent, as it does for the shape that was sent. The fun
%% runs under its own `try` (`roadrunner_send_writer:run/5`): a crash before a
%% final response is answered 500, as a handler crash is, and one after it
%% closes the connection.
-spec send_phase(
    #loop_state{},
    module(),
    roadrunner_req:request(),
    roadrunner_http:headers(),
    roadrunner_send:sender(),
    roadrunner_event_handler:span()
) -> no_return().
send_phase(S0, Handler, Req, Headers, Fun, Span) ->
    %% Queued pipelined responses go out ahead of anything the fun sends.
    #loop_state{socket = Socket} = S = flush_out(S0),
    case roadrunner_send_writer:run(Handler, Fun, Headers, Req, send_emit(S, Handler)) of
        {done, {websocket, _Status, {session, Upgrade, Run}}, Req2} ->
            %% The fun answered with an upgrade: run the session here, as
            %% for a returned one; `request_stop` fires when it ends.
            Run(ws_finish(release_request_slot(S), Req2, Span, Upgrade));
        {done, {Kind, Status, SentHeaders}, Req2} ->
            ok = roadrunner_event:request_stop(Span, Status, Kind),
            send_finish(S, Req2, Kind, SentHeaders);
        {closed, {Kind, Status, _SentHeaders}} ->
            %% The fun stopped on purpose (`{shutdown, _}`): what it read of
            %% the body is unknown, so the connection closes.
            ok = roadrunner_event:request_stop(Span, Status, Kind),
            exit_unread(S, Req);
        {crashed, Class, Reason, Stack, Sent} ->
            ok = roadrunner_event:request_exception(Span, Class, Reason, Stack),
            logger:error(#{
                msg => "roadrunner handler crashed",
                handler => Handler,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            _ = crash_answer(Sent, Socket),
            exit_unread(S, Req)
    end.

%% A 500 for a fun that crashed before its final response; after it, the
%% connection only closes.
-spec crash_answer(none | complete | open, roadrunner_transport:socket()) ->
    ok | {error, term()}.
crash_answer(none, Socket) -> roadrunner_conn:send_internal_error(Socket);
crash_answer(_Sent, _Socket) -> ok.

%% A complete or file response is keep-alive eligible on the headers it went
%% out with, a streamed one closes, as for the shapes themselves.
-spec send_finish(
    #loop_state{},
    roadrunner_req:request(),
    buffered | stream | sendfile | websocket,
    roadrunner_http:headers() | rejected
) -> no_return().
send_finish(S, Req, Kind, _Headers) when Kind =:= stream; Kind =:= websocket ->
    %% A refused upgrade already answered and closes, as for a returned one.
    writer_finish(S, Req);
send_finish(S, Req, _Kind, Headers) ->
    buffered_finish(S, Req, Headers).

%% `roadrunner_send`'s writer for this connection. Each final response
%% goes out at once, `Connection: close` added when the server closes after
%% it (`with_close_if_closing/3`, on the request the fun holds then), and
%% reports the headers it went out with for the keep-alive decision. A
%% complete one answers the client, so a 100 Continue still owed is not
%% sent after it (`roadrunner_conn:skip_continue/1`); a stream sends it
%% first.
-spec send_emit(#loop_state{}, module()) -> roadrunner_send_writer:emit().
send_emit(#loop_state{socket = Socket, alt_svc = AltSvc} = S, Handler) ->
    fun
        ({inform, Status, Headers}, Req) ->
            send_interim(Socket, Status, Headers, AltSvc, Req);
        ({reply, Status, Headers0, Body}, #{method := Method} = Req) ->
            ok = roadrunner_conn:skip_continue(Req),
            Headers = with_close_if_closing(S, Req, Headers0),
            Resp = roadrunner_http1:response(
                Status, framed(Status, Headers, Body), reply_body(Method, Body), AltSvc
            ),
            Result = roadrunner_event:response_send(
                roadrunner_transport:send(Socket, Resp), buffered_response
            ),
            {Result, Status, Headers};
        ({stream, Status, Headers}, Req) ->
            #loop_state{} = disarm(S),
            ok = roadrunner_conn:continue_before_stream(Req),
            {Result, Send} = roadrunner_stream_response:start(
                Socket, Status, roadrunner_http:auto_headers(Headers, AltSvc)
            ),
            {roadrunner_send_writer:started(Result, Send), Status, Headers};
        ({sendfile, Status, Headers0, Spec}, Req) ->
            ok = roadrunner_conn:skip_continue(Req),
            Headers = with_close_if_closing(S, Req, Headers0),
            #loop_state{} = dispatch_response(S, Handler, Req, {sendfile, Status, Headers, Spec}),
            {ok, Status, Headers};
        ({websocket, Mod, State, Opts} = Upgrade, Req) ->
            case dispatch_websocket(S, Req, Mod, State, Opts) of
                {ws_upgrade, Run, _S} -> {ok, 101, {session, Upgrade, Run}};
                #loop_state{} -> {{error, rejected}, 101, rejected}
            end
    end.

%% RFC 9110 §15.2: a server MUST NOT send a 1xx response to an HTTP/1.0
%% client, so an interim response to one is skipped.
-spec send_interim(
    roadrunner_transport:socket(),
    roadrunner_http:status(),
    roadrunner_http:headers(),
    binary() | undefined,
    roadrunner_req:request()
) -> ok | {error, term()}.
send_interim(_Socket, _Status, _Headers, _AltSvc, #{version := {1, 0}}) ->
    ok;
send_interim(Socket, Status, Headers, AltSvc, _Req) ->
    roadrunner_event:response_send(
        roadrunner_transport:send(Socket, roadrunner_http1:response(Status, Headers, ~"", AltSvc)),
        interim_response
    ).

%% RFC 9110 §9.3.2: a HEAD response carries no content.
-spec reply_body(binary(), iodata()) -> iodata().
reply_body(~"HEAD", _Body) -> ~"";
reply_body(_Method, Body) -> Body.

%% RFC 9112 §9.6: a server that will not reuse the connection MUST signal it on
%% the final response. The per-request keep-alive decision already reaches the
%% wire whenever the client or handler set `Connection: close`; the gap is a
%% *server-initiated* close the client cannot infer — reaching
%% `max_keep_alive_requests` on a connection that was otherwise keep-alive. Add
%% the header there (and only there) so a fronting proxy (nginx, ngrok) stops
%% reusing a connection we are about to close, instead of racing a request onto
%% it. Buffered + sendfile share Content-Length framing and are keep-alive
%% eligible, so they get the header here. Websocket has already switched
%% protocols (its 101 carried `Connection: Upgrade`), and stream / loop always
%% force close in `finishing_phase` — none of the three runs through the
%% request-count ceiling, so they pass through this helper untouched.
-spec ensure_close_signaled(
    #loop_state{}, roadrunner_req:request(), roadrunner_handler:response()
) -> roadrunner_handler:response().
ensure_close_signaled(S, Req, {Status, Headers, Body}) when is_integer(Status) ->
    {Status, with_close_if_closing(S, Req, Headers), Body};
ensure_close_signaled(S, Req, {sendfile, Status, Headers, Spec}) when is_integer(Status) ->
    {sendfile, Status, with_close_if_closing(S, Req, Headers), Spec};
ensure_close_signaled(_S, _Req, Response) ->
    Response.

%% Prepend `Connection: close` exactly when the server closes a connection
%% that would otherwise be reused: this request trips the keep-alive ceiling,
%% the handler answered without asking for a body the client holds back
%% for a 100 Continue (`read_body/8`; RFC 9110 §10.1.1 asks a server
%% answering before the body to say whether it closes), or the request
%% declared a manual-mode body over its cap, which is never read, so the
%% connection cannot go on past it. In the common case the
%% response has no `connection` header, so the prepend is the only token; if a
%% handler set one explicitly, `close` is the first token on the wire and takes
%% precedence (RFC 9112 §9.6). Every other case is left byte-for-byte unchanged.
-spec with_close_if_closing(#loop_state{}, roadrunner_req:request(), roadrunner_http:headers()) ->
    roadrunner_http:headers().
with_close_if_closing(
    #loop_state{body_buffering = manual}, #{body_reader := #{continue := _}} = Req, Headers
) ->
    with_close(Req, Headers);
with_close_if_closing(
    #loop_state{body_buffering = manual},
    #{body_reader := #{framing := {content_length, N}, max := Max}} = Req,
    Headers
) when N > Max ->
    with_close(Req, Headers);
with_close_if_closing(
    #loop_state{requests_served = Served, max_keep_alive_requests = Max}, Req, Headers
) when Served >= Max ->
    with_close(Req, Headers);
with_close_if_closing(_S, _Req, Headers) ->
    Headers.

-spec with_close(roadrunner_req:request(), roadrunner_http:headers()) ->
    roadrunner_http:headers().
with_close(Req, Headers) ->
    case roadrunner_conn:keep_alive_decision(Req, Headers) of
        keep_alive -> [{~"connection", ~"close"} | Headers];
        close -> Headers
    end.

%% Queue an encoded buffered response — or write it now. `buffered`
%% still holding inbound bytes means at least a fragment of the next
%% pipelined request is already in hand, so the response can wait for
%% the batch: it reaches the wire in one `flush_out/1` write at the
%% next socket boundary, and a pipelined burst pays one send instead
%% of one per response (the client receives the batch as one segment).
%% An empty `buffered` sends at dispatch — the same send point as the
%% immediate-send shape this replaces. The first clause is the
%% non-pipelined common case and touches NO loop-state (a measured
%% ~3-4% of single-in-flight throughput was two record copies per
%% request); the second closes out a burst by flushing the batch with
%% its last response appended.
-spec queue_response(#loop_state{}, iodata()) -> #loop_state{}.
queue_response(#loop_state{buffered = <<>>, out = [], socket = Socket} = S, Resp) ->
    _ = roadrunner_event:response_send(
        roadrunner_transport:send(Socket, Resp), buffered_response
    ),
    S;
queue_response(#loop_state{buffered = <<>>, out = Out} = S, Resp) ->
    flush_out(S#loop_state{out = [Out | Resp]});
queue_response(#loop_state{out = Out} = S, Resp) ->
    S#loop_state{out = [Out | Resp]}.

%% Write everything queued since the last flush in ONE send and reset
%% the accumulator. A send failure funnels through the same
%% `response_send` failure telemetry the per-response sends used, and
%% is otherwise discovered on the next socket operation — identical to
%% the immediate-send shape this replaces.
-spec flush_out(#loop_state{}) -> #loop_state{}.
flush_out(#loop_state{out = []} = S) ->
    S;
flush_out(#loop_state{socket = Socket, out = Out} = S) ->
    _ = roadrunner_event:response_send(
        roadrunner_transport:send(Socket, Out), buffered_response
    ),
    S#loop_state{out = []}.

%% Dispatches the 5 response shapes that match the
%% `roadrunner_handler:result/0` type. Stream / loop /
%% sendfile / websocket force connection close (the underlying
%% writers manage their own keep-alive semantics — generally none).
%% Buffered responses (the 3-tuple shapes) are QUEUED, not sent — see
%% `queue_response/2`; writer-owned shapes flush the queue first so
%% wire order matches dispatch order. Returns the updated loop state,
%% or `{ws_upgrade, Run, _}` when a WebSocket upgrade was answered.
-spec dispatch_response(
    #loop_state{},
    module(),
    roadrunner_req:request(),
    roadrunner_handler:response()
) -> #loop_state{} | {ws_upgrade, roadrunner_ws_session:run(), #loop_state{}}.
dispatch_response(S0, _Handler, Req, {websocket, Mod, State}) when is_atom(Mod) ->
    dispatch_websocket(S0, Req, Mod, State, #{});
dispatch_response(S0, _Handler, Req, {websocket, Mod, State, Opts}) when
    is_atom(Mod), is_map(Opts)
->
    dispatch_websocket(S0, Req, Mod, State, Opts);
dispatch_response(
    #loop_state{socket = Socket, alt_svc = AltSvc} = S0,
    _Handler,
    Req,
    {stream, Status, Headers0, Fun}
) when
    is_function(Fun, 1)
->
    %% The stream writer owns the wire from here — flush queued
    %% responses ahead of its first bytes, and the 100 a client may still
    %% hold its body back for ahead of the head.
    S = flush_out(disarm(S0)),
    ok = roadrunner_conn:continue_before_stream(Req),
    Headers = roadrunner_http:auto_headers(Headers0, AltSvc),
    _ = roadrunner_stream_response:run(Socket, Status, Headers, Fun),
    S;
dispatch_response(
    #loop_state{socket = Socket, alt_svc = AltSvc} = S0,
    Handler,
    Req,
    {loop, Status, Headers0, LoopState}
) when
    is_integer(Status)
->
    S = flush_out(disarm(S0)),
    ok = roadrunner_conn:continue_before_stream(Req),
    Headers = roadrunner_http:auto_headers(Headers0, AltSvc),
    _ = roadrunner_loop_response:run(Socket, Status, Headers, Handler, LoopState),
    S;
dispatch_response(
    #loop_state{socket = Socket, alt_svc = AltSvc} = S0,
    _Handler,
    Req,
    {sendfile, Status, Headers0, {Filename, Offset, Length}}
) when
    is_integer(Status)
->
    %% The body goes out via kernel sendfile, which can't join an
    %% iodata batch — flush queued responses ahead of the head.
    S = flush_out(S0),
    Head = roadrunner_http1:response(Status, Headers0, ~"", AltSvc),
    _ = roadrunner_event:response_send(
        roadrunner_transport:send(Socket, Head), sendfile_response_head
    ),
    ok =
        case roadrunner_req:method(Req) of
            ~"HEAD" ->
                ok;
            _ ->
                SendResult = roadrunner_transport:sendfile(
                    Socket, Filename, Offset, Length
                ),
                _ = roadrunner_event:response_send(SendResult, sendfile_body),
                %% A `{error, _}` here means the wire is mid-framing
                %% (short write, socket error, etc.). With keep-alive
                %% enabled on sendfile responses, the client would
                %% otherwise hang waiting for missing body bytes until
                %% its own timeout. Close the socket so the next
                %% read_request_phase recv returns `{error, closed}`
                %% and the conn exits normally instead of idling.
                case SendResult of
                    ok ->
                        ok;
                    {error, _} ->
                        _ = roadrunner_transport:close(Socket),
                        ok
                end
        end,
    S;
%% Buffered (3-tuple) response shape. RFC 9110 §9.3.2: HEAD must NOT
%% include a message body — match on `method := ~"HEAD"` in the
%% function head and emit the response with an empty body. Free
%% pattern-match dispatch (no `maps:get(method, _)` per response).
dispatch_response(
    #loop_state{alt_svc = AltSvc} = S,
    _Handler,
    #{method := ~"HEAD"},
    {Status, Headers0, Body}
) when
    is_integer(Status)
->
    Resp = roadrunner_http1:response(Status, framed(Status, Headers0, Body), ~"", AltSvc),
    queue_response(S, Resp);
dispatch_response(
    #loop_state{alt_svc = AltSvc} = S,
    _Handler,
    _Req,
    {Status, Headers0, Body}
) when
    is_integer(Status)
->
    Resp = roadrunner_http1:response(Status, framed(Status, Headers0, Body), Body, AltSvc),
    queue_response(S, Resp).

%% A buffered response with neither `content-length` nor
%% `transfer-encoding` has no end an HTTP/1.1 client can find on a
%% kept-alive connection (RFC 9112 §6.3), so it gets a `content-length`
%% from its body. For HEAD that is the length the GET would send (RFC
%% 9110 §8.6). 1xx, 204, and 304 carry no body and are left as they are
%% (RFC 9110 §8.6 forbids `content-length` on a 204).
-spec framed(roadrunner_http:status(), roadrunner_http:headers(), iodata()) ->
    roadrunner_http:headers().
framed(Status, Headers, _Body) when Status < 200; Status =:= 204; Status =:= 304 ->
    Headers;
framed(_Status, Headers, Body) ->
    case has_framing(Headers) of
        true -> Headers;
        false -> [{~"content-length", integer_to_binary(iolist_size(Body))} | Headers]
    end.

-spec has_framing(roadrunner_http:headers()) -> boolean().
has_framing([{~"content-length", _} | _]) -> true;
has_framing([{~"transfer-encoding", _} | _]) -> true;
has_framing([_ | Rest]) -> has_framing(Rest);
has_framing([]) -> false.

-spec dispatch_websocket(
    #loop_state{},
    roadrunner_req:request(),
    module(),
    term(),
    roadrunner_ws_handler:upgrade_opts()
) -> #loop_state{} | {ws_upgrade, roadrunner_ws_session:run(), #loop_state{}}.
dispatch_websocket(S0, Req, Mod, State, Opts) ->
    %% Queued pipelined responses must precede the 101 (or the 400/500
    %% reject) on the wire. The session arms the socket itself, so it
    %% starts from a passive one, with what was already read in
    %% `Buffered`.
    #loop_state{socket = Socket, buffered = Buffered, proto_opts = ProtoOpts} =
        S = flush_out(disarm(S0)),
    %% `start/7` returns right after the 101 with the session to run in
    %% this process (`Run`). A rejected upgrade (400/426/500 already sent,
    %% `connection: close`) falls through to the normal websocket
    %% finishing path.
    case roadrunner_ws_session:start(Socket, Req, Mod, State, Opts, Buffered, ProtoOpts) of
        %% The flushed state rides along so the caller never re-flushes
        %% the already-written batch from a stale pre-flush state.
        {upgrade, Run} -> {ws_upgrade, Run, S};
        rejected -> S
    end.

%% --- finishing phase ---
%%
%% Drain any unread manual-mode body bytes, then decide keep-alive
%% vs close. Buffered (3-tuple) and sendfile responses share the
%% same wire framing: a Content-Length header followed by exactly
%% that many body bytes. Both are keep-alive eligible. Stream /
%% loop / websocket writers emit arbitrary frame sequences with
%% their own lifecycle and force close.
%%
%% On keep-alive, recurse into `read_request_phase` with phase
%% flipped to `keep_alive`, the request-specific scratch fields
%% reset to defaults, and any pipelined leftover bytes carried in
%% `buffered` so the next iteration can parse them without waiting
%% on more inbound packets.
%% Pattern-matched on the response shape directly so we skip the
%% cross-module call to `roadrunner_conn:response_kind/1`.
-spec finishing_phase(#loop_state{}, roadrunner_req:request(), roadrunner_handler:response()) ->
    no_return().
finishing_phase(S, Req, {Status, Headers, _Body}) when is_integer(Status) ->
    buffered_finish(S, Req, Headers);
finishing_phase(S, Req, {sendfile, Status, Headers, _}) when is_integer(Status) ->
    buffered_finish(S, Req, Headers);
finishing_phase(S, Req, _Response) ->
    writer_finish(S, Req).

%% Stream / loop / websocket: writer owns the wire. In auto-mode the body is
%% already fully read; manual-mode may have leftover that needs draining,
%% or, when it cannot be, lingering over.
-spec writer_finish(#loop_state{}, roadrunner_req:request()) -> no_return().
writer_finish(S, Req) ->
    case drain_body_if_manual(Req) of
        {ok, _Leftover} -> exit_normal(S, normal);
        {error, _} -> exit_lingering(S, normal)
    end.

-spec buffered_finish(
    #loop_state{},
    roadrunner_req:request(),
    roadrunner_http:headers()
) -> no_return().
buffered_finish(S0, Req, Headers) ->
    %% A manual-mode request whose body the handler left (partly) unread
    %% is about to be drained, and the drain can read the socket — the
    %% just-queued response goes out first so a client that watches for
    %% it while still uploading isn't kept waiting on its own upload.
    %% Bodyless manual requests (`framing := none`, the pipelined-GET
    %% hot path) and auto mode (body consumed pre-dispatch) skip the
    %% flush and keep coalescing.
    S =
        case Req of
            #{body_reader := #{framing := none}} -> S0;
            #{body_reader := _} -> flush_out(S0);
            _ -> S0
        end,
    case drain_body_if_manual(Req) of
        {ok, ManualLeftover} ->
            case roadrunner_conn:keep_alive_decision(Req, Headers) of
                close ->
                    %% Either the client/handler asked to close, or
                    %% `ensure_close_signaled/3` added `Connection: close`
                    %% because this request tripped `max_keep_alive_requests`
                    %% — both land here, and both close the connection.
                    exit_normal(S, normal);
                keep_alive ->
                    Leftover = pipelined_leftover(Req, S, ManualLeftover),
                    S1 = release_request_slot(S),
                    read_request_phase(S1#loop_state{
                        phase = keep_alive,
                        buffered = Leftover
                    })
            end;
        {error, _} ->
            %% Drain failure (a body over its cap, never asked for, or
            %% broken) — close, lingering over what the client may still
            %% be sending.
            exit_lingering(S, normal)
    end.

%% The close path a WebSocket session runs in this process once it ends:
%% the websocket finishing path (`request_stop`, any unread manual-mode
%% body drained or lingered over, then the connection's own exit). The
%% upgrade's in-flight slot is already back: a session is a connection,
%% which `max_clients` bounds, and an exit signal that kills it would
%% skip this path and leave a held slot taken for good. It captures only
%% what that path reads, so the
%% session does not keep the connection state, the upgrade request and
%% the full listener options live for its whole lifetime: those were most
%% of the process's live data, and every full-sweep collection would
%% copy them again.
-spec ws_finish(
    #loop_state{},
    roadrunner_req:request(),
    roadrunner_event_handler:span(),
    roadrunner_handler:response()
) -> roadrunner_ws_session:finish().
ws_finish(
    #loop_state{
        socket = Socket,
        proto_opts = ProtoOpts,
        conn_span = ConnSpan,
        requests_served = Served
    },
    Req,
    Span,
    Response
) ->
    Close = roadrunner_conn:close_opts(ProtoOpts),
    Linger = maps:get(http1_linger_timeout, ProtoOpts, 1000),
    Status = roadrunner_conn:response_status(Response),
    Kind = roadrunner_conn:response_kind(Response),
    Reader = maps:get(body_reader, Req, none),
    fun() ->
        ok = roadrunner_event:request_stop(Span, Status, Kind),
        case drain_reader(Reader) of
            {ok, _Leftover} -> ok;
            {error, _} -> ok = roadrunner_conn:linger(Socket, Linger)
        end,
        exit_clean(Socket, Close, ConnSpan, Served, normal)
    end.

%% Manual-mode body_reader owns its post-body leftover (returned by
%% `drain_reader/1`). Auto-mode stashes the leftover in the loop state's
%% `buffered` field — set by `read_auto_body/4` from the body read, or
%% left as is by `read_body_phase/3` for a request with no body.
-spec pipelined_leftover(roadrunner_req:request(), #loop_state{}, binary()) -> binary().
pipelined_leftover(Req, _S, ManualLeftover) when is_map_key(body_reader, Req) ->
    ManualLeftover;
pipelined_leftover(_Req, #loop_state{buffered = Buf}, _ManualLeftover) ->
    Buf.

%% In auto-mode the body has already been fully read by
%% `read_body_phase` — the request map has no `body_reader` key, so
%% there is nothing to drain. Manual-mode (where the handler may have
%% left bytes unread) drains the body_reader (`drain_reader/1`).
-spec drain_body_if_manual(roadrunner_req:request()) ->
    {ok, binary()} | {error, term()}.
drain_body_if_manual(#{body_reader := Reader}) ->
    drain_reader(Reader);
drain_body_if_manual(_Req) ->
    {ok, <<>>}.

%% Drain a manual-mode body reader; `none` is a request without one.
-spec drain_reader(roadrunner_req:body_reader() | none) -> {ok, binary()} | {error, term()}.
drain_reader(none) ->
    {ok, <<>>};
drain_reader(#{continue := _}) ->
    %% The handler answered without asking for the body (`read_body/8`):
    %% no 100 went out and the client is holding the body back, so there is
    %% nothing to drain, and the connection closes.
    {error, body_not_requested};
drain_reader(Reader) ->
    roadrunner_conn:drain_reader(Reader).

%% 413 + close for a body over its cap, after any queued pipelined
%% responses, lingering over the body the client may be sending.
-spec refuse_too_large(#loop_state{}) -> no_return().
refuse_too_large(S) ->
    S1 = flush_out(S),
    ok = rejection(S1, content_length_too_large),
    _ = roadrunner_conn:send_payload_too_large(S1#loop_state.socket),
    exit_lingering(S1, rejected).

%% Close after a response sent before the request was read to its end,
%% lingering over what the client may still be sending
%% (`roadrunner_conn:linger/2`) for the listener's `http1` `linger_timeout`.
-spec exit_lingering(#loop_state{}, roadrunner_event_handler:close_reason()) -> no_return().
exit_lingering(#loop_state{socket = Socket, proto_opts = ProtoOpts} = S, Reason) ->
    %% The request is over; its slot is not held through the linger.
    S1 = flush_out(release_request_slot(S)),
    ok = roadrunner_conn:linger(Socket, maps:get(http1_linger_timeout, ProtoOpts, 1000)),
    exit_normal(S1, Reason).

%% Close after a response sent ahead of the handler, or for its crash: a
%% manual-mode body the request frames may still be on its way, so the
%% close lingers. An auto-mode body was read before dispatch.
-spec exit_unread(#loop_state{}, roadrunner_req:request()) -> no_return().
exit_unread(S, #{body_reader := #{framing := Framing}}) when Framing =/= none ->
    exit_lingering(S, normal);
exit_unread(S, _Req) ->
    exit_normal(S, normal).

-spec rejection(#loop_state{}, atom()) -> ok.
rejection(#loop_state{listener_name = ListenerName, peer = Peer}, Reason) ->
    roadrunner_event:request_rejected(ListenerName, Peer, Reason).

%% Hand a writer-owned response (stream, loop, WebSocket) a passive
%% socket, as `once` leaves it after a request: it reads the socket
%% itself, or runs handler code that receives on the mailbox. Reads
%% already queued stay queued, in order, for whoever reads next: a body
%% reader takes them before the socket (`roadrunner_conn:disarmed/0`),
%% and the WebSocket session and the loop response read socket messages
%% themselves. Only the passive message goes, so it never reaches
%% handler code. These responses close the connection after them, so
%% the socket is never armed again.
-spec disarm(#loop_state{}) -> #loop_state{}.
disarm(#loop_state{recv_mode = Mode} = S) ->
    case active_count(Mode) of
        once -> S;
        _N -> passive(S)
    end.

-spec passive(#loop_state{}) -> #loop_state{}.
passive(#loop_state{socket = Socket} = S) ->
    _ = roadrunner_transport:setopts(Socket, [{active, false}]),
    ok = roadrunner_conn:disarmed(),
    ok = drop_passive(roadrunner_transport:passive_message(Socket)),
    S#loop_state{recv_mode = once}.

-spec drop_passive(atom()) -> ok.
drop_passive(PassiveTag) ->
    receive
        {PassiveTag, _Sock} -> drop_passive(PassiveTag)
    after 0 ->
        ok
    end.

%% Arm `{active, N}`: at the connection's start and on each passive
%% message. A failed arm means the socket is gone.
-spec arm_active_n(#loop_state{}, pos_integer()) -> ok.
arm_active_n(#loop_state{socket = Socket} = S, N) ->
    case roadrunner_transport:setopts(Socket, [{active, N}]) of
        ok -> roadrunner_conn:armed(N);
        {error, Reason} -> exit_normal(S, transport_reason(Reason))
    end.

%% A stray message did not use up an `{active, once}` arm, but arming
%% again is how the hibernating `once` path has always resumed; an
%% `{active, N}` socket is still armed, and arming it again would add
%% `N` more unread reads.
-spec rearm_after_stray(#loop_state{}, once | 1..32767) -> ok.
rearm_after_stray(S, once) -> arm_active_once(S);
rearm_after_stray(_S, _N) -> ok.

-spec arm_active_once(#loop_state{}) -> ok.
arm_active_once(#loop_state{socket = Socket} = S) ->
    %% On socket failure (peer RST during the gap, kernel-side close)
    %% we can't `setopts` — exit cleanly instead of crashing.
    case roadrunner_transport:setopts(Socket, [{active, once}]) of
        ok -> ok;
        {error, Reason} -> exit_normal(S, transport_reason(Reason))
    end.

%% A timed-out read waited for the connection's first request, or
%% idled between requests on a kept-alive one.
-spec timeout_reason(#loop_state{}) -> request_timeout | keep_alive_timeout.
timeout_reason(#loop_state{phase = first}) -> request_timeout;
timeout_reason(#loop_state{phase = keep_alive}) -> keep_alive_timeout.

-spec transport_reason(term()) -> roadrunner_event_handler:close_reason().
transport_reason(closed) -> peer_closed;
transport_reason(Reason) -> {transport, Reason}.

%% Convenience wrapper around `exit_clean/5` that pulls fields off
%% the loop state. Most exit paths in the read/dispatch/finishing
%% phases fire `listener_conn_close` (accept already fired during
%% `shoot`), carrying why the connection ended.
-spec exit_normal(#loop_state{}, roadrunner_event_handler:close_reason()) -> no_return().
exit_normal(S, Reason) ->
    #loop_state{
        socket = Socket,
        proto_opts = ProtoOpts,
        conn_span = ConnSpan,
        requests_served = Served
    } = flush_out(release_request_slot(S)),
    exit_clean(Socket, ProtoOpts, ConnSpan, Served, Reason).

%% Funnel for every clean exit path once the connection was accepted.
%% Fires the paired `listener_conn_close` event, then releases the
%% listener slot, closes the socket, and exits normally.
%%
%% **Limitation**: under `exit(Pid, kill)` this funnel is skipped — the
%% runtime tears the process down without giving it a chance to run
%% any cleanup. Same OTP semantics as `terminate/3` callbacks. Bounded
%% by `max_clients` and reset on listener restart.
-spec exit_clean(
    roadrunner_transport:socket(),
    roadrunner_conn:close_opts(),
    roadrunner_event_handler:span(),
    non_neg_integer(),
    roadrunner_event_handler:close_reason()
) -> no_return().
exit_clean(Socket, ProtoOpts, ConnSpan, Served, Reason) ->
    ok = roadrunner_event:listener_conn_close(ConnSpan, Served, Reason),
    exit_unaccepted(Socket, ProtoOpts).

%% Exit before `listener_accept` fired (a drain or a bad PROXY header
%% ahead of `serve/5`), so no `listener_conn_close` pairs with it:
%% release the listener slot, close the socket, and exit normally.
-spec exit_unaccepted(roadrunner_transport:socket(), roadrunner_conn:close_opts()) ->
    no_return().
exit_unaccepted(Socket, ProtoOpts) ->
    ok = roadrunner_conn:unregister_for_drain(ProtoOpts),
    ok = roadrunner_conn:release_slot(ProtoOpts),
    ok = roadrunner_transport:close(Socket),
    exit(normal).
