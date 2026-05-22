-module(roadrunner_http3_stream_worker).
-moduledoc false.

%% Per-stream worker process for HTTP/3 dispatch — the h3 analogue of
%% `roadrunner_http2_stream_worker`. Spawned by
%% `roadrunner_conn_loop_http3` once a request stream finishes
%% receiving (HEADERS + body + the stream's FIN). The worker:
%%
%% 1. QPACK-decodes the HEADERS field block (stateless, static-table
%%    only — the conn advertises `qpack_max_table_capacity = 0`) and
%%    builds the request map.
%% 2. Resolves the route + middleware stack and calls the handler,
%%    sharing the exact dispatch path h1/h2 use
%%    (`roadrunner_conn:resolve_handler/2` + the pre-composed pipeline).
%% 3. Writes the response straight onto the QUIC stream via
%%    `quic:send_data/4` — QUIC connections are gen_statem-backed, so a
%%    non-owner process can send with the `Conn` handle (no h2-style
%%    conn-mediated send protocol needed).
%%
%% Crash isolation: workers are spawn_monitored (NOT linked) by the
%% conn loop. A handler crash is caught here and turned into a 500; any
%% other failure (QPACK decompression, malformed pseudo-headers,
%% response encoding) crashes the worker, and the conn loop resets the
%% stream on the `'DOWN'` — leaving the connection's other streams
%% untouched.

-export([start/6]).
-export([init/6]).
%% Exported for `roadrunner_conn_loop_http3` to emit a buffered
%% response (e.g. 413) directly, without spawning a worker.
-export([send_buffered/5]).

-doc """
Spawn a monitored worker for `StreamId`. Returns `{Pid, MonitorRef}`
so the conn loop can correlate the eventual `'DOWN'` back to the
stream id (normal exit → stream done; abnormal → reset the stream).
""".
-spec start(pid(), non_neg_integer(), binary(), iodata(), map(), map()) ->
    {pid(), reference()}.
start(Conn, StreamId, HeaderBlock, Body, RequestContext, ProtoOpts) ->
    spawn_monitor(?MODULE, init, [Conn, StreamId, HeaderBlock, Body, RequestContext, ProtoOpts]).

-doc false.
-spec init(pid(), non_neg_integer(), binary(), iodata(), map(), map()) -> ok.
init(Conn, StreamId, HeaderBlock, Body, RequestContext, ProtoOpts) ->
    proc_lib:set_label({roadrunner_http3_stream_worker, StreamId}),
    {ok, Headers} = quic_qpack:decode(HeaderBlock),
    {ok, Req} = roadrunner_http3_request:from_headers(Headers, Body, RequestContext),
    %% Attach request-scoped logger metadata so any `?LOG_*` from
    %% middleware/handlers is auto-correlated by `request_id` — the
    %% handler runs in this worker, not on the conn loop.
    ok = roadrunner_conn:set_request_logger_metadata(Req),
    run_handler(Conn, StreamId, Req, ProtoOpts),
    ok.

run_handler(Conn, StreamId, Req, ProtoOpts) ->
    %% `dispatch` is set by listener init and always present; the
    %% matched route's `Pipeline` is the pre-composed `next()` fun
    %% built once at compile / `reload_routes/2` time.
    #{dispatch := Dispatch} = ProtoOpts,
    Metadata = telemetry_metadata(Req),
    ReqStart = roadrunner_telemetry:request_start(Metadata),
    case roadrunner_conn:resolve_handler(Dispatch, Req) of
        {ok, Handler, Bindings, Pipeline, _State} ->
            invoke(
                Conn, StreamId, Handler, Pipeline, Req#{bindings => Bindings}, Metadata, ReqStart
            );
        not_found ->
            send_buffered(Conn, StreamId, 404, [{~"content-type", ~"text/plain"}], ~"Not Found"),
            ok = roadrunner_telemetry:request_stop(ReqStart, Metadata, #{
                status => 404, response_kind => buffered
            })
    end.

invoke(Conn, StreamId, Handler, Pipeline, Req, Metadata, ReqStart) ->
    try Pipeline(Req) of
        {Response, _Req2} ->
            emit_handler_response(Conn, StreamId, Response),
            ok = roadrunner_telemetry:request_stop(ReqStart, Metadata, #{
                status => roadrunner_conn:response_status(Response),
                response_kind => roadrunner_conn:response_kind(Response)
            })
    catch
        Class:Reason:Stack ->
            ok = roadrunner_telemetry:request_exception(ReqStart, Metadata, Class, Reason),
            logger:error(#{
                msg => "roadrunner h3 handler crashed",
                handler => Handler,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            send_buffered(
                Conn, StreamId, 500, [{~"content-type", ~"text/plain"}], ~"Internal Server Error"
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
    #{
        request_id => RequestId,
        peer => Peer,
        method => Method,
        path => Target,
        scheme => Scheme,
        listener_name => ListenerName
    }.

emit_handler_response(Conn, StreamId, {Status, Headers, Body}) when
    is_integer(Status, 100, 599)
->
    send_buffered(Conn, StreamId, Status, Headers, Body);
emit_handler_response(Conn, StreamId, {stream, Status, _, _}) when
    is_integer(Status, 100, 599)
->
    emit_501(Conn, StreamId);
emit_handler_response(Conn, StreamId, {loop, Status, _, _}) when
    is_integer(Status, 100, 599)
->
    emit_501(Conn, StreamId);
emit_handler_response(Conn, StreamId, {sendfile, Status, _, _}) when
    is_integer(Status, 100, 599)
->
    emit_501(Conn, StreamId);
emit_handler_response(Conn, StreamId, {websocket, _, _}) ->
    emit_501(Conn, StreamId).

%% Stream / loop / sendfile / websocket response shapes are phase-2 for
%% HTTP/3; until then they answer 501 (mirroring how h2 answers 501 for
%% the WebSocket shape).
emit_501(Conn, StreamId) ->
    send_buffered(
        Conn,
        StreamId,
        501,
        [{~"content-type", ~"text/plain"}],
        ~"HTTP/3 does not yet support this response shape"
    ).

%% Encode the response as a HEADERS frame (QPACK-encoded `:status` +
%% the handler's headers) followed by a single DATA frame, and write
%% both in one `quic:send_data/4` with the stream's FIN. A header-only
%% response (empty body) sends just the HEADERS frame with FIN.
-spec send_buffered(
    pid(), non_neg_integer(), roadrunner_http:status(), roadrunner_http:headers(), iodata()
) ->
    ok.
send_buffered(Conn, StreamId, Status, Headers, Body) ->
    HeaderList = [{~":status", integer_to_binary(Status)} | Headers],
    HeadersFrame = quic_h3_frame:encode_headers(quic_qpack:encode(HeaderList)),
    Frames =
        case iolist_size(Body) of
            0 -> HeadersFrame;
            _ -> [HeadersFrame, quic_h3_frame:encode_data(iolist_to_binary(Body))]
        end,
    ok = quic:send_data(Conn, StreamId, Frames, true).
