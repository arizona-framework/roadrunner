-module(roadrunner_conn_loop).
-moduledoc """
Tail-recursive synchronous connection loop — alternative to
`roadrunner_conn_statem`'s `gen_statem` implementation.

Same per-connection lifecycle the gen_statem encodes
(`awaiting_shoot → reading_request → reading_body → dispatching →
finishing → loop or close`) but expressed as direct function calls
between phase functions instead of gen_statem dispatch + state-enter
trampolines. The five phase names stay visible to operators via
`proc_lib:set_label/1` updates at every boundary, so `observer`,
`recon:proc_count/2`, and crash reports still show what the
connection was doing.

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

Pending: Phase 3b (stream/loop/sendfile/websocket dispatch
shapes), Phase 3c (keep-alive loop-back + pipelined leftover),
Phase 4 (hibernation), Phase 5 (top-level try/catch around
`exit_clean`), Phase 6 (test parametrization), Phase 7 (A/B vs
gen_statem), Phase 8 (cutover or park).
""".

-export([start/2]).

%% Internal entry — invoked by `proc_lib:start/3` from `start/2`.
-export([init_loop/3]).

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
    %% Cumulative successfully-served requests on this conn. Phase 3a
    %% always exits after one request; 3c will loop here on keep-alive
    %% and bump this counter to enforce `max_keep_alive_request`.
    requests_served = 0 :: non_neg_integer(),
    %% Bytes received but not yet parsed. Empty on first iteration;
    %% populated mid-recv when `parse_request/1` returns `{more, _}`.
    %% Phase 3c will also use this for pipelined leftovers.
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
read_request_phase(#loop_state{listener_name = ListenerName} = S) ->
    proc_lib:set_label({roadrunner_conn, reading_request, ListenerName}),
    Timeout = maps:get(request_timeout, S#loop_state.proto_opts),
    %% Compute an *absolute* deadline once. Each iteration's `after`
    %% clause decays it — `recv_request_bytes/2` recomputes
    %% `Deadline - now` so a slow client that drips bytes can NOT keep
    %% extending the receive's timeout. Mirrors gen_statem's one-shot
    %% `state_timeout` semantics in a hand-rolled receive.
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    arm_active_once(S),
    recv_request_bytes(S, Deadline).

-spec recv_request_bytes(#loop_state{}, integer()) -> no_return().
recv_request_bytes(
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
            recv_request_bytes(S, Deadline)
    after Remaining ->
        %% Slowloris / first-request silence. Phase 2 only sees `first`
        %% requests (no keep-alive yet) so we always send a 408.
        _ = roadrunner_conn:send_request_timeout(Socket),
        exit_normal(S)
    end.

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
        proto_opts = ProtoOpts,
        listener_name = ListenerName
    } = S,
    Req,
    Deadline
) ->
    proc_lib:set_label({roadrunner_conn, reading_body, ListenerName}),
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
        proto_opts = ProtoOpts,
        listener_name = ListenerName
    } = S,
    Req
) ->
    proc_lib:set_label({roadrunner_conn, dispatching, ListenerName}),
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
    HandlerFun = fun(R) -> Handler:handle(R) end,
    Pipeline = roadrunner_middleware:compose(ListenerMws ++ RouteMws, HandlerFun),
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

%% Phase 3a: buffered (3-tuple) only. Phase 3b adds stream/loop/
%% sendfile/websocket. Anything else crashes loud — the handler
%% behaviour spec rules out other shapes, so a crash is the right
%% signal that someone's returning an undocumented response.
-spec dispatch_response(
    roadrunner_transport:socket(),
    module(),
    roadrunner_http1:request(),
    roadrunner_handler:response()
) -> ok.
dispatch_response(Socket, _Handler, Req, {Status, Headers, Body}) when is_integer(Status) ->
    RespBody = roadrunner_conn:response_body_for(Req, Body),
    Resp = roadrunner_http1:response(Status, Headers, RespBody),
    _ = roadrunner_telemetry:response_send(
        roadrunner_transport:send(Socket, Resp), buffered_response
    ),
    ok.

%% --- finishing phase ---
%%
%% Phase 3a: drain unread manual-mode body bytes (auto mode already
%% read everything, so this is a no-op there) and exit. Phase 3c
%% will use this point to decide keep-alive vs close and loop back
%% into `read_request_phase`.
-spec finishing_phase(#loop_state{}, roadrunner_http1:request(), roadrunner_handler:response()) ->
    no_return().
finishing_phase(#loop_state{listener_name = ListenerName} = S, Req, _Response) ->
    proc_lib:set_label({roadrunner_conn, finishing, ListenerName}),
    _ = roadrunner_conn:drain_body(Req),
    exit_normal(S).

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
