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
%%    `roadrunner_quic:send_data/4` — a synchronous round-trip to the
%%    connection (make_ref + reply) keyed by the `Conn` handle, so this
%%    non-owner worker gets flow-control back-pressure without a separate
%%    h2-style conn-mediated send module.
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
%% Exported for eunit branch coverage of the stop-on-send-error path.
-export([sendfile_loop/3]).

%% RFC 9114 §7.2.1: the DATA frame type is 0x00. We frame the body by
%% hand (type + length varints, then the body by reference) instead of
%% `roadrunner_quic_h3_frame:encode_data/1` so a large body is never flattened
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
start(Conn, StreamId, Req, #{handler_spawn_opts := SpawnOpts, dispatch := Dispatch}) ->
    spawn_opt(?MODULE, init, [Conn, StreamId, Req, Dispatch], [monitor | SpawnOpts]).

-doc false.
-spec init(pid(), non_neg_integer(), roadrunner_req:request(), roadrunner_conn:dispatch()) -> ok.
init(Conn, StreamId, Req, Dispatch) ->
    proc_lib:set_label({roadrunner_http3_stream_worker, StreamId}),
    %% Attach request-scoped logger metadata so any `?LOG_*` from
    %% middleware/handlers is auto-correlated by `request_id` — the
    %% handler runs in this worker, not on the conn loop.
    ok = roadrunner_conn:set_request_logger_metadata(Req),
    run_handler(Conn, StreamId, Req, Dispatch),
    ok.

-spec run_handler(pid(), non_neg_integer(), roadrunner_req:request(), roadrunner_conn:dispatch()) ->
    ok.
run_handler(Conn, StreamId, Req, Dispatch) ->
    %% `dispatch` is set by listener init and always present; the
    %% matched route's `Pipeline` is the pre-composed `next()` fun
    %% built once at compile / `reload_routes/2` time.
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
    is_integer(Status), Status >= 200, Status =< 599
->
    emit_checked(Conn, StreamId, Headers, fun() ->
        send_buffered(Conn, StreamId, Status, Headers, Body),
        Status
    end);
emit_handler_response(Conn, StreamId, Handler, {Status, _Headers, _Body}) when
    is_integer(Status), Status >= 100, Status =< 199
->
    reject_interim(Conn, StreamId, Handler, Status);
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

%% Emit a response unless it carries a header with CR/LF/NUL (RFC 9110
%% §5.5), in which case answer 500. Connection-specific fields (RFC 9114
%% §4.2) are not rejected here — `header_frame/2` strips them. `Emit`
%% performs the send and returns the status sent; shared by the buffered
%% / stream / sendfile paths.
-spec emit_checked(
    pid(), non_neg_integer(), roadrunner_http:headers(), fun(() -> roadrunner_http:status())
) -> roadrunner_http:status().
emit_checked(Conn, StreamId, Headers, Emit) ->
    case validate_response_headers(Headers) of
        ok -> Emit();
        {unsafe, Kind} -> reject_unsafe(Conn, StreamId, Kind)
    end.

%% One pass over the response headers running the RFC 9110 §5.5 CR/LF/NUL
%% field-byte check (the shared compiled pattern, fetched once), returning
%% the offending kind (never the raw bytes) on the first unsafe field.
%% Non-crashing because `emit_checked/4` runs in the `try ... of` body,
%% whose exceptions the `try` does NOT catch.
-spec validate_response_headers(roadrunner_http:headers()) ->
    ok | {unsafe, name | value}.
validate_response_headers(Headers) ->
    validate_response_headers(Headers, roadrunner_http:unsafe_bytes_pattern()).

-spec validate_response_headers(roadrunner_http:headers(), binary:cp()) ->
    ok | {unsafe, name | value}.
validate_response_headers([], _UnsafeCp) ->
    ok;
validate_response_headers([{Name, Value} | Rest], UnsafeCp) ->
    case binary:match(Name, UnsafeCp) of
        nomatch ->
            case binary:match(Value, UnsafeCp) of
                nomatch -> validate_response_headers(Rest, UnsafeCp);
                _ -> {unsafe, value}
            end;
        _ ->
            {unsafe, name}
    end.

%% RFC 9110 §5.5: a response header name or value containing CR, LF, or
%% NUL is a handler bug (usually unvalidated user input echoed into a
%% header) that would put malformed bytes on the wire, or split at a
%% downstream h3->h1 reverse proxy. Answer 500 rather than emit it; only
%% the kind is logged, never the raw bytes. Shared by every response
%% shape via `emit_checked/4`.
-spec reject_unsafe(pid(), non_neg_integer(), name | value) -> 500.
reject_unsafe(Conn, StreamId, Kind) ->
    logger:error(#{
        msg => "roadrunner h3 handler returned a header with CR/LF/NUL",
        kind => Kind
    }),
    send_buffered(
        Conn, StreamId, 500, [{~"content-type", ~"text/plain"}], ~"Internal Server Error"
    ),
    500.

%% RFC 9110 §15.2: a 1xx is interim and cannot be a final response. The
%% single-response handler API cannot express "interim 1xx then final", so
%% a returned 1xx is always a misuse; answer 500 rather than put an invalid
%% final 1xx on the wire. Legitimate interim 100-continue is handled out of
%% band; this only fires for a handler-returned buffered 1xx.
-spec reject_interim(pid(), non_neg_integer(), module(), 100..199) -> 500.
reject_interim(Conn, StreamId, Handler, Status) ->
    logger:error(#{
        msg => "roadrunner h3 handler returned an interim 1xx status as a final response",
        handler => Handler,
        status => Status
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
%% both in one `roadrunner_quic:send_data/4` with the stream's FIN. A header-only
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
    _ = roadrunner_quic:send_data(Conn, StreamId, Frames, true),
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
    _ = roadrunner_quic:send_data(Conn, StreamId, header_frame(Status, Headers), false),
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
        Len -> roadrunner_quic:send_data(Conn, StreamId, data_frame(Data, Len), false)
    end;
stream_send(Conn, StreamId, Data, fin) ->
    put(?FIN_KEY, true),
    roadrunner_quic:send_data(Conn, StreamId, data_frame(Data, iolist_size(Data)), true);
stream_send(Conn, StreamId, Data, {fin, Trailers}) ->
    %% Trailers go out after the status + body, so an injected one cannot
    %% become a 500. One pass crashes on the RFC 9110 §5.5 check (so the conn
    %% loop resets the stream and the malformed bytes never reach the client,
    %% the same cut-off h1 does for chunked trailers) and strips the
    %% connection-specific fields RFC 9114 §4.2 forbids, matching the header
    %% path. The crash must happen before `?FIN_KEY` is set, so run it first.
    Stripped = roadrunner_http:strip_connection_specific_fields_safe(Trailers),
    put(?FIN_KEY, true),
    TrailersFrame = roadrunner_quic_h3_frame:encode_headers(roadrunner_qpack:encode(Stripped)),
    roadrunner_quic:send_data(
        Conn, StreamId, [data_frame(Data, iolist_size(Data)), TrailersFrame], true
    ).

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
            %% Stop if the chunk could not be sent (the stream was reset /
            %% the conn closed). Continuing would re-`Push` to a gone stream,
            %% which the conn would recreate — read the rest only while the
            %% wire is live.
            case Send(Bin, nofin) of
                ok -> sendfile_loop(IoDev, NextRemaining, Send);
                {error, _} -> ok
            end
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
    _ = roadrunner_quic:send_data(Conn, StreamId, header_frame(Status, Headers), false),
    %% Monitor the conn so an idle loop worker (blocked in `info_loop`)
    %% does not leak once the conn is gone: its `'DOWN'` becomes a
    %% `{roadrunner_disconnect, conn_down}` for the handler. The monitor
    %% fires when the QUIC connection process exits (promptly on a
    %% force-close / abort, or after its drain timeout on a graceful
    %% close).
    _ = monitor(process, Conn),
    Push = fun(Data) -> loop_push(Conn, StreamId, Data) end,
    info_loop(Conn, StreamId, Handler, Push, State).

%% The conn's `'DOWN'` and a peer `{roadrunner_stream_reset, _}` (routed
%% by the conn loop on RESET_STREAM) each deliver one final
%% `{roadrunner_disconnect, _}` to the handler and end the loop. OTP
%% message shapes are answered via `roadrunner_loop_sys` rather than
%% surfacing in `handle_info/3`: `sys:get_state/1` & friends work and a
%% `gen_server:call/2,3` against the worker gets `{error, not_supported}`
%% instead of hanging (see `roadrunner_loop_response` for the full
%% contract); any other message is the handler's.
-spec info_loop(pid(), non_neg_integer(), module(), roadrunner_handler:push_fun(), term()) -> ok.
info_loop(Conn, StreamId, Handler, Push, State) ->
    receive
        {'DOWN', _MonRef, process, Conn, _Reason} ->
            %% Connection gone — give the handler its disconnect and stop.
            deliver_disconnect(Handler, Push, State, conn_down);
        {roadrunner_stream_reset, StreamId} ->
            %% The conn loop routed a peer RESET_STREAM for this stream
            %% (RFC 9114 §4.1). Hand the handler the disconnect and stop;
            %% no FIN frame — the stream is gone.
            deliver_disconnect(Handler, Push, State, reset);
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
                    _ = roadrunner_quic:send_data(Conn, StreamId, data_frame(<<>>, 0), true),
                    ok
            end
    end.

%% Hand the handler one final `{roadrunner_disconnect, Reason}` so it can
%% drop subscriptions / stop work, then end the loop. The stream/conn is
%% gone: we neither emit the FIN frame nor honour the return.
-spec deliver_disconnect(module(), roadrunner_handler:push_fun(), term(), reset | conn_down) -> ok.
deliver_disconnect(Handler, Push, State, Reason) ->
    _ = Handler:handle_info({roadrunner_disconnect, Reason}, Push, State),
    ok.

%% Push handed to the loop handler: empty data is a no-op (matches the
%% h1/h2 contract), non-empty ships as one DATA frame (no FIN).
-spec loop_push(pid(), non_neg_integer(), iodata()) -> ok | {error, term()}.
loop_push(Conn, StreamId, Data) ->
    case iolist_size(Data) of
        0 -> ok;
        Len -> roadrunner_quic:send_data(Conn, StreamId, data_frame(Data, Len), false)
    end.

%% HEADERS frame: QPACK-encoded `:status` + the handler's headers, with
%% connection-specific fields stripped (RFC 9114 §4.2 — h3 MUST NOT
%% generate them) and the auto-injected `Date` (RFC 9110 §6.6.1) added.
-spec header_frame(roadrunner_http:status(), roadrunner_http:headers()) -> iolist().
header_frame(Status, Headers) ->
    Stripped = roadrunner_http:strip_connection_specific_fields(Headers),
    HeaderList = [{~":status", integer_to_binary(Status)} | roadrunner_http:with_date(Stripped)],
    roadrunner_quic_h3_frame:encode_headers(roadrunner_qpack:encode(HeaderList)).

%% DATA frame as an iolist (type + length varints, then the body by
%% reference) so a large body is never flattened. `Len` is the caller's
%% already-computed `iolist_size(Body)`.
-spec data_frame(iodata(), non_neg_integer()) -> iolist().
data_frame(Body, Len) ->
    [roadrunner_quic_varint:encode(?H3_FRAME_DATA), roadrunner_quic_varint:encode(Len), Body].
