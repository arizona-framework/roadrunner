-module(roadrunner_handler).
-moduledoc """
Behaviour for handling parsed HTTP requests.

Implementations receive the parsed request map and return a
`{Response, Req2}` pair — the `Response` selects what the conn does
on the wire, and `Req2` is the (possibly mutated) request threaded
back to the conn. Always returning `Req2` lets the conn drain
unread bodies in `body_buffering => manual` mode, lets response
middlewares observe and rewrite, and matches cowboy's idiom of
threading `Req` through the entire request lifecycle.

`Response` is one of:

- `{StatusCode, Headers, Body}` — buffered response, encoded and sent
  in one shot.
- `{stream, StatusCode, Headers, StreamFun}` — chunked streaming. The
  connection emits status + headers (with `Transfer-Encoding: chunked`
  auto-prepended) and calls `StreamFun(Send)` where
  `Send(Data, nofin | fin | {fin, Trailers})` writes one chunk; `fin`
  also writes the size-0 terminator and `{fin, Trailers}` writes the
  terminator followed by the given trailer headers (RFC 7230 §4.1.2).
  Trailer names should be advertised in the response's `Trailer`
  header.
- `{sendfile, StatusCode, Headers, {Filename, Offset, Length}}` —
  zero-copy file body. The connection emits status + headers
  verbatim (the handler is responsible for `Content-Length` and
  `Content-Type`), then dispatches `file:sendfile/5` for plain TCP
  (kernel-space copy) or a chunked read+send loop for TLS (where
  the kernel sendfile path can't see plaintext). Used by
  `roadrunner_static` so large assets don't get copied through the
  Erlang heap.
- `{loop, StatusCode, Headers, State}` — message-driven streaming.
  The connection emits status + headers, then enters a receive loop
  in the conn process. Each Erlang message is dispatched through the
  optional `handle_info/3` callback, which can call `Push(Data)` to
  emit a chunk. Returning `{stop, _}` writes the size-0 terminator
  and closes. Useful for SSE/long-poll endpoints that subscribe to a
  pubsub topic in `handle/1` and forward messages to the wire.
- `{websocket, Module, State}` — upgrade to a `roadrunner_ws_handler`.

If the handler did not call `roadrunner_req:read_body/1,2`, just thread
the original `Req` back. Idiomatic shape:

```erlang
handle(Req) ->
    {{200, [], ~"hello"}, Req}.

handle(Req) ->
    {ok, Body, Req2} = roadrunner_req:read_body(Req),
    {{200, [], Body}, Req2}.
```
""".

-export_type([send_fun/0, stream_fun/0, push_fun/0, sendfile_spec/0, response/0, result/0]).

-type send_fun() ::
    fun((iodata(), nofin | fin | {fin, roadrunner_http1:headers()}) -> ok | {error, term()}).
-type stream_fun() :: fun((send_fun()) -> any()).
-type push_fun() :: fun((iodata()) -> ok | {error, term()}).
-type sendfile_spec() :: {
    Filename :: file:filename_all(),
    Offset :: non_neg_integer(),
    Length :: non_neg_integer()
}.
-type response() ::
    {StatusCode :: roadrunner_http1:status(), roadrunner_http1:headers(), Body :: iodata()}
    | {stream, StatusCode :: roadrunner_http1:status(), roadrunner_http1:headers(), stream_fun()}
    | {loop, StatusCode :: roadrunner_http1:status(), roadrunner_http1:headers(), State :: term()}
    | {sendfile, StatusCode :: roadrunner_http1:status(), roadrunner_http1:headers(),
        sendfile_spec()}
    | {websocket, Module :: module(), State :: term()}.
-type result() :: {response(), roadrunner_http1:request()}.

-callback handle(Request :: roadrunner_http1:request()) -> result().
-callback handle_info(Info :: term(), Push :: push_fun(), State :: term()) ->
    {ok, NewState :: term()} | {stop, NewState :: term()}.

-optional_callbacks([handle_info/3]).
