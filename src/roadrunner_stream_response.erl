-module(roadrunner_stream_response).
-moduledoc false.

%% Per-connection `{stream, ...}` response — chunked Transfer-Encoding.
%%
%% Called by `roadrunner_conn_loop:dispatch_response/4` after a handler returns
%% `{stream, Status, Headers, Fun}`. Writes the status line + chunked
%% headers, then calls the user's `Fun(Send)` with a `Send/2` callback
%% that frames each emission as one chunk on the wire.
%%
%% `Send(Data, FinFlag)` — `FinFlag` is one of:
%% - `nofin` — write `Data` as one chunk; expect more.
%% - `fin` — write `Data` as one chunk, then the size-0 terminator.
%% - `{fin, Trailers}` — same as `fin` but the terminator is followed
%%   by serialized trailer headers (RFC 9112 §7.1.2).
%%
%% Empty data is special-cased: `Send(<<>>, nofin)` is a no-op (a
%% zero-length chunk encodes as `0\r\n\r\n`, the chunked terminator,
%% which would prematurely end the response).
%%
%% A fun that returns without a `fin` gets the size-0 terminator written
%% for it, so the client sees a complete chunked body (as HTTP/2 and
%% HTTP/3 end such a stream) instead of one the close cuts short.
%%
%% No process spawn — runs in the conn process.

-export([run/4, start/3]).
%% Shared with `roadrunner_loop_response`'s push.
-export([chunk_or_empty/1]).

%% Process-dict flag: set once `Send` writes a fin variant. The conn runs
%% one stream response at a time, and `start/3` clears it first.
-define(FIN_KEY, '$roadrunner_stream_fin').

-doc """
Send the chunked-response head, then call the user's stream fun
with a `Send/2` callback. Returns once the stream fun returns;
the caller is responsible for closing the connection (stream
responses always return `close` from the conn's keep-alive
decision).
""".
-spec run(
    roadrunner_transport:socket(),
    roadrunner_http:status(),
    roadrunner_http:headers(),
    roadrunner_handler:stream_fun()
) -> ok | {error, term()}.
run(Socket, Status, UserHeaders, Fun) ->
    {_, Send} = start(Socket, Status, UserHeaders),
    _ = Fun(Send),
    _ = erase(?FIN_KEY) =:= true orelse roadrunner_transport:send(Socket, ~"0\r\n\r\n"),
    ok.

%% Send the chunked-response head and return the head write's result with
%% the `Send/2` that writes the body: `run/4`'s first half, for a
%% `roadrunner_respond:stream/3` call, whose fun goes on after it.
-doc false.
-spec start(roadrunner_transport:socket(), roadrunner_http:status(), roadrunner_http:headers()) ->
    {ok | {error, term()}, roadrunner_handler:send_fun()}.
start(Socket, Status, UserHeaders) ->
    %% A stream response always closes the connection (the conn loop force-
    %% closes once this returns), so advertise it on the wire per RFC 9112
    %% §9.6 — without it a fronting proxy treats the connection as reusable
    %% and can race a request onto a socket we are about to drop.
    Headers = [{~"transfer-encoding", ~"chunked"}, {~"connection", ~"close"} | UserHeaders],
    Head = roadrunner_http1:response(Status, Headers, ~""),
    Result = roadrunner_event:response_send(
        roadrunner_transport:send(Socket, Head), stream_response_head
    ),
    _ = erase(?FIN_KEY),
    Send = fun
        (Data, nofin) ->
            roadrunner_transport:send(Socket, stream_frame(Data, nofin));
        (Data, FinFlag) ->
            _ = put(?FIN_KEY, true),
            roadrunner_transport:send(Socket, stream_frame(Data, FinFlag))
    end,
    {Result, Send}.

%% Build the wire frame for one chunked-stream emission.
%%
%% **Empty data is special-cased**: a zero-length chunk would encode
%% as `0\r\n\r\n`, which IS the chunked-body terminator — emitting it
%% mid-stream prematurely ends the response. So `Send(<<>>, nofin)`
%% emits nothing, `Send(<<>>, fin)` emits just the terminator (no
%% leading chunk), and `Send(<<>>, {fin, Trailers})` emits just the
%% terminator + trailers.
-spec stream_frame(iodata(), nofin | fin | {fin, roadrunner_http:headers()}) -> iodata().
stream_frame(Data, nofin) ->
    chunk_or_empty(Data);
stream_frame(Data, fin) ->
    [chunk_or_empty(Data), ~"0\r\n\r\n"];
stream_frame(Data, {fin, Trailers}) ->
    [chunk_or_empty(Data), ~"0\r\n", encode_trailers(Trailers), ~"\r\n"].

%% One chunk of `Data` (RFC 9112 §7.1), or nothing for empty data: a
%% zero-length chunk would be the terminator and end the response.
-doc false.
-spec chunk_or_empty(iodata()) -> iodata().
chunk_or_empty(Data) ->
    case iolist_size(Data) of
        0 -> [];
        N -> [integer_to_binary(N, 16), ~"\r\n", Data, ~"\r\n"]
    end.

-spec encode_trailers(roadrunner_http:headers()) -> iodata().
encode_trailers(Trailers) ->
    %% Trailers go on the wire after the size-0 chunk; the same
    %% header-injection defense the response-line headers get applies
    %% here — a CR/LF in a trailer value lets an attacker inject a
    %% phantom trailer header.
    [
        begin
            ok = roadrunner_http:check_header_safe(Name, name),
            ok = roadrunner_http:check_header_safe(Value, value),
            [Name, ~": ", Value, ~"\r\n"]
        end
     || {Name, Value} <- Trailers
    ].
