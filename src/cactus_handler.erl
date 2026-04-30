-module(cactus_handler).
-moduledoc """
Behaviour for handling parsed HTTP requests.

Implementations receive the parsed request map and return one of:

- `{StatusCode, Headers, Body}` — buffered response, encoded and sent
  in one shot.
- `{stream, StatusCode, Headers, StreamFun}` — chunked streaming. The
  connection emits status + headers (with `Transfer-Encoding: chunked`
  auto-prepended) and calls `StreamFun(Send)` where
  `Send(Data, nofin | fin)` writes one chunk; passing `fin` also
  writes the size-0 terminator.
- `{loop, StatusCode, Headers, State}` — message-driven streaming.
  The connection emits status + headers, then enters a receive loop
  in the conn process. Each Erlang message is dispatched through the
  optional `handle_info/3` callback, which can call `Push(Data)` to
  emit a chunk. Returning `{stop, _}` writes the size-0 terminator
  and closes. Useful for SSE/long-poll endpoints that subscribe to a
  pubsub topic in `handle/1` and forward messages to the wire.
- `{websocket, Module, State}` — upgrade to a `cactus_ws_handler`.
""".

-export_type([send_fun/0, stream_fun/0, push_fun/0, response/0]).

-type send_fun() :: fun((iodata(), nofin | fin) -> ok | {error, term()}).
-type stream_fun() :: fun((send_fun()) -> any()).
-type push_fun() :: fun((iodata()) -> ok | {error, term()}).
-type response() ::
    {StatusCode :: cactus_http1:status(), cactus_http1:headers(), Body :: iodata()}
    | {stream, StatusCode :: cactus_http1:status(), cactus_http1:headers(), stream_fun()}
    | {loop, StatusCode :: cactus_http1:status(), cactus_http1:headers(), State :: term()}
    | {websocket, Module :: module(), State :: term()}.

-callback handle(Request :: cactus_http1:request()) -> response().
-callback handle_info(Info :: term(), Push :: push_fun(), State :: term()) ->
    {ok, NewState :: term()} | {stop, NewState :: term()}.

-optional_callbacks([handle_info/3]).
