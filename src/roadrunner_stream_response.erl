-module(roadrunner_stream_response).
-moduledoc """
Per-connection `{stream, ...}` response — chunked Transfer-Encoding.

Called by `roadrunner_conn:dispatch_response/4` after a handler returns
`{stream, Status, Headers, Fun}`. Writes the status line + chunked
headers, then calls the user's `Fun(Send)` with a `Send/2` callback
that frames each emission as one chunk on the wire.

`Send(Data, FinFlag)` — `FinFlag` is one of:
- `nofin` — write `Data` as one chunk; expect more.
- `fin` — write `Data` as one chunk, then the size-0 terminator.
- `{fin, Trailers}` — same as `fin` but the terminator is followed
  by serialized trailer headers (RFC 7230 §4.1.2).

Empty data is special-cased: `Send(<<>>, nofin)` is a no-op (a
zero-length chunk encodes as `0\r\n\r\n`, the chunked terminator,
which would prematurely end the response).

Pure functions, no process spawn — runs in the conn process.
""".

-export([run/4]).

-doc """
Send the chunked-response head, then call the user's stream fun
with a `Send/2` callback. Returns once the stream fun returns;
the caller is responsible for closing the connection (stream
responses always return `close` from the conn's keep-alive
decision).
""".
-spec run(
    roadrunner_transport:socket(),
    roadrunner_http1:status(),
    roadrunner_http1:headers(),
    roadrunner_handler:stream_fun()
) -> ok | {error, term()}.
run(Socket, Status, UserHeaders, Fun) ->
    Headers = [{~"transfer-encoding", ~"chunked"} | UserHeaders],
    Head = roadrunner_http1:response(Status, Headers, ~""),
    _ = roadrunner_telemetry:response_send(
        roadrunner_transport:send(Socket, Head), stream_response_head
    ),
    Send = fun(Data, FinFlag) ->
        Frame = stream_frame(Data, FinFlag),
        roadrunner_transport:send(Socket, Frame)
    end,
    _ = Fun(Send),
    ok.

%% Build the wire frame for one chunked-stream emission.
%%
%% **Empty data is special-cased**: a zero-length chunk would encode
%% as `0\r\n\r\n`, which IS the chunked-body terminator — emitting it
%% mid-stream prematurely ends the response. So `Send(<<>>, nofin)`
%% emits nothing, `Send(<<>>, fin)` emits just the terminator (no
%% leading chunk), and `Send(<<>>, {fin, Trailers})` emits just the
%% terminator + trailers.
-spec stream_frame(iodata(), nofin | fin | {fin, roadrunner_http1:headers()}) -> iodata().
stream_frame(Data, nofin) ->
    case iolist_size(Data) of
        0 -> [];
        N -> [integer_to_binary(N, 16), ~"\r\n", Data, ~"\r\n"]
    end;
stream_frame(Data, fin) ->
    [chunk_or_empty(Data), ~"0\r\n\r\n"];
stream_frame(Data, {fin, Trailers}) ->
    [chunk_or_empty(Data), ~"0\r\n", encode_trailers(Trailers), ~"\r\n"].

-spec chunk_or_empty(iodata()) -> iodata().
chunk_or_empty(Data) ->
    case iolist_size(Data) of
        0 -> [];
        N -> [integer_to_binary(N, 16), ~"\r\n", Data, ~"\r\n"]
    end.

-spec encode_trailers(roadrunner_http1:headers()) -> iodata().
encode_trailers(Trailers) ->
    %% Trailers go on the wire after the size-0 chunk; the same
    %% header-injection defense the response-line headers get applies
    %% here — a CR/LF in a trailer value lets an attacker inject a
    %% phantom trailer header.
    [
        begin
            ok = roadrunner_http1:check_header_safe(Name, name),
            ok = roadrunner_http1:check_header_safe(Value, value),
            [Name, ~": ", Value, ~"\r\n"]
        end
     || {Name, Value} <- Trailers
    ].
