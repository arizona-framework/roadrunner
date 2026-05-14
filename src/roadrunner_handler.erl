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
  terminator followed by the given trailer headers (RFC 9112 §7.1.2).
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
    fun((iodata(), nofin | fin | {fin, roadrunner_req:headers()}) -> ok | {error, term()}).
-type stream_fun() :: fun((send_fun()) -> any()).
-type push_fun() :: fun((iodata()) -> ok | {error, term()}).
-type sendfile_spec() :: {
    Filename :: file:filename_all(),
    Offset :: non_neg_integer(),
    Length :: non_neg_integer()
}.

-doc """
Handler response shape returned alongside the (mutated) request map.

Response header names MUST be ASCII lowercase. HTTP/2 requires this on the
wire per RFC 9113 §8.1.2 (clients reject responses with uppercase names);
the HTTP/1.1 path emits names verbatim, so the requirement is uniform
across protocols. Framework helpers (`roadrunner_resp:*`,
`roadrunner_compress`, the auto-injected `~"date"` header) all emit
lowercase names; handler-supplied tuples must follow suit.
""".
-type response() ::
    {StatusCode :: roadrunner_req:status(), roadrunner_req:headers(), Body :: iodata()}
    | {stream, StatusCode :: roadrunner_req:status(), roadrunner_req:headers(), stream_fun()}
    | {loop, StatusCode :: roadrunner_req:status(), roadrunner_req:headers(), State :: term()}
    | {sendfile, StatusCode :: roadrunner_req:status(), roadrunner_req:headers(), sendfile_spec()}
    | {websocket, Module :: module(), State :: term()}.
-type result() :: {response(), roadrunner_req:request()}.

-doc """
Invoked once per parsed request. Receives the request map and
returns a `{Response, Req2}` pair where `Response` is one of the
shapes listed in the moduledoc (buffered, stream, sendfile, loop,
websocket) and `Req2` is the (possibly mutated) request map threaded
back to the framework. Always return `Req2` so the conn can drain
unread bodies in manual-buffering mode and response middlewares can
observe / rewrite.
""".
-callback handle(Request :: roadrunner_req:request()) -> result().

-doc """
Optional, only fired for `{loop, _, _, State}` responses. The
framework dispatches every non-OTP Erlang message delivered to the
conn (or h2 worker) process through this callback. `Push(Data)`
writes one chunk to the wire. Return `{ok, NewState}` to keep
looping or `{stop, NewState}` to emit the size-0 terminator and
close. Handlers that don't export this callback can't use
`{loop, ...}` responses.
""".
-callback handle_info(Info :: term(), Push :: push_fun(), State :: term()) ->
    {ok, NewState :: term()} | {stop, NewState :: term()}.

-optional_callbacks([handle_info/3]).
