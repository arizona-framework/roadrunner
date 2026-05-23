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

-export([start/4]).
-export([init/4]).
%% Exported for `roadrunner_conn_loop_http3` to emit a buffered
%% response (e.g. 413) directly, without spawning a worker.
-export([send_buffered/5]).

%% RFC 9114 §7.2.1: the DATA frame type is 0x00. We frame the body by
%% hand (type + length varints, then the body by reference) instead of
%% `quic_h3_frame:encode_data/1` so a large body is never flattened
%% into one binary on the response path.
-define(H3_FRAME_DATA, 16#00).

-doc """
Spawn a monitored worker for `StreamId`. Returns `{Pid, MonitorRef}`
so the conn loop can correlate the eventual `'DOWN'` back to the
stream id (normal exit → stream done; abnormal → reset the stream).

The conn loop has already QPACK-decoded the field block and built
`Req` (so QPACK-decompression and malformed-message errors are raised
at the connection / stream level, not by crashing this worker).
""".
-spec start(pid(), non_neg_integer(), roadrunner_req:request(), map()) ->
    {pid(), reference()}.
start(Conn, StreamId, Req, ProtoOpts) ->
    spawn_monitor(?MODULE, init, [Conn, StreamId, Req, ProtoOpts]).

-doc false.
-spec init(pid(), non_neg_integer(), roadrunner_req:request(), map()) -> ok.
init(Conn, StreamId, Req, ProtoOpts) ->
    proc_lib:set_label({roadrunner_http3_stream_worker, StreamId}),
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
            %% `emit_handler_response/3` returns the status actually sent
            %% (which differs from the handler's when we override a bad
            %% response with 500 / 501) so telemetry reports the truth.
            %% It runs in the `of` body, whose exceptions a `try` does
            %% NOT catch — so it must not raise; it sends the response.
            Status = emit_handler_response(Conn, StreamId, Response),
            ok = roadrunner_telemetry:request_stop(ReqStart, Metadata, #{
                status => Status,
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

-spec emit_handler_response(pid(), non_neg_integer(), roadrunner_handler:response()) ->
    roadrunner_http:status().
emit_handler_response(Conn, StreamId, {Status, Headers, Body}) when
    is_integer(Status, 100, 599)
->
    case forbidden_header(Headers) of
        {true, Name} ->
            %% RFC 9114 §4.2: connection-specific header fields MUST NOT
            %% be generated. A handler emitting one (e.g. a shared h1/h2
            %% handler with `connection: close`) is a server bug, not a
            %% received malformed message — answer 500 rather than write
            %% a response the client rejects.
            logger:error(#{
                msg => "roadrunner h3 handler returned a connection-specific header",
                header => Name
            }),
            send_buffered(
                Conn, StreamId, 500, [{~"content-type", ~"text/plain"}], ~"Internal Server Error"
            ),
            500;
        false ->
            send_buffered(Conn, StreamId, Status, Headers, Body),
            Status
    end;
emit_handler_response(Conn, StreamId, {stream, _, _, _}) ->
    emit_501(Conn, StreamId);
emit_handler_response(Conn, StreamId, {loop, _, _, _}) ->
    emit_501(Conn, StreamId);
emit_handler_response(Conn, StreamId, {sendfile, _, _, _}) ->
    emit_501(Conn, StreamId);
emit_handler_response(Conn, StreamId, {websocket, _, _}) ->
    emit_501(Conn, StreamId).

%% RFC 9114 §4.2 connection-specific header set. Function-clause
%% dispatch (mirrors `roadrunner_http3_request:check_banned/1`) keeps it
%% branch-friendly; returns the offending name for the log.
-spec forbidden_header(roadrunner_http:headers()) -> {true, binary()} | false.
forbidden_header([]) ->
    false;
forbidden_header([{Name, _} | Rest]) ->
    case is_forbidden_header(Name) of
        true -> {true, Name};
        false -> forbidden_header(Rest)
    end.

-spec is_forbidden_header(binary()) -> boolean().
is_forbidden_header(~"connection") -> true;
is_forbidden_header(~"keep-alive") -> true;
is_forbidden_header(~"proxy-connection") -> true;
is_forbidden_header(~"transfer-encoding") -> true;
is_forbidden_header(~"upgrade") -> true;
is_forbidden_header(_) -> false.

%% Stream / loop / sendfile / websocket response shapes are phase-2 for
%% HTTP/3; until then they answer 501 (mirroring how h2 answers 501 for
%% the WebSocket shape).
-spec emit_501(pid(), non_neg_integer()) -> 501.
emit_501(Conn, StreamId) ->
    send_buffered(
        Conn,
        StreamId,
        501,
        [{~"content-type", ~"text/plain"}],
        ~"HTTP/3 does not yet support this response shape"
    ),
    501.

%% Encode the response as a HEADERS frame (QPACK-encoded `:status` +
%% the handler's headers) followed by a single DATA frame, and write
%% both in one `quic:send_data/4` with the stream's FIN. A header-only
%% response (empty body) sends just the HEADERS frame with FIN.
-spec send_buffered(
    pid(), non_neg_integer(), roadrunner_http:status(), roadrunner_http:headers(), iodata()
) ->
    ok.
send_buffered(Conn, StreamId, Status, Headers, Body) ->
    HeaderList = [{~":status", integer_to_binary(Status)} | roadrunner_http:with_date(Headers)],
    HeadersFrame = quic_h3_frame:encode_headers(quic_qpack:encode(HeaderList)),
    Frames =
        case iolist_size(Body) of
            0 ->
                HeadersFrame;
            BodyLen ->
                %% DATA frame as iodata: type + length varints, then the
                %% body by reference (no flatten). `quic:send_data/4`
                %% takes iodata and the transport `writev()`s it.
                DataHeader = [quic_varint:encode(?H3_FRAME_DATA), quic_varint:encode(BodyLen)],
                [HeadersFrame, DataHeader, Body]
        end,
    ok = quic:send_data(Conn, StreamId, Frames, true).
