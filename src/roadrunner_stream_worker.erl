-module(roadrunner_stream_worker).
-moduledoc false.

%% Runs one HTTP/2 or HTTP/3 request inside its stream worker: route it,
%% run the handler pipeline, send the response and emit the request
%% telemetry. Both protocols share this flow; only how a response is put
%% on the stream differs, so each worker implements the two callbacks
%% below and passes its module in.

-export([run/7]).
-export([conn_heap_floor/1, heap_floor/3]).
-export_type([conn_heap_floor/0, heap_floor/0]).

%% The heap floor of a connection: the min_heap_size it starts its stream
%% workers at, in an atomics cell its workers raise (see conn_heap_floor/1).
%% Base is the size workers start at without it, Cap the most it rises to.
-type conn_heap_floor() ::
    {atomics:atomics_ref(), Base :: pos_integer(), Cap :: pos_integer()} | undefined.
%% What a worker gets of it: the floor it starts at, beside the cell, base
%% and cap (see heap_floor/3).
-type heap_floor() ::
    {atomics:atomics_ref(), Floor :: pos_integer(), Base :: pos_integer(), Cap :: pos_integer()}
    | undefined.

%% Send a complete response (headers and body) on the stream.
-callback send_buffered(
    pid(), non_neg_integer(), roadrunner_http:status(), roadrunner_http:headers(), iodata()
) -> ok.

%% Send the handler's response, returning the status actually sent (which
%% differs from the handler's when the worker overrides a response it
%% cannot send, e.g. 500 for a returned 1xx). It runs in the `of` body of
%% the handler's `try`, which does not catch: if it raises (a stream fun
%% that fails, a sendfile that cannot open its file), no
%% `request_exception` is emitted, the worker exits and the
%% connection resets the stream.
-callback emit_handler_response(
    pid(), non_neg_integer(), module(), roadrunner_handler:response()
) -> roadrunner_http:status().

%% Send an interim 1xx on the stream, for `roadrunner_send:inform/3`.
-callback send_interim(
    pid(), non_neg_integer(), roadrunner_http:status(), roadrunner_http:headers()
) -> ok | {error, term()}.

%% Send a streamed response's head, for `roadrunner_send:stream/3`,
%% returning the body's `Send` and the status actually sent (a 500 when the
%% head could not be).
-callback start_stream(
    pid(), non_neg_integer(), module(), roadrunner_http:status(), roadrunner_http:headers()
) -> {{ok, roadrunner_handler:send_fun()} | {error, term()}, roadrunner_http:status()}.

-spec run(
    module(),
    h2 | h3,
    pid(),
    non_neg_integer(),
    roadrunner_req:request(),
    roadrunner_conn:dispatch(),
    heap_floor()
) -> ok.
run(Worker, Protocol, Conn, StreamId, Req, Dispatch, HeapFloor) ->
    ok = start_at_heap_floor(HeapFloor),
    %% `dispatch` is set by listener init and always present. The matched
    %% route's `Pipeline` is a pre-composed `next()` fun (listener mws ++
    %% per-route mws, with `state` injected up front if attached, ending in
    %% `fun Handler:handle/1`), built once at compile / `reload_routes/2`
    %% time — we just call it with the request, no per-request closure.
    Span = roadrunner_event:request_start(Req),
    case roadrunner_conn:resolve_handler(Dispatch, Req) of
        {ok, Handler, Bindings, Pipeline, _State, Limits} ->
            case route_body(Limits, Req) of
                #{} = Req1 ->
                    invoke(
                        Worker,
                        Protocol,
                        Conn,
                        StreamId,
                        Handler,
                        Pipeline,
                        Req1#{bindings => Bindings},
                        Span,
                        HeapFloor
                    );
                too_large ->
                    ok = Worker:send_buffered(
                        Conn,
                        StreamId,
                        413,
                        [{~"content-type", ~"text/plain"}],
                        ~"Payload Too Large"
                    ),
                    ok = roadrunner_event:request_stop(Span, 413, buffered)
            end;
        {method_not_allowed, Allowed} ->
            %% Path matched but no route on it answers this method: 405 plus
            %% the `Allow` union, decided before any pipeline runs because the
            %% method gate is a routing decision rather than handler work.
            ok = Worker:send_buffered(
                Conn,
                StreamId,
                405,
                [
                    {~"content-type", ~"text/plain"},
                    {~"allow", roadrunner_conn:allow_header_value(Allowed)}
                ],
                ~"Method Not Allowed"
            ),
            ok = roadrunner_event:request_stop(Span, 405, buffered);
        not_found ->
            ok = Worker:send_buffered(
                Conn, StreamId, 404, [{~"content-type", ~"text/plain"}], ~"Not Found"
            ),
            ok = roadrunner_event:request_stop(Span, 404, buffered)
    end.

%% A stream worker starts with a small heap and grows it over several
%% collections to what its request needs, as an HTTP/1.1 connection did
%% before its heap floor (`roadrunner_conn_loop:raise_heap_floor/1`). A
%% worker lives for one request, so the connection keeps the floor instead:
%% each worker raises the connection's cell to the heap its request needed,
%% up to the cap, and the next worker starts at that size. Every 16th
%% stream starts at the base and resets the cell, so the floor is learned
%% again and a connection whose requests got smaller stops sizing workers
%% for the larger ones.

%% The connection's cell, or `undefined` when the listener's
%% `handler_spawn.heap_floor` is `false` or its `max` no higher than the base.
-doc false.
-spec conn_heap_floor(roadrunner_conn:proto_opts()) -> conn_heap_floor().
conn_heap_floor(#{heap_floor := Cap, handler_spawn_opts := SpawnOpts}) ->
    Base =
        case lists:keyfind(min_heap_size, 1, SpawnOpts) of
            {min_heap_size, Words} -> Words;
            false -> element(2, erlang:system_info(min_heap_size))
        end,
    case Cap > Base of
        true ->
            Cell = atomics:new(1, []),
            ok = atomics:put(Cell, 1, Base),
            {Cell, Base, Cap};
        false ->
            undefined
    end;
conn_heap_floor(#{}) ->
    undefined.

%% The floor the next worker starts at. `Relearn` (every 16th stream)
%% starts it at the base and resets the cell.
-doc false.
-spec heap_floor(conn_heap_floor(), non_neg_integer(), h2 | h3) -> heap_floor().
heap_floor(undefined, _StreamId, _Protocol) ->
    undefined;
heap_floor({Cell, Base, Cap}, StreamId, Protocol) ->
    case relearn(StreamId, Protocol) of
        true ->
            ok = atomics:put(Cell, 1, Base),
            {Cell, Base, Base, Cap};
        false ->
            {Cell, atomics:get(Cell, 1), Base, Cap}
    end.

%% Client-initiated request streams count up by 2 on HTTP/2 (1, 3, 5, ...)
%% and by 4 on HTTP/3 (0, 4, 8, ...): every 16th of them relearns.
-spec relearn(non_neg_integer(), h2 | h3) -> boolean().
relearn(StreamId, h2) -> (StreamId bsr 1) rem 16 =:= 0;
relearn(StreamId, h3) -> (StreamId bsr 2) rem 16 =:= 0.

-spec start_at_heap_floor(heap_floor()) -> ok.
start_at_heap_floor({_Cell, Floor, Base, _Cap}) when Floor > Base ->
    _ = erlang:process_flag(min_heap_size, Floor),
    ok;
start_at_heap_floor(_HeapFloor) ->
    ok.

%% Sampled when the handler returns, before the response is encoded. Two
%% workers raising at once can leave the smaller of their sizes; the next
%% worker that needs more raises it again.
-spec raise_heap_floor(heap_floor()) -> ok.
raise_heap_floor(undefined) ->
    ok;
raise_heap_floor({_Cell, Cap, _Base, Cap}) ->
    %% Started at the cap: nothing to raise, so skip reading the heap.
    ok;
raise_heap_floor({Cell, Floor, _Base, Cap}) ->
    {heap_size, Heap} = erlang:process_info(self(), heap_size),
    case min(Heap, Cap) of
        Needed when Needed > Floor ->
            case atomics:get(Cell, 1) of
                Current when Needed > Current -> atomics:put(Cell, 1, Needed);
                _ -> ok
            end;
        _ ->
            ok
    end.

%% The request held to its route's own `max_content_length`, or `too_large`.
%% The connection holds a buffered body to the listener's cap, raised to the
%% route's when a body outgrows it, so only a route cap tighter than the
%% listener's is left to check on one here, once the request is routed. A
%% body read in manual mode is held to the route's cap as it is read.
-spec route_body(roadrunner_router:limits(), roadrunner_req:request()) ->
    roadrunner_req:request() | too_large.
route_body(#{max_content_length := Max}, #{body := Body} = Req) ->
    case iolist_size(Body) > Max of
        true -> too_large;
        false -> Req
    end;
route_body(#{max_content_length := Max}, #{body_reader := Reader} = Req) ->
    Req#{body_reader := Reader#{max := Max}};
route_body(_Limits, Req) ->
    Req.

-spec invoke(
    module(),
    h2 | h3,
    pid(),
    non_neg_integer(),
    module(),
    roadrunner_middleware:next(),
    roadrunner_req:request(),
    roadrunner_event_handler:span(),
    heap_floor()
) -> ok.
invoke(
    Worker,
    Protocol,
    Conn,
    StreamId,
    Handler,
    Pipeline,
    #{method := Method} = Req,
    Span,
    HeapFloor
) ->
    try Pipeline(Req) of
        {{send, Headers, Fun}, Req2} when is_list(Headers), is_function(Fun, 1) ->
            ok = raise_heap_floor(HeapFloor),
            run_send(Worker, Protocol, Conn, StreamId, Handler, Req2, Headers, Fun, Span);
        {Response0, Req2} ->
            ok = raise_heap_floor(HeapFloor),
            %% A handler-returned 1xx or unsafe header becomes a 500 here,
            %% for every shape (`roadrunner_conn:final_response/3`,
            %% `safe_response/3`). Telemetry reports the status actually
            %% sent. RFC 9110 §9.3.2: a HEAD response carries no content, so
            %% emit the body-stripped form; telemetry keeps the shape before
            %% stripping (`roadrunner_conn:response_kind/1`).
            Response = safe_response(
                Protocol, Handler, roadrunner_conn:final_response(Protocol, Handler, Response0)
            ),
            Final = roadrunner_conn:head_response(Response, Method),
            ok = continue_before(Final, Req2),
            Status = Worker:emit_handler_response(Conn, StreamId, Handler, Final),
            ok = roadrunner_event:request_stop(
                Span, Status, roadrunner_conn:response_kind(Response)
            )
    catch
        Class:Reason:Stack ->
            ok = roadrunner_event:request_exception(Span, Class, Reason, Stack),
            logger:error(#{
                msg => crash_message(Protocol),
                handler => Handler,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            ok = Worker:send_buffered(
                Conn, StreamId, 500, [{~"content-type", ~"text/plain"}], ~"Internal Server Error"
            )
    end.

%% A `{send, Headers, Fun}` response: the fun writes the stream itself,
%% as it runs, through `send_emit/4`. It runs under its own `try`
%% (`roadrunner_send_writer:run/5`): a crash before a final response is
%% answered 500, as a handler crash is; one after it leaves the stream to the
%% connection, reset when its body was still open. A transport exit (the
%% stream reset or the connection gone under a write) ends the worker as it
%% does for the `stream` shape, without a report.
-spec run_send(
    module(),
    h2 | h3,
    pid(),
    non_neg_integer(),
    module(),
    roadrunner_req:request(),
    roadrunner_http:headers(),
    roadrunner_send:sender(),
    roadrunner_event_handler:span()
) -> ok.
run_send(Worker, Protocol, Conn, StreamId, Handler, Req, Headers, Fun, Span) ->
    Emit = send_emit(Worker, Protocol, Conn, StreamId, Handler),
    case roadrunner_send_writer:run(Handler, Fun, Headers, Req, Emit) of
        {closed, {Kind, Status, _SentHeaders}} ->
            %% The fun stopped on purpose (`{shutdown, _}`): only its stream
            %% ends.
            roadrunner_event:request_stop(Span, Status, Kind);
        {done, {Kind, Status, _SentHeaders}, _Req2} ->
            roadrunner_event:request_stop(Span, Status, Kind);
        {crashed, exit, Reason, _Stack, _Sent} when
            Reason =:= stream_reset; Reason =:= conn_down; element(1, Reason) =:= quic_conn_down
        ->
            exit(Reason);
        {crashed, Class, Reason, Stack, Sent} ->
            ok = roadrunner_event:request_exception(Span, Class, Reason, Stack),
            logger:error(#{
                msg => crash_message(Protocol),
                handler => Handler,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            crash_answer(Sent, Worker, Conn, StreamId)
    end.

%% A 500 for a fun that crashed before its final response. After a complete
%% one the stream is done; a body still open is reset by the connection on
%% the worker's abnormal exit.
-spec crash_answer(none | complete | open, module(), pid(), non_neg_integer()) -> ok.
crash_answer(none, Worker, Conn, StreamId) ->
    Worker:send_buffered(
        Conn, StreamId, 500, [{~"content-type", ~"text/plain"}], ~"Internal Server Error"
    );
crash_answer(complete, _Worker, _Conn, _StreamId) ->
    ok;
crash_answer(open, _Worker, _Conn, _StreamId) ->
    exit(unfinished_response).

%% `roadrunner_send`'s writer for this stream. A complete or file response
%% goes through the shapes' own send path (`emit_handler_response/4`), so it
%% gets their HEAD and header-limit handling: a status other than the one
%% asked for is the 500 that answered headers over the client's limit. A
%% complete one answers the client, so a 100 Continue still owed is not
%% sent after it (`roadrunner_conn:skip_continue/1`); a stream sends it
%% first.
-spec send_emit(module(), h2 | h3, pid(), non_neg_integer(), module()) ->
    roadrunner_send_writer:emit().
send_emit(Worker, Protocol, Conn, StreamId, Handler) ->
    fun
        ({inform, Status, Headers}, _Req) ->
            Worker:send_interim(Conn, StreamId, Status, Headers);
        ({reply, Status, Headers, Body}, #{method := Method} = Req) ->
            ok = roadrunner_conn:skip_continue(Req),
            Response = roadrunner_conn:head_response({Status, Headers, Body}, Method),
            Sent = Worker:emit_handler_response(Conn, StreamId, Handler, Response),
            {sent(Protocol, Status, Sent), Sent, Headers};
        ({sendfile, Status, Headers, Spec}, #{method := Method} = Req) ->
            ok = roadrunner_conn:skip_continue(Req),
            Response = roadrunner_conn:head_response({sendfile, Status, Headers, Spec}, Method),
            Sent = Worker:emit_handler_response(Conn, StreamId, Handler, Response),
            {sent(Protocol, Status, Sent), Sent, Headers};
        ({stream, Status, Headers}, Req) ->
            ok = roadrunner_conn:continue_before_stream(Req),
            {Result, Sent} = Worker:start_stream(Conn, StreamId, Handler, Status, Headers),
            {Result, Sent, Headers};
        ({websocket, _Mod, _State, _Opts} = Upgrade, _Req) ->
            %% No WebSocket over HTTP/2 or HTTP/3: the 501 a returned
            %% upgrade gets.
            {
                {error, not_supported},
                Worker:emit_handler_response(Conn, StreamId, Handler, Upgrade),
                []
            };
        ({cancel_after, Ms}, _Req) ->
            cancel_after(Protocol, Conn, StreamId, Ms);
        (monitor_connection, _Req) ->
            %% The h2 connection, or the QUIC connection an h3 stream rides
            %% on: either exits when the client's connection goes away.
            {ok, monitor(process, Conn)}
    end.

%% A timer that has the loop holding the stream cancel it: the h2
%% connection (`roadrunner_conn_loop_http2:cancel_stream/2`), or the h3 loop
%% the worker was started from (`roadrunner_conn_loop_http3`), as an h3
%% worker's `Conn` is the QUIC connection.
-spec cancel_after(h2 | h3, pid(), non_neg_integer(), non_neg_integer()) ->
    {ok, reference()}.
cancel_after(Protocol, Conn, StreamId, Ms) ->
    Loop =
        case Protocol of
            h2 -> Conn;
            h3 -> roadrunner_http3_stream_worker:loop()
        end,
    %% `erlang:send_after/3` takes at most 2^32 - 1 ms.
    {ok, erlang:send_after(min(Ms, 16#FFFFFFFF), Loop, {roadrunner_cancel_stream, StreamId})}.

%% A complete response's result: `ok` when its status went out, the
%% header-limit error `start_stream/5` returns when a 500 did instead.
-spec sent(h2 | h3, roadrunner_http:status(), roadrunner_http:status()) ->
    ok | {error, header_list_too_large | field_section_too_large}.
sent(_Protocol, Status, Status) -> ok;
sent(h2, _Status, _Sent) -> {error, header_list_too_large};
sent(h3, _Status, _Sent) -> {error, field_section_too_large}.

%% RFC 9110 §5.5: a response header name or value containing CR, LF or
%% NUL is a handler bug (usually unvalidated user input echoed into a
%% header) that would put malformed bytes on the wire, or split at a
%% downstream h2/h3->h1 reverse proxy. Answer 500 instead, in every
%% shape, before anything is sent; only the kind is logged, never the
%% raw bytes. Checking here, in the worker, keeps the bug on its own
%% stream: the h2 conn process that encodes the headers is shared by
%% every stream of the connection. Connection-specific fields are not
%% rejected here, the send paths strip them.
-spec safe_response(h2 | h3, module(), roadrunner_handler:response()) ->
    roadrunner_handler:response().
safe_response(_Protocol, _Handler, {websocket, _, _} = Response) ->
    Response;
safe_response(_Protocol, _Handler, {websocket, _, _, _} = Response) ->
    Response;
safe_response(Protocol, Handler, Response) ->
    case roadrunner_http:unsafe_header(response_headers(Response)) of
        none ->
            Response;
        Kind ->
            logger:error(#{
                msg => unsafe_message(Protocol),
                handler => Handler,
                kind => Kind
            }),
            {500, [{~"content-type", ~"text/plain"}], ~"Internal Server Error"}
    end.

-spec response_headers(roadrunner_handler:response()) -> roadrunner_http:headers().
response_headers({stream, _, Headers, _}) -> Headers;
response_headers({loop, _, Headers, _}) -> Headers;
response_headers({sendfile, _, Headers, _}) -> Headers;
response_headers({_, Headers, _}) -> Headers.

-spec unsafe_message(h2 | h3) -> string().
unsafe_message(h2) -> "roadrunner h2 handler returned a header with CR/LF/NUL";
unsafe_message(h3) -> "roadrunner h3 handler returned a header with CR/LF/NUL".

%% A response that streams may read the body as it goes: the 100 Continue
%% its client may still be waiting on goes out first
%% (`roadrunner_conn:continue_before_stream/1`).
-spec continue_before(roadrunner_handler:response(), roadrunner_req:request()) -> ok.
continue_before({stream, _Status, _Headers, _Fun}, Req) ->
    roadrunner_conn:continue_before_stream(Req);
continue_before({loop, _Status, _Headers, _State}, Req) ->
    roadrunner_conn:continue_before_stream(Req);
continue_before(_Response, _Req) ->
    ok.

-spec crash_message(h2 | h3) -> string().
crash_message(h2) -> "roadrunner h2 handler crashed";
crash_message(h3) -> "roadrunner h3 handler crashed".
