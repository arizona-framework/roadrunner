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
  in one shot. Without a `content-length` or `transfer-encoding`
  header, HTTP/1.1 adds `content-length` from the body (HTTP/2 and
  HTTP/3 frame the body themselves).
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
- `{websocket, Module, State, Headers}` — the same upgrade, with `Headers`
  added to the `101 Switching Protocols` response (e.g. a `set-cookie`).
  The handshake's own headers (`upgrade`, `connection`,
  `sec-websocket-accept`, `sec-websocket-extensions`) win: an entry
  naming one of them is dropped, as is a `content-length` or
  `transfer-encoding`, which a 1xx response must not carry.

If the handler did not call `roadrunner_req:read_body/1,2`, just thread
the original `Req` back. Idiomatic shape:

```erlang
handle(Req) ->
    {{200, [], ~"hello"}, Req}.

handle(Req) ->
    {ok, Body, Req2} = roadrunner_req:read_body(Req),
    {{200, [], Body}, Req2}.
```

## init_route/1: optional setup when the routes compile

A handler **may** implement `init_route/1`. It runs once per route that
names the handler, when the listener starts and again on every
`roadrunner_listener:reload_routes/2`, never per request. It gets the
route's state and its return becomes the state the handler reads with
`roadrunner_req:state/1`:

```erlang
init_route(Opts) -> State.  %% once per route, when the routes compile
handle(Req) -> Result.      %% per request, roadrunner_req:state(Req) is State
```

Check the route's options and precompute there: a bad option then stops
the listener from starting instead of failing a request, and the work is
paid once. `roadrunner_static` uses it this way. It is the handler's
counterpart of a middleware's `init/1`; the name differs because a module
can also be a `roadrunner_ws_handler`, whose `init/1` runs per WebSocket
session.
""".

-export_type([send_fun/0, stream_fun/0, push_fun/0, sendfile_spec/0, response/0, result/0]).

-doc """
The chunk-writing callback handed to a `t:stream_fun/0`. Each call
emits one chunk on the wire:

- `Send(Data, nofin)` — write `Data` and expect more.
- `Send(Data, fin)` — write `Data` then the size-0 terminator.
- `Send(Data, {fin, Trailers})` — write `Data`, the terminator, and
  serialized trailer headers (RFC 9112 §7.1.2).

Returns `ok` on success or `{error, Reason}` if the wire write
failed (peer close, kernel error, etc.).
""".
-type send_fun() ::
    fun((iodata(), nofin | fin | {fin, roadrunner_http:headers()}) -> ok | {error, term()}).

-doc """
The stream callback for `{stream, _, _, Fun}` responses. The
framework calls `Fun(Send)` with a `t:send_fun/0`; the fun emits
chunks via `Send` and returns when the stream is complete.
""".
-type stream_fun() :: fun((send_fun()) -> any()).

-doc """
The push callback handed to a `{loop, _, _, State}` handler via
`handle_info/3`. Each call writes one chunk to the wire.
""".
-type push_fun() :: fun((iodata()) -> ok | {error, term()}).

-doc """
The `{Filename, Offset, Length}` triple for a `{sendfile, _, _, _}`
response. Bytes `[Offset, Offset+Length)` of the file are emitted
verbatim — the handler is responsible for setting `Content-Length`
and `Content-Type` headers on the response.
""".
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

Over HTTP/2 and HTTP/3, a client can tell the server the most header
bytes it will take (`SETTINGS_MAX_HEADER_LIST_SIZE` on HTTP/2, RFC 9113
§6.5.2, `SETTINGS_MAX_FIELD_SECTION_SIZE` on HTTP/3, RFC 9114 §4.2.2,
both counted as name + value + 32 per field, `:status` and the auto
headers such as `date` included), and the server keeps to it. A response
whose headers are over it is answered `500` instead, before anything is
sent, the error is logged and telemetry reports the `500`. Trailers over
it come after the status is sent, so the stream is reset instead.
""".
-type response() ::
    {StatusCode :: roadrunner_http:status(), roadrunner_http:headers(), Body :: iodata()}
    | {stream, StatusCode :: roadrunner_http:status(), roadrunner_http:headers(), stream_fun()}
    | {loop, StatusCode :: roadrunner_http:status(), roadrunner_http:headers(), State :: term()}
    | {sendfile, StatusCode :: roadrunner_http:status(), roadrunner_http:headers(), sendfile_spec()}
    | {websocket, Module :: module(), State :: term()}
    | {websocket, Module :: module(), State :: term(), roadrunner_http:headers()}.

-doc """
What `handle/1` returns: a pair of the handler's `t:response/0` and
the (possibly mutated) request map. Threading `Req2` back lets the
conn drain unread bodies in manual-buffering mode and response
middlewares observe / rewrite.
""".
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

When the client connection goes away while the loop is still running,
the framework delivers a final `{roadrunner_disconnect, Reason}`
message through this callback so the handler can drop pubsub
subscriptions and stop work instead of discovering the dead socket on
its next push:

- `{roadrunner_disconnect, closed}` — the peer closed (or errored) the
  HTTP/1 connection.
- `{roadrunner_disconnect, reset}` — the peer cancelled this stream
  (HTTP/2 `RST_STREAM`, HTTP/3 `RESET_STREAM`).
- `{roadrunner_disconnect, conn_down}` — the owning connection process
  died (HTTP/2 / HTTP/3).

It is delivered at most once, the loop then ends regardless of the
return value (the wire is gone, so no terminator is written). A handler
that does not match it explicitly falls through to its catch-all clause;
the loop still ends.
""".
-callback handle_info(Info :: term(), Push :: push_fun(), State :: term()) ->
    {ok, NewState :: term()} | {stop, NewState :: term()}.

-doc """
Optional setup run when the routes compile. When the handler exports it,
the router calls it once for every route that names the handler, at
listener start and on every `roadrunner_listener:reload_routes/2`, never
per request. It works with every route form: the `{Path, Handler}` and
`{Path, Handler, State}` tuples, the map form, and the listener's
single-handler `routes => Handler | {Handler, State} | #{handler := Handler}`
forms.

`State` is the route's state, or `undefined` when the route sets none.
The return value replaces it: `roadrunner_req:state/1` returns it on every
request the route answers, and `roadrunner_router:match/3` reports it.

Validate options and precompute here (resolve paths, build lookup tables):
a raise stops the listener from starting. On `reload_routes/2` it refuses
the reload instead: the call returns `{error, {init_failed, Reason}}` and
the listener keeps serving its current routes. The reason is wrapped as
`{init_route_failed, Path, Handler, Reason}` so the error names the route
(`Path` is `undefined` for the single-handler forms).
`roadrunner_router:validate/1` does not run it, and `compile/2` runs it
only once the whole table has passed validation.

A handler without `init_route/1` keeps its state exactly as the route wrote
it.
""".
-callback init_route(State :: term()) -> NewState :: term().

-optional_callbacks([handle_info/3, init_route/1]).
