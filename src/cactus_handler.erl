-module(cactus_handler).
-moduledoc """
Behaviour for handling parsed HTTP requests.

Implementations receive the parsed request map and return either a
buffered `{StatusCode, Headers, Body}` triple or a streaming
`{stream, StatusCode, Headers, StreamFun}` tuple.

For the buffered shape, the connection encodes the full response and
closes. For the streaming shape, the connection emits the status line
and headers (with `Transfer-Encoding: chunked` auto-prepended), then
calls `StreamFun(Send)` where `Send(Data, nofin | fin)` writes one
chunk; passing `fin` writes the size-0 terminator.
""".

-export_type([send_fun/0, stream_fun/0, response/0]).

-type send_fun() :: fun((iodata(), nofin | fin) -> ok | {error, term()}).
-type stream_fun() :: fun((send_fun()) -> any()).
-type response() ::
    {StatusCode :: cactus_http1:status(), cactus_http1:headers(), Body :: iodata()}
    | {stream, StatusCode :: cactus_http1:status(), cactus_http1:headers(), stream_fun()}
    | {websocket, Module :: module(), State :: term()}.

-callback handle(Request :: cactus_http1:request()) -> response().
