-module(roadrunner_http2_stream_worker).
-moduledoc false.

%% Per-stream worker process for HTTP/2 dispatch (Phase H8b).
%%
%% Spawned by `roadrunner_conn_loop_http2` once a request stream
%% finishes receiving (HEADERS + body + END_STREAM). The worker:
%%
%% 1. Resolves the route + middleware stack.
%% 2. Calls the handler.
%% 3. Translates the response shape (`{Status, Headers, Body}` or
%%    `{stream, _, _, Fun}`) into messages back to the conn process,
%%    which is the single owner of HPACK encoder state and frame I/O.
%%
%% Worker → conn protocol (synchronous round-trip per write so the
%% worker doesn't outpace flow control or the wire):
%%
%% ```
%% Worker → Conn: {h2_send_headers, Worker, Ref, StreamId, Status, Headers, EndStream}
%% Conn   → Worker: {h2_send_ack, Ref}                       %% frame written
%%
%% Worker → Conn: {h2_send_data, Worker, Ref, StreamId, Data, EndStream}
%% Conn   → Worker: {h2_send_ack, Ref}                       %% frame written
%%                   %% (delayed if the conn or stream send window was
%%                   %% closed — drained on the next WINDOW_UPDATE)
%%
%% Worker → Conn: {h2_send_trailers, Worker, Ref, StreamId, Trailers}
%% Conn   → Worker: {h2_send_ack, Ref}
%% ```
%%
%% The worker has no explicit "done" message: it is spawn_monitored, so
%% the conn finalises the stream on the worker's `DOWN`.
%%
%% If the peer cancels the stream (`RST_STREAM` or worker-level error
%% on the conn side), the conn sends `{h2_stream_reset, StreamId}` —
%% the worker observes this on its next sync round and exits without
%% emitting further frames.
%%
%% Crash isolation: workers are spawn_monitored (NOT linked) so a
%% handler crash resets only the affected stream — the conn
%% observes the `'DOWN'` and emits
%% `RST_STREAM(INTERNAL_ERROR)`, leaving in-flight peers untouched.

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
-spec start(pid(), pos_integer(), roadrunner_req:request(), map()) ->
    {pid(), reference()}.
start(ConnPid, StreamId, Req, ProtoOpts) ->
    #{handler_spawn_opts := SpawnOpts} = ProtoOpts,
    spawn_opt(?MODULE, init, [ConnPid, StreamId, Req, ProtoOpts], [monitor | SpawnOpts]).

-doc false.
-spec init(pid(), pos_integer(), roadrunner_req:request(), map()) -> ok.
init(ConnPid, StreamId, Req, ProtoOpts) ->
    proc_lib:set_label({roadrunner_http2_stream_worker, StreamId}),
    %% Mirror the h1 path: attach request-scoped metadata so any
    %% `?LOG_*` from middleware/handlers is auto-correlated by
    %% `request_id`. The conn process can't do this for us — the
    %% handler runs in this worker, not on the conn.
    ok = roadrunner_conn:set_request_logger_metadata(Req),
    run_handler(ConnPid, StreamId, Req, ProtoOpts),
    %% No explicit completion message: the worker is spawn_monitored by
    %% the conn, which finalises the stream on the worker's `DOWN`
    %% (`normal` -> clean removal, anything else -> RST_STREAM).
    ok.

run_handler(ConnPid, StreamId, Req, ProtoOpts) ->
    %% `dispatch` is set by listener init and always present. The
    %% matched route's `Pipeline` is a pre-composed `next()` fun
    %% (listener mws ++ per-route mws, with `state` injected up front
    %% if attached, ending in `fun Handler:handle/1`), built once at
    %% compile / `reload_routes/2` time — we just call it with the
    %% request, no per-request closure allocation.
    #{dispatch := Dispatch} = ProtoOpts,
    Metadata = telemetry_metadata(Req),
    ReqStart = roadrunner_telemetry:request_start(Metadata),
    case roadrunner_conn:resolve_handler(Dispatch, Req) of
        {ok, Handler, Bindings, Pipeline, _State} ->
            invoke(
                ConnPid,
                StreamId,
                Handler,
                Pipeline,
                Req#{bindings => Bindings},
                Metadata,
                ReqStart
            );
        not_found ->
            send_buffered(
                ConnPid, StreamId, 404, [{~"content-type", ~"text/plain"}], ~"Not Found"
            ),
            ok = roadrunner_telemetry:request_stop(ReqStart, Metadata, #{
                status => 404, response_kind => buffered
            })
    end.

invoke(ConnPid, StreamId, Handler, Pipeline, #{method := Method} = Req, Metadata, ReqStart) ->
    try Pipeline(Req) of
        {Response, _Req2} ->
            %% RFC 9110 §9.3.2: a HEAD response carries no content; emit
            %% the body-stripped form but report the handler's original
            %% shape / status to telemetry.
            emit_handler_response(
                ConnPid, StreamId, Handler, roadrunner_conn:head_response(Response, Method)
            ),
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

-spec telemetry_metadata(roadrunner_req:request()) -> roadrunner_telemetry:metadata().
telemetry_metadata(#{
    request_id := RequestId,
    peer := Peer,
    method := Method,
    target := Target,
    scheme := Scheme,
    listener_name := ListenerName
}) ->
    %% All five required keys are populated by
    %% `roadrunner_http2_request:build/6`; pattern-match destructure
    %% replaces the prior 6 `maps:get/2,3` calls per request.
    #{
        request_id => RequestId,
        peer => Peer,
        method => Method,
        path => Target,
        scheme => Scheme,
        listener_name => ListenerName
    }.

emit_handler_response(ConnPid, StreamId, _Handler, {Status, Headers, Body}) when
    is_integer(Status), Status >= 100, Status =< 599
->
    send_buffered(ConnPid, StreamId, Status, Headers, Body);
emit_handler_response(ConnPid, StreamId, _Handler, {stream, Status, Headers, Fun}) when
    is_integer(Status), Status >= 100, Status =< 599, is_function(Fun, 1)
->
    roadrunner_http2_stream_response:run(ConnPid, StreamId, Status, Headers, Fun);
emit_handler_response(ConnPid, StreamId, Handler, {loop, Status, Headers, State}) when
    is_integer(Status), Status >= 100, Status =< 599
->
    %% Mirrors h1's `{loop, _}` path: enter a selective-receive loop
    %% in the worker (sharing the handler's mailbox), dispatch each
    %% non-OTP message through `Handler:handle_info/3`, emit DATA
    %% frames via Push. On `{stop, _}` the worker emits an empty
    %% DATA + END_STREAM and exits.
    roadrunner_http2_loop_response:run(
        ConnPid, StreamId, Status, Headers, {Handler, State}
    );
emit_handler_response(
    ConnPid, StreamId, _Handler, {sendfile, Status, Headers, {File, Offset, Length}}
) when is_integer(Status), Status >= 100, Status =< 599 ->
    %% h2 has no kernel sendfile path. Wrap the file-read loop in a
    %% stream_fun so the existing streaming machinery handles
    %% HEADERS, DATA framing, MAX_FRAME_SIZE chunking, and per-stream
    %% / conn-level flow control. File-open failures crash the worker;
    %% the conn process RST_STREAM-s the stream, matching h1.
    Fun = fun(Send) ->
        {ok, IoDev} = file:open(File, [read, raw, binary]),
        try
            {ok, _} = file:position(IoDev, Offset),
            sendfile_loop(IoDev, Length, Send)
        after
            _ = file:close(IoDev)
        end
    end,
    roadrunner_http2_stream_response:run(ConnPid, StreamId, Status, Headers, Fun);
emit_handler_response(ConnPid, StreamId, _Handler, {websocket, _, _}) ->
    emit_501(ConnPid, StreamId).

%% File-read block per worker->conn round-trip. Decoupled from the
%% wire frame size: the conn (`send_data_chunks/8`) splits each block
%% into ?MAX_FRAME_SIZE (16384) DATA frames and emits them in one
%% transport send, so a larger read here means fewer worker->conn
%% round-trips and fewer ssl:send calls, with byte-identical wire
%% output. Kept to 4 frames' worth (≈ the default 65535 send window)
%% so the conn rarely buffers a remainder in its pending-send queue;
%% reading much past the window would just grow that per-stream buffer
%% without sending more per round-trip (the window caps each send).
-define(SENDFILE_READ_BLOCK, 4 * 16384).

sendfile_loop(_IoDev, 0, Send) ->
    Send(<<>>, fin);
sendfile_loop(IoDev, Remaining, Send) ->
    Want = min(Remaining, ?SENDFILE_READ_BLOCK),
    {ok, Bin} = file:read(IoDev, Want),
    case Remaining - byte_size(Bin) of
        0 ->
            Send(Bin, fin);
        NextRemaining ->
            Send(Bin, nofin),
            sendfile_loop(IoDev, NextRemaining, Send)
    end.

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
    sync(fun(Ref) ->
        _ = (ConnPid ! {h2_send_response, self(), Ref, StreamId, Status, Headers, Body}),
        ok
    end).

sync(SendFun) ->
    Ref = make_ref(),
    ok = SendFun(Ref),
    receive
        {h2_send_ack, Ref} -> ok;
        {h2_stream_reset, _StreamId} -> exit(stream_reset)
    end.
