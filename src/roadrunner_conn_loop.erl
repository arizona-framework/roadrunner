-module(roadrunner_conn_loop).
-moduledoc """
Tail-recursive synchronous connection loop — alternative to
`roadrunner_conn_statem`'s `gen_statem` implementation.

Same per-connection lifecycle the gen_statem encodes
(`awaiting_shoot → reading_request → reading_body → dispatching →
finishing → loop or close`) but expressed as direct function calls
between phase functions instead of gen_statem dispatch + state-enter
trampolines.

## Phase introspection vs hot-path cost

The label set on the conn process via `proc_lib:set_label/1` is
intentionally written **at most twice per conn**: once at
`init_loop` time (`{roadrunner_conn, awaiting_shoot, ListenerName}`)
and once at the `shoot` handoff (`refine_conn_label/2` rewrites it
to include the peer). The phases AFTER `awaiting_shoot` (read_request,
read_body, dispatching, finishing) run in microseconds on the
happy path — too fast for an operator's `observer` snapshot to
catch a specific phase anyway. Profiling showed per-phase label
updates cost ~1.2 % CPU on hello (4 writes/req, each touching the
process dictionary), and contributed to the run-to-run variance.
Stuck conns still surface via the conn-entry label + the
`reading_request` idle window (where hibernation parks the
process). Sub-microsecond phases that no one ever observes don't
pay this cost.

Selected per-listener via `proto_opts.conn_impl => loop`. Default is
`statem`, which dispatches to `roadrunner_conn_statem`. The two
implementations are wire-equivalent — same accept/drain/telemetry
contract, same body-framing decisions, same keep-alive rules. The
loop variant exists to recover the throughput + variance gap with
elli without giving up roadrunner's stability features (drain,
slot tracking, telemetry pairing, hibernation, lifecycle
introspection). See `.claude/plans/sorted-discovering-thimble.md`
for the phased rollout.

## Phases shipped so far

- **Phase 1** — `awaiting_shoot` + clean exit funnel (`exit_clean/6`).
- **Phase 2** — `read_request_phase` with active-mode header read,
  parse via `roadrunner_http1:parse_request/1`, 400 / 408 error
  responses, drain handling, `request_timeout` via the receive's
  `after` clause (no `start_timer` arms), stray-msg tolerance.
- **Phase 3a** — `read_body_phase`, `dispatch_phase` (buffered
  3-tuple response shape only), `finishing_phase` (close after
  each request — keep-alive lands in 3c). Telemetry pairing for
  `[roadrunner, request, start | stop | exception]` with shared
  `StartMono`. 413 for oversized bodies, 500 for handler crashes,
  404 for not_found dispatch.
- **Phase 3b** — full dispatch_response/4 with all 5 response
  shapes: buffered (3-tuple), `{stream, ...}`, `{loop, ...}`,
  `{sendfile, ...}`, `{websocket, ...}`. Stream / loop / sendfile /
  websocket all force connection close (matching the gen_statem's
  contract). The stream/loop/ws response writers
  (`roadrunner_stream_response:run/4`, etc.) are reused as-is.
- **Phase 3c** — keep-alive loop-back. `finishing_phase` decides
  keep-alive vs close per `roadrunner_conn:keep_alive_decision/2`;
  on keep-alive (and under `max_keep_alive_request`), recurses
  into `read_request_phase` with `phase = keep_alive`, the
  pipelined leftover bytes carried in `buffered`, and
  `requests_served + 1`. Pipelined two-requests-in-one-packet
  works because `handle_request_bytes/2` parses the buffer
  before re-arming the socket. `request_timeout` selection
  becomes phase-aware (first vs keep_alive_timeout) and the
  timeout response is silent on keep_alive (no peer waiting).
- **Phase 4** — hibernation. When the listener was started with
  `hibernate_after => Ms` (Ms > 0), the keep-alive idle window
  in `recv_request_bytes/2` calls `erlang:hibernate/3` after Ms
  of no message — the conn's heap GCs and shrinks, dramatically
  reducing memory for long-lived idle keep-alive conns. A
  `send_after` timer carries the request/keep-alive deadline as
  a normal message so the hibernate `after` clause is dedicated
  to the idle-trigger. Wakes naturally on the next inbound TCP
  packet. Listeners without `hibernate_after` bypass this entirely
  and use the Phase 2/3 receive shape (no timer per request).

Pending: Phase 5 (top-level try/catch around `exit_clean`),
Phase 6 (test parametrization), Phase 7 (A/B vs gen_statem),
Phase 8 (cutover or park).
""".

-export([start/2]).

%% Internal entries — invoked via `proc_lib:start/3` and via
%% `erlang:hibernate/3`. Must stay exported so the runtime can
%% re-enter them after wake-from-hibernate.
-export([init_loop/3, recv_request_bytes_hib/2]).

%% Loop-state record carried through every phase. Allocated once on
%% the transition out of `awaiting_shoot` and pattern-matched (not
%% reconstructed) thereafter, so the per-request hot path stays
%% allocation-light.
-record(loop_state, {
    socket :: roadrunner_transport:socket(),
    proto_opts :: roadrunner_conn:proto_opts(),
    listener_name :: atom(),
    %% Captured at `shoot` from `roadrunner_telemetry:listener_accept/1`.
    %% Paired with `listener_conn_close` in `exit_clean/2`.
    start_mono :: integer(),
    peer :: {inet:ip_address(), inet:port_number()} | undefined,
    scheme = http :: http | https,
    %% `first` for the first request on a fresh conn; `keep_alive` for
    %% subsequent loop-back iterations. Drives the timeout selection
    %% (request_timeout vs keep_alive_timeout) and the silent-vs-408
    %% behavior in `recv_request_bytes/2`'s `after` clause.
    phase = first :: first | keep_alive,
    %% Cumulative successfully-served requests on this conn. Bumped
    %% in `run_pipeline/4` after each successful dispatch; checked in
    %% `finishing_phase/3` against `max_keep_alive_request`.
    requests_served = 0 :: non_neg_integer(),
    %% Bytes received but not yet parsed. Empty on first iteration;
    %% populated mid-recv when `parse_request/1` returns `{more, _}`,
    %% AND on the keep-alive loop-back when a prior request's body
    %% drain leaves post-body bytes (RFC 7230 §6.3 pipelining).
    buffered = <<>> :: binary()
}).

-spec start(roadrunner_transport:socket(), roadrunner_conn:proto_opts()) ->
    {ok, pid()}.
start(Socket, ProtoOpts) when is_map(ProtoOpts) ->
    %% Unlinked from the acceptor — a single-conn crash never propagates
    %% to the acceptor pool. Mirrors `gen_statem:start/3` (NOT start_link)
    %% so existing acceptor handoff (`controlling_process` then `! shoot`)
    %% works without modification.
    Parent = self(),
    proc_lib:start(?MODULE, init_loop, [Parent, Socket, ProtoOpts]).

-doc false.
-spec init_loop(pid(), roadrunner_transport:socket(), roadrunner_conn:proto_opts()) ->
    no_return().
init_loop(Parent, Socket, ProtoOpts) ->
    ListenerName = maps:get(listener_name, ProtoOpts, undefined),
    proc_lib:set_label({roadrunner_conn, awaiting_shoot, ListenerName}),
    ok = roadrunner_conn:join_drain_group(ListenerName),
    proc_lib:init_ack(Parent, {ok, self()}),
    awaiting_shoot(Socket, ProtoOpts, ListenerName).

-spec awaiting_shoot(roadrunner_transport:socket(), roadrunner_conn:proto_opts(), atom()) ->
    no_return().
awaiting_shoot(Socket, ProtoOpts, ListenerName) ->
    receive
        shoot ->
            %% Socket ownership has just transferred from the acceptor —
            %% refine the proc_lib label with the peer (which we couldn't
            %% know on init/1 because the OS-level socket wasn't ours yet).
            Peer = roadrunner_conn:peer(Socket),
            ok = roadrunner_conn:refine_conn_label(ProtoOpts, Peer),
            Scheme = roadrunner_conn:scheme(Socket),
            StartMono = roadrunner_telemetry:listener_accept(#{
                listener_name => ListenerName, peer => Peer
            }),
            S = #loop_state{
                socket = Socket,
                proto_opts = ProtoOpts,
                listener_name = ListenerName,
                start_mono = StartMono,
                peer = Peer,
                scheme = Scheme
            },
            read_request_phase(S);
        {roadrunner_drain, _Deadline} ->
            %% Drain before `shoot` — no telemetry was fired yet (accept
            %% pairs with `shoot`), so no listener_conn_close either. Just
            %% release the slot and close the socket.
            exit_clean(Socket, ProtoOpts, undefined, undefined, ListenerName, 0, normal);
        _Stray ->
            %% Stray-msg tolerance — gen_statem drops unmatched info events
            %% silently; we do the same so a buggy library can't crash the
            %% conn with a typo'd message.
            awaiting_shoot(Socket, ProtoOpts, ListenerName)
    end.

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
%%      slowloris — no `start_timer` / `cancel_timer` per iteration,
%%      unlike the gen_statem variant.
%%
%% Phase 2 only handles the "first request on a fresh conn" case;
%% Phase 3 will add keep-alive loop-back and pipelined leftover.
-spec read_request_phase(#loop_state{}) -> no_return().
read_request_phase(#loop_state{buffered = Buf} = S) ->
    Timeout = phase_timeout(S),
    %% Compute an *absolute* deadline once. Each iteration's `after`
    %% clause decays it — `recv_request_bytes/2` recomputes
    %% `Deadline - now` so a slow client that drips bytes can NOT keep
    %% extending the receive's timeout. Mirrors gen_statem's one-shot
    %% `state_timeout` semantics in a hand-rolled receive.
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case Buf of
        <<>> ->
            arm_active_once(S),
            recv_request_bytes(S, Deadline);
        _ ->
            %% Pipelined leftover from a prior keep-alive iteration —
            %% try parsing it before arming the socket. If the parse
            %% returns `{more, _}` we'll arm and wait for more bytes.
            handle_request_bytes(S, Deadline)
    end.

%% First requests use `request_timeout`; keep-alive loop-backs use
%% `keep_alive_timeout` (typically shorter — connections that have
%% nothing to do drop faster).
-spec phase_timeout(#loop_state{}) -> non_neg_integer().
phase_timeout(#loop_state{phase = first, proto_opts = ProtoOpts}) ->
    maps:get(request_timeout, ProtoOpts);
phase_timeout(#loop_state{phase = keep_alive, proto_opts = ProtoOpts}) ->
    maps:get(keep_alive_timeout, ProtoOpts).

-spec recv_request_bytes(#loop_state{}, integer()) -> no_return().
recv_request_bytes(S, Deadline) ->
    case maps:get(hibernate_after, S#loop_state.proto_opts, 0) of
        Ms when is_integer(Ms), Ms > 0 ->
            recv_with_hibernate(S, Deadline, Ms);
        _ ->
            recv_no_hibernate(S, Deadline)
    end.

%% Recv path with no hibernation — single `after Remaining` clause
%% handles both request_timeout and keep_alive_timeout. Zero per-iter
%% timer arms on the hot path.
-spec recv_no_hibernate(#loop_state{}, integer()) -> no_return().
recv_no_hibernate(
    #loop_state{
        socket = Socket,
        buffered = Buf
    } = S,
    Deadline
) ->
    {DataTag, ClosedTag, ErrorTag} = roadrunner_transport:messages(Socket),
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {DataTag, _Sock, Bytes} ->
            handle_request_bytes(S#loop_state{buffered = <<Buf/binary, Bytes/binary>>}, Deadline);
        {ClosedTag, _Sock} ->
            %% Peer closed mid-headers — silent exit, no 4xx (peer's
            %% gone, no point writing).
            exit_normal(S);
        {ErrorTag, _Sock, _Reason} ->
            exit_normal(S);
        {roadrunner_drain, _Deadline} ->
            exit_normal(S);
        _Stray ->
            %% Drop unmatched messages (gen_statem does the same via
            %% the wildcard `info` clause) and re-arm.
            arm_active_once(S),
            recv_no_hibernate(S, Deadline)
    after Remaining ->
        timeout_response(S),
        exit_normal(S)
    end.

%% Recv path with hibernation. Arms ONE `send_after` for the
%% request/keep-alive deadline and uses the receive's `after` clause
%% exclusively for the hibernate trigger. On wake (any inbound
%% message) the function re-enters via `erlang:hibernate/3`'s
%% `(?MODULE, recv_request_bytes_hib, [S, Deadline])` continuation.
-spec recv_with_hibernate(#loop_state{}, integer(), pos_integer()) -> no_return().
recv_with_hibernate(
    #loop_state{
        socket = Socket,
        buffered = Buf
    } = S,
    Deadline,
    HibernateAfter
) ->
    {DataTag, ClosedTag, ErrorTag} = roadrunner_transport:messages(Socket),
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    DeadlineRef = erlang:send_after(Remaining, self(), {?MODULE, deadline_fired}),
    receive
        {DataTag, _Sock, Bytes} ->
            _ = erlang:cancel_timer(DeadlineRef),
            handle_request_bytes(S#loop_state{buffered = <<Buf/binary, Bytes/binary>>}, Deadline);
        {ClosedTag, _Sock} ->
            _ = erlang:cancel_timer(DeadlineRef),
            exit_normal(S);
        {ErrorTag, _Sock, _Reason} ->
            _ = erlang:cancel_timer(DeadlineRef),
            exit_normal(S);
        {roadrunner_drain, _Deadline} ->
            _ = erlang:cancel_timer(DeadlineRef),
            exit_normal(S);
        {?MODULE, deadline_fired} ->
            timeout_response(S),
            exit_normal(S);
        _Stray ->
            _ = erlang:cancel_timer(DeadlineRef),
            arm_active_once(S),
            recv_with_hibernate(S, Deadline, HibernateAfter)
    after HibernateAfter ->
        %% Idle window elapsed — drop the deadline timer (it'll
        %% be re-armed when the conn wakes) and hibernate. The
        %% process's heap GCs and shrinks; the next inbound
        %% TCP packet wakes it.
        _ = erlang:cancel_timer(DeadlineRef),
        erlang:hibernate(?MODULE, recv_request_bytes_hib, [S, Deadline])
    end.

%% Hibernate continuation. Re-enters `recv_request_bytes/2` so
%% the next iteration picks up wherever the recv shape demands
%% (with or without hibernation, depending on `hibernate_after`).
-doc false.
-spec recv_request_bytes_hib(#loop_state{}, integer()) -> no_return().
recv_request_bytes_hib(S, Deadline) ->
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
%% request (Phase 2 placeholder: exit clean — Phase 3 will dispatch
%% body + handler); on `{error, _}` we send 400 and exit.
-spec handle_request_bytes(#loop_state{}, integer()) -> no_return().
handle_request_bytes(
    #loop_state{
        socket = Socket,
        listener_name = ListenerName,
        peer = Peer,
        scheme = Scheme,
        proto_opts = ProtoOpts
    } = S,
    Deadline
) ->
    Buf = S#loop_state.buffered,
    case roadrunner_http1:parse_request(Buf) of
        {ok, Req0, Rest} ->
            ReqCounter = maps:get(requests_counter, ProtoOpts),
            _ = atomics:add(ReqCounter, 1, 1),
            RequestId = roadrunner_conn:generate_request_id(),
            Req = Req0#{
                peer => Peer,
                scheme => Scheme,
                request_id => RequestId,
                listener_name => ListenerName
            },
            ok = roadrunner_conn:set_request_logger_metadata(Req),
            ok = roadrunner_conn:maybe_send_continue(Socket, Req, Rest),
            read_body_phase(S#loop_state{buffered = Rest}, Req, Deadline);
        {more, _} ->
            arm_active_once(S),
            recv_request_bytes(S, Deadline);
        {error, Reason} ->
            logger:debug(#{
                msg => "roadrunner rejecting malformed request",
                peer => Peer,
                listener_name => ListenerName,
                reason => Reason
            }),
            ok = roadrunner_telemetry:request_rejected(#{
                listener_name => ListenerName,
                peer => Peer,
                reason => Reason
            }),
            _ = roadrunner_conn:send_bad_request(Socket),
            exit_normal(S)
    end.

%% --- read_body phase ---
%%
%% Auto-buffering reads the full body synchronously via the recv
%% closure (passive `gen_tcp:recv` with the request_timeout deadline).
%% Manual buffering builds a body_state the handler will pull from
%% via `roadrunner_req:read_body/1,2`.
-spec read_body_phase(#loop_state{}, roadrunner_http1:request(), integer()) -> no_return().
read_body_phase(
    #loop_state{
        socket = Socket,
        proto_opts = ProtoOpts
    } = S,
    Req,
    Deadline
) ->
    MaxCL = maps:get(max_content_length, ProtoOpts),
    MinRate = maps:get(minimum_bytes_per_second, ProtoOpts),
    Recv = roadrunner_conn:make_recv(Socket, Deadline, MinRate),
    Buffered = S#loop_state.buffered,
    case maps:get(body_buffering, ProtoOpts) of
        auto ->
            case roadrunner_conn:read_body(Req, Buffered, Recv, MaxCL) of
                {ok, Body, Leftover} ->
                    %% Leftover is bytes past the body — Phase 3c will
                    %% feed it back to the next reading_request iteration
                    %% as pipelined leftover. Phase 3a closes after one
                    %% request, so it's discarded here.
                    dispatch_phase(S#loop_state{buffered = Leftover}, Req#{body => Body});
                {error, content_length_too_large} ->
                    _ = roadrunner_conn:drain_oversized_body(Buffered, Socket, MaxCL),
                    ok = rejection(S, content_length_too_large),
                    _ = roadrunner_conn:send_payload_too_large(Socket),
                    exit_normal(S);
                {error, request_timeout} ->
                    _ = roadrunner_conn:send_request_timeout(Socket),
                    exit_normal(S);
                {error, slow_client} ->
                    exit_normal(S);
                {error, BodyReason} ->
                    ok = rejection(S, BodyReason),
                    _ = roadrunner_conn:send_bad_request(Socket),
                    exit_normal(S)
            end;
        manual ->
            case roadrunner_conn:body_framing(Req) of
                {error, FramingReason} ->
                    ok = rejection(S, FramingReason),
                    _ = roadrunner_conn:send_bad_request(Socket),
                    exit_normal(S);
                Framing ->
                    BodyState = roadrunner_conn:make_body_state(
                        Framing, Buffered, Recv, MaxCL
                    ),
                    dispatch_phase(S, Req#{body_state => BodyState})
            end
    end.

%% --- dispatch phase ---
%%
%% Resolve handler (single-handler or routed), build the middleware
%% pipeline, run it bracketed by request_start / request_stop |
%% request_exception telemetry. The 5 response shapes (buffered,
%% stream, loop, sendfile, websocket) dispatch to their respective
%% writers — Phase 3a wires the buffered (3-tuple) shape only;
%% the remaining four land in Phase 3b.
-spec dispatch_phase(#loop_state{}, roadrunner_http1:request()) -> no_return().
dispatch_phase(
    #loop_state{
        socket = Socket,
        proto_opts = ProtoOpts
    } = S,
    Req
) ->
    Dispatch = maps:get(dispatch, ProtoOpts),
    ListenerMws = maps:get(middlewares, ProtoOpts),
    case roadrunner_conn:resolve_handler(Dispatch, Req) of
        {ok, Handler, Bindings, RouteOpts} ->
            FullReq = Req#{bindings => Bindings, route_opts => RouteOpts},
            run_pipeline(S, Handler, FullReq, ListenerMws);
        not_found ->
            _ = roadrunner_conn:send_not_found(Socket),
            exit_normal(S)
    end.

-spec run_pipeline(
    #loop_state{},
    module(),
    roadrunner_http1:request(),
    roadrunner_middleware:middleware_list()
) -> no_return().
run_pipeline(#loop_state{socket = Socket} = S, Handler, Req, ListenerMws) ->
    RouteMws = roadrunner_conn:route_middlewares(Req),
    %% Common production case: handler dispatch with no middlewares
    %% (listener empty AND route empty). Skip the compose helper —
    %% it would just wrap `Handler:handle/1` in another fun and fall
    %% through. Direct call avoids one closure allocation + one
    %% indirection per request.
    Pipeline =
        case ListenerMws =:= [] andalso RouteMws =:= [] of
            true ->
                fun Handler:handle/1;
            false ->
                roadrunner_middleware:compose(
                    ListenerMws ++ RouteMws,
                    fun(R) -> Handler:handle(R) end
                )
        end,
    Metadata = telemetry_metadata(Req),
    ReqStart = roadrunner_telemetry:request_start(Metadata),
    try Pipeline(Req) of
        {Response, Req2} when is_map(Req2) ->
            _ = dispatch_response(Socket, Handler, Req2, Response),
            ok = roadrunner_telemetry:request_stop(ReqStart, Metadata, #{
                status => roadrunner_conn:response_status(Response),
                response_kind => roadrunner_conn:response_kind(Response)
            }),
            finishing_phase(
                S#loop_state{requests_served = S#loop_state.requests_served + 1},
                Req2,
                Response
            )
    catch
        Class:Reason:Stack ->
            ok = roadrunner_telemetry:request_exception(
                ReqStart, Metadata, Class, Reason
            ),
            logger:error(#{
                msg => "roadrunner handler crashed",
                handler => Handler,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            _ = roadrunner_conn:send_internal_error(Socket),
            exit_normal(S)
    end.

%% Mirrors `roadrunner_conn_statem:dispatch_response/4` exactly. The 5
%% shapes match the `roadrunner_handler:result/0` type. Stream / loop /
%% sendfile / websocket force connection close (the underlying
%% writers manage their own keep-alive semantics — generally none).
-spec dispatch_response(
    roadrunner_transport:socket(),
    module(),
    roadrunner_http1:request(),
    roadrunner_handler:response()
) -> ok.
dispatch_response(Socket, _Handler, Req, {websocket, Mod, State}) when is_atom(Mod) ->
    _ = roadrunner_ws_session:run(Socket, Req, Mod, State),
    ok;
dispatch_response(Socket, _Handler, _Req, {stream, Status, Headers, Fun}) when
    is_function(Fun, 1)
->
    _ = roadrunner_stream_response:run(Socket, Status, Headers, Fun),
    ok;
dispatch_response(Socket, Handler, _Req, {loop, Status, Headers, LoopState}) when
    is_integer(Status)
->
    _ = roadrunner_loop_response:run(Socket, Status, Headers, Handler, LoopState),
    ok;
dispatch_response(
    Socket, _Handler, Req, {sendfile, Status, Headers, {Filename, Offset, Length}}
) when
    is_integer(Status)
->
    Head = roadrunner_http1:response(Status, Headers, ~""),
    _ = roadrunner_telemetry:response_send(
        roadrunner_transport:send(Socket, Head), sendfile_response_head
    ),
    _ =
        case roadrunner_req:method(Req) of
            ~"HEAD" ->
                ok;
            _ ->
                roadrunner_telemetry:response_send(
                    roadrunner_transport:sendfile(Socket, Filename, Offset, Length),
                    sendfile_body
                )
        end,
    ok;
dispatch_response(Socket, _Handler, Req, {Status, Headers, Body}) when is_integer(Status) ->
    RespBody = roadrunner_conn:response_body_for(Req, Body),
    Resp = roadrunner_http1:response(Status, Headers, RespBody),
    _ = roadrunner_telemetry:response_send(
        roadrunner_transport:send(Socket, Resp), buffered_response
    ),
    ok.

%% --- finishing phase ---
%%
%% Drain any unread manual-mode body bytes, then decide keep-alive
%% vs close. Stream / loop / sendfile / websocket all force close
%% (their writers manage their own lifecycle); only buffered
%% (3-tuple) responses are eligible for keep-alive.
%%
%% On keep-alive, recurse into `read_request_phase` with phase
%% flipped to `keep_alive`, the request-specific scratch fields
%% reset to defaults, and any pipelined leftover bytes carried in
%% `buffered` so the next iteration can parse them without waiting
%% on more inbound packets.
-spec finishing_phase(#loop_state{}, roadrunner_http1:request(), roadrunner_handler:response()) ->
    no_return().
finishing_phase(
    #loop_state{
        proto_opts = ProtoOpts
    } = S,
    Req,
    Response
) ->
    case roadrunner_conn:response_kind(Response) of
        buffered ->
            buffered_finish(S, Req, Response, ProtoOpts);
        _ ->
            %% Stream / loop / sendfile / websocket: writer owns the
            %% wire from here. Close the conn.
            _ = roadrunner_conn:drain_body(Req),
            exit_normal(S)
    end.

-spec buffered_finish(
    #loop_state{},
    roadrunner_http1:request(),
    roadrunner_handler:response(),
    roadrunner_conn:proto_opts()
) -> no_return().
buffered_finish(S, Req, {_Status, Headers, _Body} = _Response, ProtoOpts) ->
    case roadrunner_conn:drain_body(Req) of
        {ok, ManualLeftover} ->
            case roadrunner_conn:keep_alive_decision(Req, Headers) of
                close ->
                    exit_normal(S);
                keep_alive ->
                    Max = maps:get(max_keep_alive_request, ProtoOpts),
                    Served = S#loop_state.requests_served,
                    case Served >= Max of
                        true ->
                            exit_normal(S);
                        false ->
                            Leftover = pipelined_leftover(Req, S, ManualLeftover),
                            read_request_phase(S#loop_state{
                                phase = keep_alive,
                                buffered = Leftover
                            })
                    end
            end;
        {error, _} ->
            %% Drain failure — close. Manual-mode handlers can leave the
            %% body_state in a broken state if they read past EOF.
            exit_normal(S)
    end.

%% Manual-mode body_state owns its post-body leftover (returned by
%% `drain_body/1`). Auto-mode stashes the leftover in the loop state's
%% `buffered` field — set by `read_body_phase` on `read_body/4` return.
-spec pipelined_leftover(roadrunner_http1:request(), #loop_state{}, binary()) -> binary().
pipelined_leftover(Req, _S, ManualLeftover) when is_map_key(body_state, Req) ->
    ManualLeftover;
pipelined_leftover(_Req, #loop_state{buffered = Buf}, _ManualLeftover) ->
    Buf.

-spec telemetry_metadata(roadrunner_http1:request()) -> roadrunner_telemetry:metadata().
telemetry_metadata(Req) ->
    #{
        request_id => maps:get(request_id, Req),
        peer => maps:get(peer, Req),
        method => maps:get(method, Req),
        path => maps:get(target, Req),
        scheme => maps:get(scheme, Req),
        listener_name => maps:get(listener_name, Req, undefined)
    }.

-spec rejection(#loop_state{}, atom()) -> ok.
rejection(#loop_state{listener_name = ListenerName, peer = Peer}, Reason) ->
    roadrunner_telemetry:request_rejected(#{
        listener_name => ListenerName, peer => Peer, reason => Reason
    }).

-spec arm_active_once(#loop_state{}) -> ok.
arm_active_once(#loop_state{socket = Socket} = S) ->
    %% On socket failure (peer RST during the gap, kernel-side close)
    %% we can't `setopts` — exit cleanly instead of crashing.
    case roadrunner_transport:setopts(Socket, [{active, once}]) of
        ok -> ok;
        {error, _} -> exit_normal(S)
    end.

%% Convenience wrapper around `exit_clean/7` that pulls fields off
%% the loop state. Most exit paths in the read/dispatch/finishing
%% phases fire `listener_conn_close` (accept already fired during
%% `shoot`).
-spec exit_normal(#loop_state{}) -> no_return().
exit_normal(#loop_state{
    socket = Socket,
    proto_opts = ProtoOpts,
    listener_name = ListenerName,
    start_mono = StartMono,
    peer = Peer,
    requests_served = Served
}) ->
    exit_clean(Socket, ProtoOpts, StartMono, Peer, ListenerName, Served, normal).

%% Funnel for every clean exit path. Mirrors `roadrunner_conn_statem:terminate/3`
%% — fires the paired listener_conn_close telemetry (only if accept already
%% fired), releases the listener slot, closes the socket, and exits with the
%% supplied Reason.
%%
%% **Limitation**: under `exit(Pid, kill)` this funnel is skipped (same
%% gen_statem limitation today). Bounded by `max_clients` and reset on
%% listener restart.
-spec exit_clean(
    roadrunner_transport:socket(),
    roadrunner_conn:proto_opts(),
    integer() | undefined,
    {inet:ip_address(), inet:port_number()} | undefined,
    atom(),
    non_neg_integer(),
    term()
) -> no_return().
exit_clean(Socket, ProtoOpts, StartMono, Peer, ListenerName, Served, Reason) ->
    case StartMono of
        undefined ->
            ok;
        _ ->
            roadrunner_telemetry:listener_conn_close(StartMono, #{
                listener_name => ListenerName,
                peer => Peer,
                requests_served => Served
            })
    end,
    ok = roadrunner_conn:release_slot(ProtoOpts),
    ok = roadrunner_transport:close(Socket),
    exit(Reason).
