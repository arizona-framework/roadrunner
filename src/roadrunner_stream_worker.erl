-module(roadrunner_stream_worker).
-moduledoc false.

%% Runs one HTTP/2 or HTTP/3 request inside its stream worker: route it,
%% run the handler pipeline, send the response and emit the request
%% telemetry. Both protocols share this flow; only how a response is put
%% on the stream differs, so each worker implements the two callbacks
%% below and passes its module in.

-export([run/6]).

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

-spec run(
    module(),
    h2 | h3,
    pid(),
    non_neg_integer(),
    roadrunner_req:request(),
    roadrunner_conn:dispatch()
) -> ok.
run(Worker, Protocol, Conn, StreamId, Req, Dispatch) ->
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
                        Span
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
    roadrunner_event_handler:span()
) -> ok.
invoke(
    Worker,
    Protocol,
    Conn,
    StreamId,
    Handler,
    Pipeline,
    #{method := Method} = Req,
    Span
) ->
    try Pipeline(Req) of
        {Response0, Req2} ->
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
    case unsafe_header(response_headers(Response)) of
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

%% The kind of the first field with CR/LF/NUL in it, or `none`.
-spec unsafe_header(roadrunner_http:headers()) -> none | name | value.
unsafe_header([]) ->
    none;
unsafe_header([{Name, Value} | Rest]) ->
    case roadrunner_http:is_header_safe(Name) of
        true ->
            case roadrunner_http:is_header_safe(Value) of
                true -> unsafe_header(Rest);
                false -> value
            end;
        false ->
            name
    end.

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
