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

%% Worker process-dict flag: set once a `{stream, ...}` `Send` observed
%% a fin variant, so `send_stream/5` knows whether to auto-close. Lives
%% in this per-stream worker's dict, so stream isolation is automatic.
-define(FIN_KEY, '$roadrunner_http3_stream_fin').

%% File-read granularity for the sendfile path. QUIC has no small frame
%% cap (unlike h2's 16 KB DATA frames), so this is just a bounded read
%% buffer that keeps the whole file off the heap.
-define(SENDFILE_CHUNK_SIZE, 65536).

-doc """
Spawn a monitored worker for `StreamId`. Returns `{Pid, MonitorRef}`
so the conn loop can correlate the eventual `'DOWN'` back to the
stream id (normal exit → stream done; abnormal → reset the stream).

The conn loop has already QPACK-decoded the field block and built
`Req` (so QPACK-decompression and malformed-message errors are raised
at the connection / stream level, not by crashing this worker).
""".
-spec start(pid(), non_neg_integer(), roadrunner_req:request(), roadrunner_conn:proto_opts()) ->
    {pid(), reference()}.
start(Conn, StreamId, Req, ProtoOpts) ->
    #{handler_spawn_opts := SpawnOpts} = ProtoOpts,
    spawn_opt(?MODULE, init, [Conn, StreamId, Req, ProtoOpts], [monitor | SpawnOpts]).

-doc false.
-spec init(pid(), non_neg_integer(), roadrunner_req:request(), roadrunner_conn:proto_opts()) -> ok.
init(Conn, StreamId, Req, ProtoOpts) ->
    proc_lib:set_label({roadrunner_http3_stream_worker, StreamId}),
    %% Attach request-scoped logger metadata so any `?LOG_*` from
    %% middleware/handlers is auto-correlated by `request_id` — the
    %% handler runs in this worker, not on the conn loop.
    ok = roadrunner_conn:set_request_logger_metadata(Req),
    run_handler(Conn, StreamId, Req, ProtoOpts),
    ok.

-spec run_handler(pid(), non_neg_integer(), roadrunner_req:request(), roadrunner_conn:proto_opts()) ->
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
            ok = roadrunner_telemetry:request_stop(ReqStart, Metadata, 404, buffered)
    end.

-spec invoke(
    pid(),
    non_neg_integer(),
    module(),
    roadrunner_middleware:next(),
    roadrunner_req:request(),
    roadrunner_telemetry:metadata(),
    integer()
) -> ok.
invoke(Conn, StreamId, Handler, Pipeline, #{method := Method} = Req, Metadata, ReqStart) ->
    try Pipeline(Req) of
        {Response, _Req2} ->
            %% `emit_handler_response/4` returns the status actually sent
            %% (which differs from the handler's when we override a bad
            %% response with 500 / 501) so telemetry reports the truth.
            %% It runs in the `of` body, whose exceptions a `try` does
            %% NOT catch — so it must not raise; it sends the response.
            %% RFC 9110 §9.3.2: a HEAD response carries no content, so
            %% emit the body-stripped form; telemetry keeps the handler's
            %% original shape (`response_kind/1` below).
            Status = emit_handler_response(
                Conn, StreamId, Handler, roadrunner_conn:head_response(Response, Method)
            ),
            ok = roadrunner_telemetry:request_stop(
                ReqStart, Metadata, Status, roadrunner_conn:response_kind(Response)
            )
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

-spec emit_handler_response(pid(), non_neg_integer(), module(), roadrunner_handler:response()) ->
    roadrunner_http:status().
emit_handler_response(Conn, StreamId, _Handler, {Status, Headers, Body}) when
    is_integer(Status), Status >= 100, Status =< 599
->
    emit_checked(Conn, StreamId, Headers, fun() ->
        send_buffered(Conn, StreamId, Status, Headers, Body),
        Status
    end);
emit_handler_response(Conn, StreamId, _Handler, {stream, Status, Headers, Fun}) ->
    emit_checked(Conn, StreamId, Headers, fun() ->
        send_stream(Conn, StreamId, Status, Headers, Fun),
        Status
    end);
emit_handler_response(Conn, StreamId, _Handler, {sendfile, Status, Headers, Spec}) ->
    emit_checked(Conn, StreamId, Headers, fun() ->
        send_sendfile(Conn, StreamId, Status, Headers, Spec),
        Status
    end);
emit_handler_response(Conn, StreamId, Handler, {loop, Status, Headers, State}) ->
    emit_checked(Conn, StreamId, Headers, fun() ->
        send_loop(Conn, StreamId, Status, Headers, Handler, State),
        Status
    end);
emit_handler_response(Conn, StreamId, _Handler, {websocket, _, _}) ->
    emit_501(Conn, StreamId).

%% Emit a response unless it carries a connection-specific header
%% (RFC 9114 §4.2), in which case answer 500. `Emit` performs the send
%% and returns the status sent; shared by the buffered / stream /
%% sendfile paths.
-spec emit_checked(
    pid(), non_neg_integer(), roadrunner_http:headers(), fun(() -> roadrunner_http:status())
) -> roadrunner_http:status().
emit_checked(Conn, StreamId, Headers, Emit) ->
    case forbidden_header(Headers) of
        {true, Name} -> reject_forbidden(Conn, StreamId, Name);
        false -> Emit()
    end.

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

%% RFC 9114 §4.2: connection-specific header fields MUST NOT be
%% generated. A handler emitting one (e.g. a shared h1/h2 handler with
%% `connection: close`) is a server bug, not a received malformed
%% message — answer 500 rather than write a response the client rejects.
%% Shared by the buffered and streaming response paths.
-spec reject_forbidden(pid(), non_neg_integer(), binary()) -> 500.
reject_forbidden(Conn, StreamId, Name) ->
    logger:error(#{
        msg => "roadrunner h3 handler returned a connection-specific header",
        header => Name
    }),
    send_buffered(
        Conn, StreamId, 500, [{~"content-type", ~"text/plain"}], ~"Internal Server Error"
    ),
    500.

%% The `websocket` response shape is not yet wired for HTTP/3 (it needs
%% Extended CONNECT, RFC 9220); until then it answers 501, mirroring how
%% h2 answers 501 for it. The buffered / stream / sendfile / loop shapes
%% are supported.
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
    HeadersFrame = header_frame(Status, Headers),
    Frames =
        case iolist_size(Body) of
            0 -> HeadersFrame;
            BodyLen -> [HeadersFrame, data_frame(Body, BodyLen)]
        end,
    %% Fire-and-forget: if the peer closed between its request and our
    %% response, the connection is draining and the send returns an error.
    %% That is fine, the worker exits and the conn loop cleans up the stream
    %% (same rationale as the control-stream and GOAWAY sends).
    _ = quic:send_data(Conn, StreamId, Frames, true),
    ok.

%% `{stream, ...}` response: HEADERS (no FIN), then the handler's fun
%% emits DATA chunks through a `Send/2` callback, then the stream FIN.
%% `Send(Data, nofin | fin | {fin, Trailers})` is the protocol-agnostic
%% contract shared with h1/h2 (see `roadrunner_stream_response` /
%% `roadrunner_http2_stream_response`); if the fun returns without a
%% fin variant we close the stream so the peer never sees it half-open.
%% The worker writes straight to the QUIC stream — QPACK is static-only
%% and QUIC streams are independent, so no conn round-trip (unlike h2).
-spec send_stream(
    pid(),
    non_neg_integer(),
    roadrunner_http:status(),
    roadrunner_http:headers(),
    roadrunner_handler:stream_fun()
) -> ok.
send_stream(Conn, StreamId, Status, Headers, Fun) ->
    _ = quic:send_data(Conn, StreamId, header_frame(Status, Headers), false),
    erase(?FIN_KEY),
    Send = fun(Data, FinFlag) -> stream_send(Conn, StreamId, Data, FinFlag) end,
    _ = Fun(Send),
    erase(?FIN_KEY) =:= true orelse stream_send(Conn, StreamId, <<>>, fin),
    ok.

%% One `Send/2` emission. Empty `nofin` data is a no-op (matches the
%% h1/h2 contract); `fin` / `{fin, Trailers}` carry the stream FIN, the
%% trailers riding a closing HEADERS frame after the DATA (RFC 9114 §4.1).
-spec stream_send(
    pid(), non_neg_integer(), iodata(), nofin | fin | {fin, roadrunner_http:headers()}
) -> ok | {error, term()}.
stream_send(Conn, StreamId, Data, nofin) ->
    case iolist_size(Data) of
        0 -> ok;
        Len -> quic:send_data(Conn, StreamId, data_frame(Data, Len), false)
    end;
stream_send(Conn, StreamId, Data, fin) ->
    put(?FIN_KEY, true),
    quic:send_data(Conn, StreamId, data_frame(Data, iolist_size(Data)), true);
stream_send(Conn, StreamId, Data, {fin, Trailers}) ->
    put(?FIN_KEY, true),
    TrailersFrame = quic_h3_frame:encode_headers(quic_qpack:encode(Trailers)),
    quic:send_data(Conn, StreamId, [data_frame(Data, iolist_size(Data)), TrailersFrame], true).

%% `{sendfile, ...}` response. There is no kernel sendfile over QUIC
%% (the stream bytes are encrypted), so read the file in chunks and feed
%% the streaming machinery, mirroring the h2 sendfile path. A file-open
%% failure crashes the worker; the conn loop resets the stream.
-spec send_sendfile(
    pid(),
    non_neg_integer(),
    roadrunner_http:status(),
    roadrunner_http:headers(),
    roadrunner_handler:sendfile_spec()
) -> ok.
send_sendfile(Conn, StreamId, Status, Headers, {File, Offset, Length}) ->
    Fun = fun(Send) ->
        {ok, IoDev} = file:open(File, [read, raw, binary]),
        try
            {ok, _} = file:position(IoDev, Offset),
            sendfile_loop(IoDev, Length, Send)
        after
            _ = file:close(IoDev)
        end
    end,
    send_stream(Conn, StreamId, Status, Headers, Fun).

%% Stream `Length` bytes from the open file as DATA chunks, FIN on the
%% last (or an immediate empty FIN for a zero-length range).
-spec sendfile_loop(file:io_device(), non_neg_integer(), roadrunner_handler:send_fun()) -> ok.
sendfile_loop(_IoDev, 0, Send) ->
    _ = Send(<<>>, fin),
    ok;
sendfile_loop(IoDev, Remaining, Send) ->
    {ok, Bin} = file:read(IoDev, min(Remaining, ?SENDFILE_CHUNK_SIZE)),
    case Remaining - byte_size(Bin) of
        0 ->
            _ = Send(Bin, fin),
            ok;
        NextRemaining ->
            _ = Send(Bin, nofin),
            sendfile_loop(IoDev, NextRemaining, Send)
    end.

%% `{loop, ...}` response: HEADERS (no FIN), then a message-receive loop
%% dispatching each non-OTP message through the handler's
%% `handle_info/3` with a `Push` callback that emits a DATA frame; FIN
%% on `{stop, _}`. Runs in the per-stream worker, so a handler's
%% `self() ! Msg` / `register/2` from `handle/1` works (the worker IS
%% the dispatch process). Mirrors `roadrunner_http2_loop_response`.
-spec send_loop(
    pid(),
    non_neg_integer(),
    roadrunner_http:status(),
    roadrunner_http:headers(),
    module(),
    term()
) -> ok.
send_loop(Conn, StreamId, Status, Headers, Handler, State) ->
    _ = quic:send_data(Conn, StreamId, header_frame(Status, Headers), false),
    %% Stop looping if the connection dies — otherwise an idle loop
    %% worker (blocked in `info_loop` waiting for a message) leaks
    %% forever once the conn is gone. The monitor fires when the QUIC
    %% connection process exits (promptly on a force-close / abort, or
    %% after its drain timeout on a graceful close).
    _ = monitor(process, Conn),
    Push = fun(Data) -> loop_push(Conn, StreamId, Data) end,
    info_loop(Conn, StreamId, Handler, Push, State).

%% OTP message shapes are answered via `roadrunner_loop_sys` rather than
%% surfacing in `handle_info/3`: `sys:get_state/1` & friends work and a
%% `gen_server:call/2,3` against the worker gets `{error, not_supported}`
%% instead of hanging (see `roadrunner_loop_response` for the full
%% contract); any other message is the handler's.
-spec info_loop(pid(), non_neg_integer(), module(), roadrunner_handler:push_fun(), term()) -> ok.
info_loop(Conn, StreamId, Handler, Push, State) ->
    receive
        {'DOWN', _MonRef, process, Conn, _Reason} ->
            %% Connection gone — stop looping.
            ok;
        {system, From, Req} ->
            Resume = fun(S) -> info_loop(Conn, StreamId, Handler, Push, S) end,
            roadrunner_loop_sys:handle_system(Req, From, State, Resume);
        {'$gen_call', From, _} ->
            ok = roadrunner_loop_sys:gen_call_unsupported(From),
            info_loop(Conn, StreamId, Handler, Push, State);
        {'$gen_cast', _} ->
            info_loop(Conn, StreamId, Handler, Push, State);
        Info ->
            case Handler:handle_info(Info, Push, State) of
                {ok, NewState} ->
                    info_loop(Conn, StreamId, Handler, Push, NewState);
                {stop, _NewState} ->
                    %% Close the stream with an empty DATA frame + FIN.
                    _ = quic:send_data(Conn, StreamId, data_frame(<<>>, 0), true),
                    ok
            end
    end.

%% Push handed to the loop handler: empty data is a no-op (matches the
%% h1/h2 contract), non-empty ships as one DATA frame (no FIN).
-spec loop_push(pid(), non_neg_integer(), iodata()) -> ok | {error, term()}.
loop_push(Conn, StreamId, Data) ->
    case iolist_size(Data) of
        0 -> ok;
        Len -> quic:send_data(Conn, StreamId, data_frame(Data, Len), false)
    end.

%% HEADERS frame: QPACK-encoded `:status` + the handler's headers, plus
%% the auto-injected `Date` (RFC 9110 §6.6.1).
-spec header_frame(roadrunner_http:status(), roadrunner_http:headers()) -> binary().
header_frame(Status, Headers) ->
    HeaderList = [{~":status", integer_to_binary(Status)} | roadrunner_http:with_date(Headers)],
    quic_h3_frame:encode_headers(quic_qpack:encode(HeaderList)).

%% DATA frame as iodata (type + length varints, then the body by
%% reference) so a large body is never flattened. `Len` is the caller's
%% already-computed `iolist_size(Body)`.
-spec data_frame(iodata(), non_neg_integer()) -> iodata().
data_frame(Body, Len) ->
    [quic_varint:encode(?H3_FRAME_DATA), quic_varint:encode(Len), Body].
