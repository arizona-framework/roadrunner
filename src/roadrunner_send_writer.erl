-module(roadrunner_send_writer).
-moduledoc false.

%% Runs a `{send, Headers, Fun}` response's fun and backs the
%% `roadrunner_send` calls it makes. Each protocol passes its writer
%% (`t:emit/0`) to `run/5`, which hands it to the fun on the request, so
%% the calls write the wire from the process running the handler: the
%% connection on HTTP/1.1, the stream worker on HTTP/2 and HTTP/3. What
%% went out is kept in that process's dictionary, so a second final
%% response is refused and `run/5` can finish what the fun left open. A
%% call from any other process raises `not_in_send_fun`: it would write
%% the wire behind that dictionary's back.

-include_lib("kernel/include/file.hrl").

-export([inform/3, final/3, run/5, started/2]).

-export_type([writer/0, op/0, emit/0, sent/0, outcome/0]).

-record(writer, {
    emit :: emit(),
    headers :: roadrunner_http:headers(),
    owner :: pid()
}).

%% The response so far: `undefined` before a final response, `emitting`
%% while the protocol writes one, `{open, ...}` while a stream is not
%% ended, `{sent, ...}` once the final response is complete. One response
%% runs at a time per process, and `run/5` clears it.
-define(KEY, '$roadrunner_send').

-opaque writer() :: #writer{}.

-type op() ::
    {inform, roadrunner_http:status(), roadrunner_http:headers()}
    | {reply, roadrunner_http:status(), roadrunner_http:headers(), iodata()}
    | {stream, roadrunner_http:status(), roadrunner_http:headers()}
    | {sendfile, roadrunner_http:status(), roadrunner_http:headers(),
        roadrunner_handler:sendfile_spec()}
    | {websocket, module(), term(), roadrunner_ws_handler:upgrade_opts()}.

%% A protocol's writer for each call, given the request the fun holds then.
%% `inform` returns the call's result; a final response returns it with the
%% status and headers that went out (a 500 in place of a response the
%% protocol could not send, the headers the HTTP/1.1 keep-alive decision
%% reads). A WebSocket upgrade returns what its protocol needs to finish
%% the request in place of the headers.
-type emit() :: fun((op(), roadrunner_req:request()) -> term()).

-type kind() :: buffered | stream | sendfile | websocket.

-type sent() ::
    {buffered | stream | sendfile, roadrunner_http:status(), roadrunner_http:headers()}
    | {websocket, roadrunner_http:status(), term()}.

-type outcome() ::
    {done, sent(), roadrunner_req:request()}
    | {closed, sent()}
    | {crashed, error | exit | throw, term(), erlang:stacktrace(), none | complete | open}.

-type result() :: ok | {ok, roadrunner_handler:send_fun()} | {error, term()}.

-spec inform(roadrunner_http:status(), roadrunner_http:headers(), roadrunner_req:request()) ->
    ok | {error, term()}.
inform(Status, Headers, #{send := #writer{emit = Emit, owner = Owner}} = Req) when
    Owner =:= self()
->
    ok = unsent(),
    case roadrunner_http:unsafe_header(Headers) of
        none ->
            Emit({inform, Status, Headers}, Req);
        Kind ->
            ok = log_unsafe(Kind),
            {error, unsafe_header}
    end;
inform(_Status, _Headers, #{send := #writer{}}) ->
    error(not_in_send_fun).

%% The final response, with the tuple's headers added: sent, or answered
%% 500 when it cannot be (`check/1`). A protocol's writer can crash once
%% part of the response is on the wire (a file read failing after its
%% head), so the response counts as started while the writer runs: a crash
%% then cuts it, as one in an open stream does, and no 500 follows a head.
-spec final(kind(), op(), roadrunner_req:request()) -> result().
final(websocket, Op, #{send := #writer{emit = Emit, owner = Owner}} = Req) when
    Owner =:= self()
->
    %% A 101 carries the upgrade options' headers, never the tuple's: the
    %% middlewares leave a returned `{websocket, ...}` alone too.
    ok = unsent(),
    _ = put(?KEY, emitting),
    {Result, Status, Session} = Emit(Op, Req),
    record(websocket, Result, Status, Session);
final(Kind, Op0, #{send := #writer{emit = Emit, headers = Extra, owner = Owner}} = Req) when
    Owner =:= self()
->
    ok = unsent(),
    Op = with_headers(Op0, Extra),
    case check(Op) of
        ok ->
            _ = put(?KEY, emitting),
            {Result, Status, Headers} = Emit(Op, Req),
            record(Kind, Result, Status, Headers);
        {error, _} = Error ->
            ok = internal_error(Emit, Req),
            Error
    end;
final(_Kind, _Op, #{send := #writer{}}) ->
    error(not_in_send_fun).

%% What keeps a final response from going out, found before any of it
%% does: a header with CR/LF/NUL, or a file that is not there or shorter
%% than its range. A file can still change before it is read; a read
%% failing after the head cuts the response.
-spec check(op()) -> ok | {error, term()}.
check(Op) ->
    case roadrunner_http:unsafe_header(element(3, Op)) of
        none ->
            check_file(Op);
        Kind ->
            ok = log_unsafe(Kind),
            {error, unsafe_header}
    end.

-spec check_file(op()) -> ok | {error, term()}.
check_file({sendfile, _Status, _Headers, {File, Offset, Length}}) ->
    case file:read_file_info(File, [raw]) of
        {ok, #file_info{type = regular, size = Size}} when Size < Offset + Length ->
            log_file(file_too_short);
        {ok, #file_info{}} ->
            ok;
        {error, Reason} ->
            log_file(Reason)
    end;
check_file(_Op) ->
    ok.

-spec log_file(term()) -> {error, term()}.
log_file(Reason) ->
    logger:error(#{msg => "roadrunner send file could not be read", reason => Reason}),
    {error, Reason}.

-spec with_headers(op(), roadrunner_http:headers()) -> op().
with_headers(Op, []) ->
    Op;
with_headers(Op, Extra) ->
    setelement(3, Op, merge_headers(element(3, Op), Extra)).

%% The call's headers win a name both set, except `vary`, a list (RFC 9110
%% §12.5.5) a middleware adds its own entry to: both values are kept, so a
%% call's `vary` does not drop the `Origin` `roadrunner_cors` varies on.
-spec merge_headers(roadrunner_http:headers(), roadrunner_http:headers()) ->
    roadrunner_http:headers().
merge_headers(Headers, Extra) ->
    case {lists:keyfind(~"vary", 1, Headers), lists:keyfind(~"vary", 1, Extra)} of
        {{_, Call}, {_, Tuple}} ->
            Vary = {~"vary", <<Call/binary, ", ", Tuple/binary>>},
            roadrunner_http:with_defaults(lists:keystore(~"vary", 1, Headers, Vary), Extra);
        _ ->
            roadrunner_http:with_defaults(Headers, Extra)
    end.

-spec record(kind(), result(), roadrunner_http:status(), roadrunner_http:headers()) -> result().
record(stream, {ok, Send}, Status, Headers) ->
    _ = put(?KEY, {open, Status, Headers, Send}),
    {ok, ended_on_fin(Send, Status, Headers)};
record(Kind, Result, Status, Headers) ->
    _ = put(?KEY, {sent, Kind, Status, Headers}),
    Result.

%% The stream's `Send`, which marks the stream complete once a `fin` goes
%% out, so `run/5` does not end it again.
-spec ended_on_fin(
    roadrunner_handler:send_fun(), roadrunner_http:status(), roadrunner_http:headers()
) -> roadrunner_handler:send_fun().
ended_on_fin(Send, Status, Headers) ->
    fun
        (Data, nofin) ->
            Send(Data, nofin);
        (Data, Fin) ->
            _ = put(?KEY, {sent, stream, Status, Headers}),
            Send(Data, Fin)
    end.

-spec unsent() -> ok.
unsent() ->
    case get(?KEY) of
        undefined -> ok;
        _ -> error(already_sent)
    end.

-spec internal_error(emit(), roadrunner_req:request()) -> ok.
internal_error(Emit, Req) ->
    {_, Status, Headers} = Emit(
        {reply, 500, [{~"content-type", ~"text/plain"}], ~"Internal Server Error"}, Req
    ),
    _ = put(?KEY, {sent, buffered, Status, Headers}),
    ok.

-spec log_unsafe(name | value) -> ok.
log_unsafe(Kind) ->
    logger:error(#{msg => "roadrunner send call had a header with CR/LF/NUL", kind => Kind}).

%% Run the fun under its own `try`, so a crash is reported with what had
%% gone out by then. Its return is the request; anything else is a handler
%% bug that crashes the caller, as a bad `handle/1` return does.
-spec run(
    module(),
    roadrunner_send:sender(),
    roadrunner_http:headers(),
    roadrunner_req:request(),
    emit()
) -> outcome().
run(Handler, Fun, Headers, Req, Emit) ->
    _ = erase(?KEY),
    try Fun(Req#{send => #writer{emit = Emit, headers = Headers, owner = self()}}) of
        #{} = Req2 ->
            Req3 = maps:remove(send, Req2),
            {done, finish(Handler, Emit, Req3), Req3}
    catch
        exit:{shutdown, _} = Reason:Stack ->
            %% The OTP way to stop on purpose: the response is finished as
            %% far as it went, nothing is logged, and the request reports a
            %% stop. Inside the protocol's writer it stays a crash.
            case erase(?KEY) of
                emitting -> {crashed, exit, Reason, Stack, open};
                Sent -> {closed, closed(Sent, Emit, Req)}
            end;
        Class:Reason:Stack ->
            {crashed, Class, Reason, Stack, crashed_state(erase(?KEY))}
    end.

%% The response a `{shutdown, _}` exit leaves: as sent, an open stream
%% ended, a 500 for none.
-spec closed(term(), emit(), roadrunner_req:request()) -> sent().
closed({sent, Kind, Status, Headers}, _Emit, _Req) ->
    {Kind, Status, Headers};
closed({open, Status, Headers, Send}, _Emit, _Req) ->
    _ = Send(<<>>, fin),
    {stream, Status, Headers};
closed(undefined, Emit, Req) ->
    ok = internal_error(Emit, Req),
    {sent, buffered, Status, Headers} = erase(?KEY),
    {buffered, Status, Headers}.

%% What the fun left: an open stream is ended, no response answered 500.
-spec finish(module(), emit(), roadrunner_req:request()) -> sent().
finish(Handler, Emit, Req) ->
    case erase(?KEY) of
        {sent, Kind, Status, Headers} ->
            {Kind, Status, Headers};
        {open, Status, Headers, Send} ->
            _ = Send(<<>>, fin),
            {stream, Status, Headers};
        emitting ->
            %% The fun caught a crash of the protocol's writer: what went
            %% out is unknown, so the response is cut.
            error(unfinished_response);
        undefined ->
            logger:error(#{
                msg => "roadrunner send fun returned without a response",
                handler => Handler
            }),
            ok = internal_error(Emit, Req),
            {sent, buffered, Status, Headers} = erase(?KEY),
            {buffered, Status, Headers}
    end.

%% A streamed response's head write turned into `stream/3`'s return.
-spec started(ok | {error, term()}, roadrunner_handler:send_fun()) ->
    {ok, roadrunner_handler:send_fun()} | {error, term()}.
started(ok, Send) -> {ok, Send};
started({error, _} = Error, _Send) -> Error.

-spec crashed_state(term()) -> none | complete | open.
crashed_state(undefined) -> none;
crashed_state(emitting) -> open;
crashed_state({sent, _, _, _}) -> complete;
crashed_state({open, _, _, _}) -> open.
