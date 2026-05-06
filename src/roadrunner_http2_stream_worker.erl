-module(roadrunner_http2_stream_worker).
-moduledoc """
Per-stream worker process for HTTP/2 dispatch (Phase H8b).

Spawned by `roadrunner_conn_loop_http2` once a request stream
finishes receiving (HEADERS + body + END_STREAM). The worker:

1. Resolves the route + middleware stack.
2. Calls the handler.
3. Translates the response shape (`{Status, Headers, Body}` or
   `{stream, _, _, Fun}`) into messages back to the conn process,
   which is the single owner of HPACK encoder state and frame I/O.

Worker → conn protocol (synchronous round-trip per write so the
worker doesn't outpace flow control or the wire):

```
Worker → Conn: {h2_send_headers, Worker, Ref, StreamId, Status, Headers, EndStream}
Conn   → Worker: {h2_send_ack, Ref}                       %% frame written

Worker → Conn: {h2_send_data, Worker, Ref, StreamId, Data, EndStream}
Conn   → Worker: {h2_send_ack, Ref}                       %% frame written
                  %% (delayed if the conn or stream send window was
                  %% closed — drained on the next WINDOW_UPDATE)

Worker → Conn: {h2_send_trailers, Worker, Ref, StreamId, Trailers}
Conn   → Worker: {h2_send_ack, Ref}

Worker → Conn: {h2_worker_done, StreamId}                 %% normal exit
```

If the peer cancels the stream (`RST_STREAM` or worker-level error
on the conn side), the conn sends `{h2_stream_reset, StreamId}` —
the worker observes this on its next sync round and exits without
emitting further frames.

Crash isolation: workers are spawn_monitored (NOT linked) so a
handler crash resets only the affected stream — the conn
observes the `'DOWN'` and emits
`RST_STREAM(INTERNAL_ERROR)`, leaving in-flight peers untouched.
""".

-export([start/4]).
-export([init/4]).

-doc """
Spawn a new worker for `StreamId`, monitored by the calling conn
process. The worker runs `Req` through the dispatch pipeline and
emits frame messages back to the conn. Returns the
`{Pid, MonitorRef}` so the conn can correlate the eventual `'DOWN'`
back to the stream id.

Workers are NOT linked: a handler crash should reset just the
affected stream, not tear down the whole connection. The conn
sees the `'DOWN'` and emits `RST_STREAM(INTERNAL_ERROR)` for the
stream's id, leaving the other 99 streams intact.
""".
-spec start(pid(), pos_integer(), roadrunner_http1:request(), map()) ->
    {pid(), reference()}.
start(ConnPid, StreamId, Req, ProtoOpts) ->
    spawn_monitor(?MODULE, init, [ConnPid, StreamId, Req, ProtoOpts]).

-doc false.
-spec init(pid(), pos_integer(), roadrunner_http1:request(), map()) -> ok.
init(ConnPid, StreamId, Req, ProtoOpts) ->
    proc_lib:set_label({roadrunner_http2_stream_worker, StreamId}),
    %% Mirror the h1 path: attach request-scoped metadata so any
    %% `?LOG_*` from middleware/handlers is auto-correlated by
    %% `request_id`. The conn process can't do this for us — the
    %% handler runs in this worker, not on the conn.
    ok = roadrunner_conn:set_request_logger_metadata(Req),
    run_handler(ConnPid, StreamId, Req, ProtoOpts),
    ConnPid ! {h2_worker_done, StreamId},
    ok.

run_handler(ConnPid, StreamId, Req, ProtoOpts) ->
    %% Destructure once — `proto_opts` always carries `dispatch`
    %% (set by listener init); `middlewares` is also always set,
    %% defaulting to `[]`, so a strict map-pattern is correct here.
    #{dispatch := Dispatch, middlewares := Mws} = ProtoOpts,
    Metadata = telemetry_metadata(Req),
    ReqStart = roadrunner_telemetry:request_start(Metadata),
    case roadrunner_conn:resolve_handler(Dispatch, Req) of
        {ok, Handler, Bindings, RouteOpts} ->
            FullReq = Req#{bindings => Bindings, route_opts => RouteOpts},
            invoke(ConnPid, StreamId, Handler, Mws, FullReq, Metadata, ReqStart);
        not_found ->
            send_buffered(
                ConnPid, StreamId, 404, [{~"content-type", ~"text/plain"}], ~"Not Found"
            ),
            ok = roadrunner_telemetry:request_stop(ReqStart, Metadata, #{
                status => 404, response_kind => buffered
            })
    end.

invoke(ConnPid, StreamId, Handler, ListenerMws, Req, Metadata, ReqStart) ->
    Pipeline = roadrunner_middleware:build_pipeline(ListenerMws, Req, Handler),
    try Pipeline(Req) of
        {Response, _Req2} ->
            emit_handler_response(ConnPid, StreamId, Response),
            ok = roadrunner_telemetry:request_stop(ReqStart, Metadata, #{
                status => roadrunner_conn:response_status(Response),
                response_kind => roadrunner_conn:response_kind(Response)
            })
    catch
        Class:Reason:Stack ->
            ok = roadrunner_telemetry:request_exception(
                ReqStart, Metadata, Class, Reason
            ),
            logger:error(#{
                msg => "roadrunner h2 handler crashed",
                handler => Handler,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            send_buffered(
                ConnPid,
                StreamId,
                500,
                [{~"content-type", ~"text/plain"}],
                ~"Internal Server Error"
            )
    end.

-spec telemetry_metadata(roadrunner_http1:request()) -> roadrunner_telemetry:metadata().
telemetry_metadata(#{
    request_id := RequestId,
    peer := Peer,
    method := Method,
    target := Target,
    scheme := Scheme,
    listener_name := ListenerName
}) ->
    %% All five required keys are populated by
    %% `roadrunner_http2_request:build/7`; pattern-match destructure
    %% replaces the prior 6 `maps:get/2,3` calls per request.
    #{
        request_id => RequestId,
        peer => Peer,
        method => Method,
        path => Target,
        scheme => Scheme,
        listener_name => ListenerName
    }.

emit_handler_response(ConnPid, StreamId, {Status, Headers, Body}) when
    is_integer(Status, 100, 599)
->
    send_buffered(ConnPid, StreamId, Status, Headers, Body);
emit_handler_response(ConnPid, StreamId, {stream, Status, Headers, Fun}) when
    is_integer(Status, 100, 599), is_function(Fun, 1)
->
    roadrunner_http2_stream_response:run(ConnPid, StreamId, Status, Headers, Fun);
emit_handler_response(ConnPid, StreamId, {loop, _, _, _}) ->
    emit_501(ConnPid, StreamId);
emit_handler_response(ConnPid, StreamId, {sendfile, _, _, _}) ->
    emit_501(ConnPid, StreamId);
emit_handler_response(ConnPid, StreamId, {websocket, _, _}) ->
    emit_501(ConnPid, StreamId).

emit_501(ConnPid, StreamId) ->
    send_buffered(
        ConnPid,
        StreamId,
        501,
        [{~"content-type", ~"text/plain"}],
        ~"HTTP/2 does not yet support this response shape"
    ).

%% Buffered response: a single conn-side message that emits
%% HEADERS + (optional) DATA in one `ssl:send/2` for the common
%% case where the body fits in a single DATA frame AND the
%% stream's flow-control window. Conn-side handler falls back to
%% the two-step (HEADERS, then queued DATA) path for large bodies
%% or constrained windows; the worker still sees a single sync
%% round-trip in either case.
send_buffered(ConnPid, StreamId, Status, Headers, Body) ->
    Bin = iolist_to_binary(Body),
    sync(ConnPid, fun(Ref) ->
        _ = (ConnPid ! {h2_send_response, self(), Ref, StreamId, Status, Headers, Bin}),
        ok
    end).

sync(_ConnPid, SendFun) ->
    Ref = make_ref(),
    ok = SendFun(Ref),
    receive
        {h2_send_ack, Ref} -> ok;
        {h2_stream_reset, _StreamId} -> exit(stream_reset)
    end.
