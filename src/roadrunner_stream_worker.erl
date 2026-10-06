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
%% `[roadrunner, request, exception]` is emitted, the worker exits and the
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
    Metadata = roadrunner_telemetry:request_metadata(Req),
    ReqStart = roadrunner_telemetry:request_start(Metadata),
    case roadrunner_conn:resolve_handler(Dispatch, Req) of
        {ok, Handler, Bindings, Pipeline, _State} ->
            invoke(
                Worker,
                Protocol,
                Conn,
                StreamId,
                Handler,
                Pipeline,
                Req#{bindings => Bindings},
                Metadata,
                ReqStart
            );
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
            ok = roadrunner_telemetry:request_stop(ReqStart, Metadata, 405, buffered);
        not_found ->
            ok = Worker:send_buffered(
                Conn, StreamId, 404, [{~"content-type", ~"text/plain"}], ~"Not Found"
            ),
            ok = roadrunner_telemetry:request_stop(ReqStart, Metadata, 404, buffered)
    end.

-spec invoke(
    module(),
    h2 | h3,
    pid(),
    non_neg_integer(),
    module(),
    roadrunner_middleware:next(),
    roadrunner_req:request(),
    roadrunner_telemetry:metadata(),
    integer()
) -> ok.
invoke(
    Worker,
    Protocol,
    Conn,
    StreamId,
    Handler,
    Pipeline,
    #{method := Method} = Req,
    Metadata,
    ReqStart
) ->
    try Pipeline(Req) of
        {Response, _Req2} ->
            %% Telemetry reports the status actually sent. RFC 9110 §9.3.2:
            %% a HEAD response carries no content, so emit the body-stripped
            %% form; telemetry keeps the handler's original shape
            %% (`response_kind/1` below).
            Status = Worker:emit_handler_response(
                Conn, StreamId, Handler, roadrunner_conn:head_response(Response, Method)
            ),
            ok = roadrunner_telemetry:request_stop(
                ReqStart, Metadata, Status, roadrunner_conn:response_kind(Response)
            )
    catch
        Class:Reason:Stack ->
            ok = roadrunner_telemetry:request_exception(ReqStart, Metadata, Class, Reason),
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

-spec crash_message(h2 | h3) -> string().
crash_message(h2) -> "roadrunner h2 handler crashed";
crash_message(h3) -> "roadrunner h3 handler crashed".
