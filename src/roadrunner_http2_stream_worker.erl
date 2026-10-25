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
%% Worker → conn protocol. A streamed response takes a synchronous
%% round-trip per write so the worker doesn't outpace flow control or
%% the wire:
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
%% A buffered response is the worker's last word on its stream, so it
%% goes one way, with no ack to wait for:
%%
%% ```
%% Worker → Conn: {h2_send_response, StreamId, Status, Headers, Body, BodyLen}
%% ```
%%
%% The worker has no explicit "done" message: it is spawn_monitored, so
%% the conn finalises the stream on the worker's `DOWN`, or, when flow
%% control still holds part of a buffered body, once that body drains.
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
%%
%% Client header limit (RFC 9113 §6.5.2): a client that sent
%% SETTINGS_MAX_HEADER_LIST_SIZE may treat a larger header section as
%% malformed, so the worker does not send one. The conn hands the worker
%% the limit it knows when it spawns it (a value lowered by a later
%% SETTINGS frame holds for the workers spawned after it: the setting is
%% advisory, §10.5.1), and the worker keeps it in its process dictionary
%% only when there is one, so a client that set no limit costs one `get/1`
%% per response. The conn encodes the headers, but the worker sizes the
%% same field section (`field_section/3`, which the conn builds it with)
%% and decides: a handler response over the limit is answered 500
%% instead, before anything is sent, and reported as 500; trailers over
%% it, or one of the worker's own answers (404, 413, 500, ...) over it,
%% crash the worker, so the conn resets the stream (INTERNAL_ERROR). The
%% oversized fields never reach the conn's HPACK encoder. HTTP/3 does the
%% same (`roadrunner_http3_stream_worker`).

-export([start/5]).
-export([init/5]).
%% `roadrunner_stream_worker` callbacks.
-export([send_buffered/5, emit_handler_response/4]).
%% For the conn, which builds the section it sends with it.
-export([field_section/3]).
%% For the trailers `roadrunner_http2_stream_response` sends.
-export([check_trailers/1]).

-behaviour(roadrunner_stream_worker).

%% Worker process-dict entry holding the client's
%% SETTINGS_MAX_HEADER_LIST_SIZE and the conn's `alt-svc` value (both
%% needed to size a response's field section), absent when it set none.
-define(PEER_LIMIT_KEY, '$roadrunner_http2_peer_max_header_list_size').

-doc """
Spawn a new worker for `StreamId`, monitored by the calling conn
process. The worker runs `Req` through the dispatch pipeline and
emits frame messages back to the conn. Returns the
`{Pid, MonitorRef}` so the conn can correlate the eventual `'DOWN'`
back to the stream id.

`PeerLimit` is the client's SETTINGS_MAX_HEADER_LIST_SIZE as the conn
knows it now, or `infinity` when it set none.

Workers are NOT linked: a handler crash should reset just the
affected stream, not tear down the whole connection. The conn
sees the `'DOWN'` and emits `RST_STREAM(INTERNAL_ERROR)` for the
stream's id, leaving the other 99 streams intact.
""".
-spec start(
    pid(), pos_integer(), roadrunner_req:request(), map(), non_neg_integer() | infinity
) ->
    {pid(), reference()}.
start(
    ConnPid,
    StreamId,
    Req,
    #{handler_spawn_opts := SpawnOpts, dispatch := Dispatch} = ProtoOpts,
    PeerLimit
) ->
    spawn_opt(
        ?MODULE,
        init,
        [ConnPid, StreamId, Req, Dispatch, peer_limit(PeerLimit, ProtoOpts)],
        [monitor | SpawnOpts]
    ).

%% The client's limit, paired with the `alt-svc` value the conn adds to
%% every response (read from the same proto opts, as the conn's
%% `enter/6` does), or `infinity` for no limit.
-spec peer_limit(non_neg_integer() | infinity, map()) ->
    {non_neg_integer(), binary() | undefined} | infinity.
peer_limit(infinity, _ProtoOpts) ->
    infinity;
peer_limit(Limit, ProtoOpts) ->
    {Limit, maps:get(alt_svc, ProtoOpts, undefined)}.

-doc false.
-spec init(
    pid(),
    pos_integer(),
    roadrunner_req:request(),
    roadrunner_conn:dispatch(),
    {non_neg_integer(), binary() | undefined} | infinity
) -> ok.
init(ConnPid, StreamId, Req, Dispatch, PeerLimit) ->
    proc_lib:set_label({roadrunner_http2_stream_worker, StreamId}),
    %% Mirror the h1 path: attach request-scoped metadata so any
    %% `?LOG_*` from middleware/handlers is auto-correlated by
    %% `request_id`. The conn process can't do this for us — the
    %% handler runs in this worker, not on the conn.
    ok = roadrunner_conn:set_request_logger_metadata(Req),
    ok = set_peer_limit(PeerLimit),
    %% No conn monitor here: a buffered response goes one way and never
    %% waits on the conn, so only the stream / loop emitters, which do,
    %% set one up (`roadrunner_http2_worker_sync:monitor_conn/1`).
    ok = roadrunner_stream_worker:run(?MODULE, h2, ConnPid, StreamId, Req, Dispatch),
    %% No explicit completion message: the worker is spawn_monitored by
    %% the conn, which finalises the stream on the worker's `DOWN`
    %% (`normal` -> clean removal, or once a buffered body still queued
    %% behind flow control drains; anything else -> RST_STREAM).
    ok.

%% Keep the client's limit for the send paths; nothing when it set none,
%% so `get(?PEER_LIMIT_KEY)` is `undefined` and no size is computed.
-spec set_peer_limit({non_neg_integer(), binary() | undefined} | infinity) -> ok.
set_peer_limit(infinity) ->
    ok;
set_peer_limit(PeerLimit) ->
    _ = put(?PEER_LIMIT_KEY, PeerLimit),
    ok.

%% Returns the status actually sent.
-doc false.
-spec emit_handler_response(pid(), pos_integer(), module(), roadrunner_handler:response()) ->
    roadrunner_http:status().
emit_handler_response(ConnPid, StreamId, _Handler, {websocket, _, _}) ->
    ok = emit_501(ConnPid, StreamId),
    501;
emit_handler_response(ConnPid, StreamId, _Handler, {websocket, _, _, _}) ->
    ok = emit_501(ConnPid, StreamId),
    501;
emit_handler_response(ConnPid, StreamId, Handler, Response) ->
    case get(?PEER_LIMIT_KEY) of
        undefined ->
            emit(ConnPid, StreamId, Handler, Response);
        {Limit, AltSvc} ->
            {Status, Headers} = status_headers(Response),
            case roadrunner_http:header_list_size(field_section(Status, Headers, AltSvc)) of
                Size when Size =< Limit ->
                    emit(ConnPid, StreamId, Handler, Response);
                Size ->
                    %% RFC 9113 §6.5.2: the client will likely refuse a
                    %% header section over its SETTINGS_MAX_HEADER_LIST_SIZE.
                    %% Nothing is sent yet, so answer 500, as for an unsafe
                    %% header, and report it; only the sizes are logged,
                    %% never the fields.
                    logger:error(#{
                        msg => "roadrunner h2 response headers exceed the client's limit",
                        handler => Handler,
                        size => Size,
                        limit => Limit
                    }),
                    ok = send_buffered(
                        ConnPid,
                        StreamId,
                        500,
                        [{~"content-type", ~"text/plain"}],
                        ~"Internal Server Error"
                    ),
                    500
            end
    end.

-spec status_headers(roadrunner_handler:response()) ->
    {roadrunner_http:status(), roadrunner_http:headers()}.
status_headers({stream, Status, Headers, _Fun}) -> {Status, Headers};
status_headers({sendfile, Status, Headers, _Spec}) -> {Status, Headers};
status_headers({loop, Status, Headers, _State}) -> {Status, Headers};
status_headers({Status, Headers, _Body}) -> {Status, Headers}.

%% Send a handler response whose headers are within the client's limit.
-spec emit(pid(), pos_integer(), module(), roadrunner_handler:response()) ->
    roadrunner_http:status().
emit(ConnPid, StreamId, _Handler, {Status, Headers, Body}) when
    is_integer(Status), Status >= 200, Status =< 599
->
    ok = send_response(ConnPid, StreamId, Status, Headers, Body),
    Status;
emit(ConnPid, StreamId, _Handler, {stream, Status, Headers, Fun}) when
    is_integer(Status), Status >= 100, Status =< 599, is_function(Fun, 1)
->
    ok = roadrunner_http2_stream_response:run(ConnPid, StreamId, Status, Headers, Fun),
    Status;
emit(ConnPid, StreamId, Handler, {loop, Status, Headers, State}) when
    is_integer(Status), Status >= 100, Status =< 599
->
    %% Mirrors h1's `{loop, _}` path: enter a selective-receive loop
    %% in the worker (sharing the handler's mailbox), dispatch each
    %% non-OTP message through `Handler:handle_info/3`, emit DATA
    %% frames via Push. On `{stop, _}` the worker emits an empty
    %% DATA + END_STREAM and exits.
    ok = roadrunner_http2_loop_response:run(
        ConnPid, StreamId, Status, Headers, {Handler, State}
    ),
    Status;
emit(ConnPid, StreamId, _Handler, {sendfile, Status, Headers, {File, Offset, Length}}) when
    is_integer(Status), Status >= 100, Status =< 599
->
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
    ok = roadrunner_http2_stream_response:run(ConnPid, StreamId, Status, Headers, Fun),
    Status.

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
%% or constrained windows.
%%
%% Every caller sends this as the stream's final response and then
%% exits, so there is nothing left to back-pressure: the message goes
%% one way and the worker does not wait for the frames to be written.
%% That saves the ack and the worker wake-up per request; the conn owns
%% the response from here, including any body still queued behind flow
%% control after the worker is gone.
%%
%% This is the path of the worker's own answers (404, 405, 413, 500,
%% 501), checked against the client's header limit here; a handler's
%% response is checked before it gets this far and goes straight to
%% `send_response/5`. The conn's own answers (413, 431, 429, 503, the
%% interim 100) are not checked: only a worker holds the limit, and their
%% few fixed fields come to under 200 bytes.
-doc false.
-spec send_buffered(
    pid(), non_neg_integer(), roadrunner_http:status(), roadrunner_http:headers(), iodata()
) -> ok.
send_buffered(ConnPid, StreamId, Status, Headers, Body) ->
    ok =
        case get(?PEER_LIMIT_KEY) of
            undefined -> ok;
            {Limit, AltSvc} -> check_fits(field_section(Status, Headers, AltSvc), Limit)
        end,
    send_response(ConnPid, StreamId, Status, Headers, Body).

-spec send_response(
    pid(), non_neg_integer(), roadrunner_http:status(), roadrunner_http:headers(), iodata()
) -> ok.
send_response(ConnPid, StreamId, Status, Headers, Body) ->
    %% Sized here, in the worker: a handler's non-iodata body crashes this
    %% worker, so the conn resets just its stream instead of crashing on it
    %% with every stream it carries, and the conn reads the size instead of
    %% walking the body again.
    _ = (ConnPid ! {h2_send_response, StreamId, Status, Headers, Body, iolist_size(Body)}),
    ok.

%% Trailers over the client's header limit (RFC 9113 §6.5.2) go out after
%% the status, so they cannot become a 500: crash, so the conn resets the
%% stream. `Trailers` are the section as sent (already stripped).
-doc false.
-spec check_trailers(roadrunner_http:headers()) -> ok.
check_trailers(Trailers) ->
    case get(?PEER_LIMIT_KEY) of
        undefined -> ok;
        {Limit, _AltSvc} -> check_fits(Trailers, Limit)
    end.

%% A section the client will likely refuse, sent after the handler's
%% status is decided (trailers) or as the worker's own answer: crash.
-spec check_fits(roadrunner_http:headers(), non_neg_integer()) -> ok.
check_fits(Fields, Limit) ->
    case roadrunner_http:fits_header_list_size(Fields, Limit) of
        true -> ok;
        false -> error(header_list_too_large)
    end.

%% The response field section as the conn sends it: `:status` + the
%% handler's headers, with the connection-specific fields RFC 9113 §8.2.2
%% forbids h2 from generating stripped and the auto headers (`date`,
%% `alt-svc`) added. The conn builds the section it HPACK-encodes with
%% this (`roadrunner_conn_loop_http2:response_fields/3`), so the size the
%% worker checks is the size that goes out (`date` changes each second
%% but not in length).
-doc false.
-spec field_section(roadrunner_http:status(), roadrunner_http:headers(), binary() | undefined) ->
    roadrunner_http:headers().
field_section(Status, Headers, AltSvc) ->
    WireHeaders = roadrunner_http:strip_connection_specific_fields(Headers),
    [{~":status", integer_to_binary(Status)} | roadrunner_http:auto_headers(WireHeaders, AltSvc)].
