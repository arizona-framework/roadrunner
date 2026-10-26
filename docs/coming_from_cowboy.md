# Coming from Cowboy

This guide is for Erlang developers who know [Cowboy](https://ninenines.eu/)
2.x and want to move an app to Roadrunner. It goes concept by concept: a
short Cowboy snippet, the same thing in Roadrunner, and the differences worth
knowing.

Many ideas carry over unchanged: listeners, a route table, handler modules,
`Req` threaded through your code, loop handlers, and WebSocket handlers. The
main change is how a handler answers. A Cowboy handler calls
`cowboy_req:reply/4` to send the response. A Roadrunner handler returns the
response as a value, and Roadrunner sends it.

## At a glance

| Cowboy | Roadrunner |
|---|---|
| `cowboy:start_clear/3`, `cowboy:start_tls/3` | `roadrunner:start_listener/2` |
| `cowboy:stop_listener/1` | `roadrunner:stop_listener/1`, or `roadrunner_listener:drain/2` |
| `cowboy_router:compile/1` | the listener's `routes` list |
| `cowboy:set_env(Name, dispatch, D)` | `roadrunner_listener:reload_routes/2` |
| `cowboy_handler`, `init/2` | `roadrunner_handler`, `handle/1` |
| `cowboy_req` | `roadrunner_req` (read) and `roadrunner_resp` (build responses) |
| `cowboy_req:stream_reply/3` + `stream_body/3` | a `{stream, ...}` response |
| `cowboy_req:reply/4` or `inform/3` while the handler runs | a `{respond, ...}` response and `roadrunner_respond` |
| `cowboy_loop` | a `{loop, ...}` response plus `handle_info/3` |
| `cowboy_websocket` | `roadrunner_ws_handler` |
| `cowboy_static` | `roadrunner_static` |
| `middlewares` and `stream_handlers` | `roadrunner_middleware` |
| `cowboy_compress_h` | `roadrunner_compress` middleware |
| `cowboy_metrics_h` | an event handler (`roadrunner_event_handler`) |

## Starting a listener

In Cowboy you compile the routes, then start a Ranch listener with transport
options and protocol options.

```erlang
Dispatch = cowboy_router:compile([
    {'_', [{"/", hello_handler, []}]}
]),
{ok, _} = cowboy:start_clear(my_http_listener,
    [{port, 8080}],
    #{env => #{dispatch => Dispatch}}
).
```

In Roadrunner one options map holds everything, routes included:

```erlang
{ok, _} = application:ensure_all_started(roadrunner),
{ok, _} = roadrunner:start_listener(my_http_listener, #{
    port => 8080,
    routes => [{~"/", hello_handler, []}]
}).
```

For TLS, Cowboy has `cowboy:start_tls/3`, and HTTP/2 is offered through ALPN:

```erlang
{ok, _} = cowboy:start_tls(my_https_listener,
    [
        {port, 8443},
        {certfile, "/path/to/certfile"},
        {keyfile, "/path/to/keyfile"}
    ],
    #{env => #{dispatch => Dispatch}}
).
```

Roadrunner uses the same `start_listener/2` with a `tls` list of `ssl` server
options. List the protocols you want; ALPN is set up from `protocols`:

```erlang
{ok, _} = roadrunner:start_listener(my_https_listener, #{
    port => 8443,
    protocols => [http1, http2, http3],
    tls => [{certfile, "/path/to/certfile"}, {keyfile, "/path/to/keyfile"}],
    routes => [{~"/", hello_handler, []}]
}).
```

Common Ranch and Cowboy options and where they live in Roadrunner:

| Cowboy / Ranch | Roadrunner |
|---|---|
| `{port, P}` | `port => P` |
| `{ip, IP}` | `ip => IP` |
| `{backlog, N}` | `socket_backlog => N` |
| `num_acceptors` | `num_acceptors` |
| `max_connections` | `max_clients` |
| TLS options in the transport options | `tls => [...]` |
| `max_keepalive` | `max_keep_alive_requests` |
| `stream_handlers`, `middlewares` | `middlewares` |

Notable differences:

- `protocols` defaults to `[http1]`, so list `http2` (and `http3`) to serve them
- `max_clients` closes a connection over the cap right away, where Ranch's
  `max_connections` leaves it waiting in the backlog; its default is 16384,
  not 1024
- HTTP/3 needs `tls` and runs over UDP on the same port number
- Without `tls`, a listener serves either HTTP/1.1 or HTTP/2 (prior
  knowledge), not both
- A listener with `tls` starts `ssl` itself; add `ssl` to your application's
  `applications` list so releases include it
- To stop gracefully, `roadrunner_listener:drain/2` stops accepting, lets open
  requests finish up to a deadline, then stops the listener
- Every option is listed in `t:roadrunner_listener:opts/0`

## Routing

Cowboy routes by host first, then by path. Bindings use `:name`, and
`[...]` takes the rest of the path.

```erlang
Dispatch = cowboy_router:compile([
    {'_', [
        {"/", index_handler, #{}},
        {"/users/:id", user_handler, #{}},
        {"/files/[...]", files_handler, #{}}
    ]}
]),
```

```erlang
Id = cowboy_req:binding(id, Req),
Rest = cowboy_req:path_info(Req).
```

Roadrunner routes on the path only. `:name` binds one segment, and
`*name` binds the rest of the path as a list of segments (which can be
empty):

```erlang
routes => [
    {~"/", index_handler, #{}},
    {~"/users/:id", user_handler, #{}},
    {~"/files/*rest", files_handler, #{}}
]
```

```erlang
#{~"id" := Id} = roadrunner_req:bindings(Req),
Rest = maps:get(~"rest", roadrunner_req:bindings(Req)).
```

The third element of a route is its state. Cowboy passes it as the second
argument of `init/2`; Roadrunner puts it on the request, read with
`roadrunner_req:state/1`.

The map form of a route adds per-route options: allowed `methods` (other
methods get `405` with an `Allow` header), `middlewares`, `max_content_length`,
and `rate_limit`:

```erlang
routes => [
    #{path => ~"/users", handler => users_index, methods => [~"GET"]},
    #{path => ~"/users", handler => users_create, methods => [~"POST"]},
    #{path => ~"/admin", handler => admin_handler, middlewares => [auth_mw]}
]
```

Notable differences:

- Binding names are binaries (`~"id"`), not atoms
- There is no host matching. If you route by host, read the `host` header in
  a handler or middleware
- There are no optional segments (`[page/:number]`). Write one route per
  shape, for example `/hats` and `/hats/page/:number`
- There are no constraints. Check and convert bindings in the handler
- Routes are tried top to bottom. A route that can never match, because the
  routes above it already answer its path and methods, stops the listener from
  starting
- To change routes on a running listener, call
  `roadrunner_listener:reload_routes/2` with the new list
- For a listener with one handler and no router, pass `routes => Mod` (or
  `{Mod, State}`)

## Handlers

A Cowboy handler gets `Req` and its state, sends a reply, and returns
`{ok, Req, State}`:

```erlang
-module(hello_handler).
-behavior(cowboy_handler).
-export([init/2]).

init(Req0, State) ->
    Req = cowboy_req:reply(200, #{
        <<"content-type">> => <<"text/plain">>
    }, <<"Hello World!">>, Req0),
    {ok, Req, State}.
```

A Roadrunner handler gets the request and returns `{Response, Req}`:

```erlang
-module(hello_handler).
-behaviour(roadrunner_handler).
-export([handle/1]).

handle(Req) ->
    {{200, [{~"content-type", ~"text/plain"}], ~"Hello World!"}, Req}.
```

Notable differences:

- `handle/1` takes one argument; read the route state with
  `roadrunner_req:state(Req)`
- The response is the return value. Nothing is sent until the handler returns
- Response headers are a list of `{Name, Value}` pairs, not a map. Names must
  be lowercase, as in Cowboy
- Always return the latest `Req` (the one from `read_body/1` if you read the
  body)
- There is no `terminate/3` callback
- An optional `init_route/1` runs once per route when the routes compile
  (and again on `reload_routes/2`), to check and prepare the route's state;
  its return is what `roadrunner_req:state/1` gives the handler
- Where Cowboy switches with `{cowboy_websocket, Req, State}` or
  `{cowboy_loop, Req, State}`, Roadrunner returns a `{websocket, ...}` or
  `{loop, ...}` response (see below)

## Reading the request

Most `cowboy_req` readers have a `roadrunner_req` function with the same
name.

| Cowboy | Roadrunner |
|---|---|
| `cowboy_req:method(Req)` | `roadrunner_req:method(Req)` |
| `cowboy_req:version(Req)` | `roadrunner_req:version(Req)`, a tuple such as `{1, 1}` or `{2, 0}` |
| `cowboy_req:path(Req)` | `roadrunner_req:path(Req)` |
| `cowboy_req:qs(Req)` | `roadrunner_req:qs(Req)` |
| `cowboy_req:parse_qs(Req)` | `roadrunner_req:parse_qs(Req)` |
| `cowboy_req:binding(id, Req)` | `maps:get(~"id", roadrunner_req:bindings(Req))` |
| `cowboy_req:bindings(Req)` | `roadrunner_req:bindings(Req)` |
| `cowboy_req:path_info(Req)` | the `*name` binding |
| `cowboy_req:header(<<"user-agent">>, Req)` | `roadrunner_req:header(~"user-agent", Req)` |
| `cowboy_req:headers(Req)` | `roadrunner_req:headers(Req)`, a list of `{Name, Value}` |
| `cowboy_req:parse_cookies(Req)` | `roadrunner_req:parse_cookies(Req)` |
| `cowboy_req:has_body(Req)` | `roadrunner_req:has_body(Req)` (with `body_buffering => manual`, `false` until the body is read) |
| `cowboy_req:read_body(Req)` | `roadrunner_req:read_body(Req)` |
| `cowboy_req:read_urlencoded_body(Req)` | `roadrunner_req:read_form(Req)` |
| `cowboy_req:peer(Req)` | `roadrunner_req:peer(Req)` |
| `cowboy_req:scheme(Req)` | `roadrunner_req:scheme(Req)`, the atom `http` or `https` |
| `cowboy_req:host(Req)` | `roadrunner_req:header(~"host", Req)` |

For example, reading a query parameter with a default and a form body:

```erlang
init(Req0, State) ->
    QsVals = cowboy_req:parse_qs(Req0),
    Lang = proplists:get_value(<<"lang">>, QsVals, <<"en-US">>),
    {ok, KeyValues, Req} = cowboy_req:read_urlencoded_body(Req0),
    ...
```

```erlang
handle(Req0) ->
    Lang =
        case lists:keyfind(~"lang", 1, roadrunner_req:parse_qs(Req0)) of
            {_, L} -> L;
            false -> ~"en-US"
        end,
    {ok, urlencoded, KeyValues, Req} = roadrunner_req:read_form(Req0),
    ...
```

Notable differences:

- `parse_qs/1` and `parse_cookies/1` return the same kind of list as in
  Cowboy, with `true` for a query flag that has no value
- `header/2` matches the name in any case
- There is no `header/3` with a default; `header/2` returns `undefined` when
  the header is missing
- `host` is the raw header value, so it can include the port. On HTTP/2 and
  HTTP/3 the `:authority` pseudo-header is passed on as `host`
- `read_form/1` reads both `application/x-www-form-urlencoded` and
  `multipart/form-data` bodies, and returns `{ok, urlencoded, Pairs, Req}` or
  `{ok, multipart, Parts, Req}`
- By default the whole body is read before the handler runs, up to
  `max_content_length`. Set `body_buffering => manual` to read it yourself
  with `read_body/2` and its `length` option
- The request is a map, like Cowboy's. You can match on it
  (`#{method := ~"GET"} = Req`), but the `roadrunner_req` functions are the
  supported way to read it
- Behind a proxy, set the listener's `real_ip` (or `proxy_protocol`) option
  and use `roadrunner_req:client_ip/1`

## Responses

Cowboy sends with `reply/2,3,4` and sets headers and cookies on `Req` first:

```erlang
Req1 = cowboy_req:set_resp_header(<<"x-request-source">>, <<"guide">>, Req0),
Req2 = cowboy_req:set_resp_cookie(<<"sessionid">>, SessionID, Req1,
    #{max_age => 3600, path => <<"/">>, http_only => true, secure => true}),
Req = cowboy_req:reply(200, #{
    <<"content-type">> => <<"text/plain">>
}, <<"welcome">>, Req2),
{ok, Req, State}.
```

Roadrunner builds the response value. `roadrunner_resp` has builders for
common cases, and `add_header/3` and `set_cookie/4` add to a response:

```erlang
Resp0 = roadrunner_resp:text(200, ~"welcome"),
Resp1 = roadrunner_resp:add_header(Resp0, ~"x-request-source", ~"guide"),
Resp = roadrunner_resp:set_cookie(Resp1, ~"sessionid", SessionID, #{
    max_age => 3600, path => ~"/", http_only => true, secure => true
}),
{Resp, Req}.
```

Other buffered responses:

```erlang
%% Each line is a possible return from handle/1
{roadrunner_resp:json(200, #{id => 42}), Req}
{roadrunner_resp:redirect(303, ~"https://ninenines.eu"), Req}
{roadrunner_resp:status(204), Req}
{roadrunner_resp:not_found(), Req}
{{200, [{~"content-type", ~"text/html"}], Html}, Req}
```

The cookie options (`max_age`, `domain`, `path`, `secure`, `http_only`,
`same_site`) have the same names as Cowboy's. Without `path`, no `Path`
attribute is sent, so set `path => ~"/"` for a site-wide cookie.

### Streaming

Cowboy streams with `stream_reply` and `stream_body`:

```erlang
Req = cowboy_req:stream_reply(200, #{
    <<"content-type">> => <<"text/html">>
}, Req0),
cowboy_req:stream_body("<html><head>Hello world!</head>", nofin, Req),
cowboy_req:stream_body("<body><p>Hats off!</p></body></html>", fin, Req),
{ok, Req, State}.
```

Roadrunner returns a `{stream, Status, Headers, Fun}` response. It calls
`Fun(Send)`, and `Send` writes one part:

```erlang
handle(Req) ->
    Fun = fun(Send) ->
        ok = Send(~"<html><head>Hello world!</head>", nofin),
        ok = Send(~"<body><p>Hats off!</p></body></html>", fin)
    end,
    {{stream, 200, [{~"content-type", ~"text/html"}], Fun}, Req}.
```

Where Cowboy uses `cowboy_req:stream_trailers/2`, end with
`Send(Data, {fin, Trailers})`.

### Loop handlers

A Cowboy loop handler gets Erlang messages in `info/3`:

```erlang
init(Req, State) ->
    Req2 = cowboy_req:stream_reply(200, Req),
    {cowboy_loop, Req2, State}.

info(eof, Req, State) ->
    {stop, Req, State};
info({event, Data}, Req, State) ->
    cowboy_req:stream_body(Data, nofin, Req),
    {ok, Req, State};
info(_Msg, Req, State) ->
    {ok, Req, State}.
```

In Roadrunner, return `{loop, Status, Headers, State}` and export
`handle_info/3`. Each message comes with a `Push` function that writes one
part:

```erlang
handle(Req) ->
    ok = my_pubsub:subscribe(self(), events),
    {{loop, 200, [{~"content-type", ~"text/event-stream"}], #{}}, Req}.

handle_info(eof, _Push, State) ->
    {stop, State};
handle_info({event, Data}, Push, State) ->
    _ = Push(roadrunner_sse:event(Data)),
    {ok, State};
handle_info(_Msg, _Push, State) ->
    {ok, State}.
```

The status and headers go out when the loop starts. Keep a catch-all clause:
Roadrunner also sends `{roadrunner_disconnect, Reason}` when the client goes
away and `{roadrunner_drain, Deadline}` when the listener drains, so a
long-lived response can end cleanly. `roadrunner_sse` builds Server-Sent
Events frames for `Push`.

### Sending files

Cowboy takes a `{sendfile, Offset, Length, Filename}` body. Roadrunner has a
`{sendfile, Status, Headers, {Filename, Offset, Length}}` response. Set
`content-length` and `content-type` yourself:

```erlang
handle(Req) ->
    File = filename:join(code:priv_dir(my_app), "static/index.html"),
    Size = filelib:file_size(File),
    Headers = [
        {~"content-type", ~"text/html"},
        {~"content-length", integer_to_binary(Size)}
    ],
    {{sendfile, 200, Headers, {File, 0, Size}}, Req}.
```

### Sending the response as the handler runs

Some Cowboy handlers send while they work: an `inform/3` first, then the
reply, chosen as the code goes. Return `{respond, Headers, Fun}` for that.
Roadrunner calls `Fun(Req)`, and the fun sends with `roadrunner_respond`, in
the same order as Cowboy's calls, with `Req` last:

```erlang
handle(Req) ->
    {{respond, [], fun respond/1}, Req}.

respond(Req0) ->
    ok = roadrunner_respond:inform(103, [{~"link", ~"</app.css>; rel=preload"}], Req0),
    {ok, Body, Req} = roadrunner_req:read_body(Req0),
    ok = roadrunner_respond:reply(200, [{~"content-type", ~"text/plain"}], Body, Req),
    Req.
```

`roadrunner_respond:stream/3` returns the same `Send` as a `{stream, ...}`
response, and `sendfile/4` sends a file. The fun returns the request, the
last one it got from `roadrunner_req`.

## Middlewares and stream handlers

A Cowboy middleware runs between the router and the handler. To answer early
it replies and returns `{stop, Req}`:

```erlang
-module(auth_mw).
-behaviour(cowboy_middleware).
-export([execute/2]).

execute(Req, Env) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        undefined -> {stop, cowboy_req:reply(401, Req)};
        _ -> {ok, Req, Env}
    end.
```

```erlang
#{
    env => #{dispatch => Dispatch},
    middlewares => [cowboy_router, auth_mw, cowboy_handler]
}
```

A Roadrunner middleware gets the request and a `Next` function that runs the
rest of the pipeline. To answer early, return a response without calling
`Next`:

```erlang
-module(auth_mw).
-behaviour(roadrunner_middleware).
-export([call/3]).

call(Req, Next, _State) ->
    case roadrunner_req:header(~"authorization", Req) of
        undefined -> {roadrunner_resp:unauthorized(), Req};
        _ -> Next(Req)
    end.
```

```erlang
middlewares => [auth_mw]
```

Put `middlewares` on the listener to wrap every route, or on a map-form route
to wrap only that route. Listener middlewares run outside route middlewares,
and the first entry in a list runs outermost. A fun works too:
`{fun ?MODULE:auth/3, State}`. A module can export an optional `init/1` that
turns its config into state once, when the listener starts.

Because a middleware gets the response back from `Next`, it can also do the
jobs Cowboy gives to stream handlers that change responses. For example,
`cowboy_compress_h`:

```erlang
#{
    env => #{dispatch => Dispatch},
    stream_handlers => [cowboy_compress_h, cowboy_stream_h]
}
```

```erlang
middlewares => [roadrunner_compress]
```

Notable differences:

- A middleware can change the response after `Next(Req)` returns. Match the
  buffered shape with a guard such as `{{Status, Headers, Body}, Req2} when
  is_integer(Status)`, and pass other responses (stream, loop, WebSocket)
  through
- Middlewares never write to the socket; they always return a response
- Middlewares run once a route matches. The router's own `404` and `405`
  answers do not go through them
- Other built-in middlewares: `roadrunner_etag`, `roadrunner_security_headers`,
  and `roadrunner_cors`
- Real client IP and per-client rate limits are listener options
  (`real_ip`, `proxy_protocol`, `rate_limit`), and `rate_limit` is also a
  per-route option

## WebSockets

A Cowboy WebSocket handler switches in `init/2` and then gets frames and
messages:

```erlang
-module(echo_ws).
-behaviour(cowboy_websocket).
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

init(Req, State) ->
    {cowboy_websocket, Req, State}.

websocket_init(State) ->
    {[{text, <<"Hello!">>}], State}.

websocket_handle(Frame = {text, _}, State) ->
    {[Frame], State};
websocket_handle(_Frame, State) ->
    {[], State}.

websocket_info({log, Text}, State) ->
    {[{text, Text}], State};
websocket_info(_Info, State) ->
    {[], State}.
```

In Roadrunner a handler returns `{websocket, Module, State}`, and `Module`
implements `roadrunner_ws_handler`. One module can be both:

```erlang
-module(echo_ws).
-behaviour(roadrunner_handler).
-behaviour(roadrunner_ws_handler).
-export([handle/1, init/1, handle_frame/2, handle_info/2]).

handle(Req) ->
    {{websocket, ?MODULE, #{}}, Req}.

init(State) ->
    {reply, [{text, ~"Hello!"}], State}.

handle_frame(#{opcode := text, payload := Text}, State) ->
    {reply, [{text, Text}], State};
handle_frame(_Frame, State) ->
    {ok, State}.

handle_info({log, Text}, State) ->
    {reply, [{text, Text}], State};
handle_info(_Info, State) ->
    {ok, State}.
```

| Cowboy | Roadrunner |
|---|---|
| `init/2` returning `{cowboy_websocket, Req, State}` | `handle/1` returning `{{websocket, Mod, State}, Req}` |
| `websocket_init/1` | `init/1` (optional) |
| `websocket_handle/2` | `handle_frame/2`, with a frame map |
| `websocket_info/2` | `handle_info/2` (optional) |
| `terminate/3` | none |
| `{Frames, State}` | `{reply, Frames, State}` |
| `{[], State, hibernate}` | `{ok, State, [hibernate]}` |
| `{[{close, 1000, Reason}], State}` | `{close, 1000, Reason, State}` |
| `{stop, State}` (closes with code 1000) | `{close, 1000, ~"", State}`, or `{close, State}` for a close frame with no code |

Notable differences:

- `handle_frame/2` gets a map such as `#{opcode := text, payload := Bin}`.
  Fragmented messages arrive whole, and ping, pong, and close are handled for
  you, so they never reach the handler
- To refuse the upgrade, return a normal response from `handle/1` instead
- To add headers to the `101` (a `sec-websocket-protocol` or a cookie), return
  `{websocket, Mod, State, Headers}`
- `permessage-deflate` is used when the client asks for it; there is no
  `compress` option to set
- Frame and message size limits are listener options under `ws`
  (`max_frame_size`, `max_message_size`), not per upgrade
- An optional `handle_drain/2` callback runs when the listener drains
- The upgrade runs over HTTP/1.1

## Static files

Cowboy serves a directory or a single file with `cowboy_static`:

```erlang
{"/assets/[...]", cowboy_static, {priv_dir, my_app, "static/assets"}},
{"/assets/[...]", cowboy_static, {dir, "/var/www/assets"}},
{"/", cowboy_static, {priv_file, my_app, "static/index.html"}},
{"/favicon.ico", cowboy_static, {file, "/var/www/favicon.ico"}}
```

Roadrunner uses `roadrunner_static` with a `dir` or a `file` option. A path in
your application's `priv` directory is written `{priv, App, SubPath}`. A
directory route needs a wildcard named `*path`:

```erlang
{~"/assets/*path", roadrunner_static, #{dir => {priv, my_app, ~"static/assets"}}},
{~"/assets/*path", roadrunner_static, #{dir => ~"/var/www/assets"}},
{~"/", roadrunner_static, #{file => {priv, my_app, ~"static/index.html"}}},
{~"/favicon.ico", roadrunner_static, #{file => ~"/var/www/favicon.ico"}}
```

| Cowboy | Roadrunner |
|---|---|
| `{dir, Path}` | `#{dir => Path}` |
| `{priv_dir, App, Path}` | `#{dir => {priv, App, Path}}` |
| `{file, Path}` | `#{file => Path}` |
| `{priv_file, App, Path}` | `#{file => {priv, App, Path}}` |
| the `{mimetypes, Module, Function}` extra | `#{mime_types => #{Ext => Type}}` |

Notable differences:

- The options are checked when the listener starts. A missing application,
  an unknown option, or a bad value stops the start with an error naming the
  option, instead of failing on a request
- `ETag`, `Last-Modified`, and `Range` are built in
- Precompressed `.br` and `.gz` files next to the original are served when
  the client accepts them
- Other options: `cache_control` (a `Cache-Control` value),
  `symlink_policy` (directory routes only), and `cache_ttl_ms`
- The content type comes from a built-in table of common web types (pages,
  scripts, styles, images, fonts, `.wasm`, media, and more); anything else is
  `application/octet-stream`. `mime_types` adds types or overrides built-in
  ones for a route, with keys such as `~".glb"` in any case
- There is no `etag` option to change how the `ETag` is built

## Events and observability

Cowboy collects metrics with the `cowboy_metrics_h` stream handler and a
callback:

```erlang
#{
    env => #{dispatch => Dispatch},
    stream_handlers => [cowboy_metrics_h, cowboy_stream_h],
    metrics_callback => fun(Metrics) -> my_metrics:record(Metrics) end
}
```

Roadrunner hands its request, connection, and WebSocket events to one event
handler per node, a module with `handle_event/2`. Set it in `sys.config`:

```erlang
[{roadrunner, [{event_handler, my_events}]}].
```

Roadrunner has no telemetry dependency. To keep using `telemetry` (for
example, handlers you attached for Cowboy, `telemetry_metrics`, Prometheus,
or OpenTelemetry), add
[`roadrunner_telemetry`](https://github.com/arizona-framework/roadrunner_telemetry)
to your deps and make it the event handler. It turns every Roadrunner event
into a `telemetry` event, such as `[roadrunner, request, stop]`, following the
`telemetry` span convention:

```erlang
[{roadrunner, [{event_handler, roadrunner_telemetry}]}].
```

To handle only the events you need, write your own event handler instead,
for example one that forwards to `telemetry` itself:

```erlang
-module(my_events).
-behaviour(roadrunner_event_handler).
-export([handle_event/2]).

handle_event(request_start, Req) ->
    {erlang:monotonic_time(), roadrunner_req:method(Req)};
handle_event(request_stop, {{Start, Method}, Status, _Kind}) ->
    telemetry:execute(
        [my_app, request, stop],
        #{duration => erlang:monotonic_time() - Start},
        #{method => Method, status => Status}
    );
handle_event(_Event, _Args) ->
    ok.
```

What `handle_event/2` returns for `request_start` comes back as the first
element of `request_stop`, so you keep only what you need. The default
handler, `roadrunner_event_noop`, drops every event. End `handle_event/2`
with a catch-all clause, since new events can be added. See
`roadrunner_event_handler` for the full list of events.

Router `404` and `405` answers fire no `request_start` or `request_stop`. If
your metrics count them, as `cowboy_metrics_h` does, add a catch-all route
such as `{~"/*path", not_found_handler, []}` at the end of your routes. That
handler then also gets requests whose method a route does not allow, so it
answers those instead of the router's `405`.

Each request also sets a `request_id` in the `logger` process metadata, and
`roadrunner_listener:info/1` returns live counters such as `active_clients`
and `requests_served`.

## No direct equivalent

Some Cowboy features have no Roadrunner counterpart. Here is the usual way to
cover each one.

- **`cowboy_rest`**: there is no REST state machine. Write a plain handler
  that matches on the method, and use the map route's `methods` for `405`
  answers, `roadrunner_etag` for `ETag` and `304`, `roadrunner_cors` for CORS,
  and your own middleware for shared steps such as authentication
- **Host matching, optional segments, and constraints** in routes: read the
  `host` header, write one route per shape, and check bindings in the handler
- **`match_qs/2`, `match_cookies/2`, `parse_header/2`**: read the list from
  `parse_qs/1` or `parse_cookies/1`, or the raw value from `header/2`, and
  convert it in your code
- **`cowboy_req:push/3,4`** (HTTP/2 server push): not available
- **`read_part/1` and `read_part_body/1`** (reading multipart one part at a
  time): `read_form/1` parses a multipart body after reading all of it
- **`cowboy_req:cast/2`** (messages to stream handlers): there are no stream
  handlers. To read a body piece by piece, use `body_buffering => manual` and
  `read_body/2` with `length`
- **Loop handler timeouts** (`{cowboy_loop, Req, State, Timeout}`): start a
  timer with `erlang:send_after/3` in `handle/1`, and cancel and restart it in
  `handle_info/3` on each message to match Cowboy's idle timeout.
  `{cowboy_loop, Req, State, hibernate}` has no equivalent
- **`cowboy_decompress_h`** and **`cowboy_tracer_h`**: no built-in version;
  a middleware can cover your own cases
- **`terminate/3`** in handlers and WebSocket handlers: there is no such
  callback
- **WebSocket idle timeout** (`idle_timeout`): there is no option for it
- **WebSockets over HTTP/2 and HTTP/3**: a `{websocket, ...}` response on
  those protocols answers `501`; WebSocket clients connect over HTTP/1.1
- **`cowboy_req:cert/1`, `sock/1` and `port/1`** (TLS client certificate,
  local address, port): no reader for them. The port can be read from the
  `host` header
- **Middleware `{suspend, M, F, A}`**: not available
- **`cowboy:set_env/3`** for values other than routes: keep them in your own
  application env or in route state

## Checklist

- Swap the `cowboy` dep for `roadrunner` and add `ssl` to `applications` if
  you serve TLS
- Replace `cowboy:start_clear/3` and `cowboy:start_tls/3` with
  `roadrunner:start_listener/2`, and list `http2` (and `http3`) in `protocols`
- Turn the dispatch rules into a `routes` list: binary paths, `*name` for
  `[...]`, no host level
- Change binding lookups from atom keys to binary keys
- Rewrite each `init/2` as `handle/1` that returns `{Response, Req}`
- Replace `cowboy_req:reply/4` calls with response tuples or `roadrunner_resp`
  builders, and response header maps with lists. Code that has to send as it
  runs, or sends `inform/3`, moves to a `{respond, ...}` response
- Move `set_resp_header` and `set_resp_cookie` to `roadrunner_resp:add_header/3`
  and `roadrunner_resp:set_cookie/4`
- Turn `stream_reply` code into `{stream, ...}` responses and `cowboy_loop`
  handlers into `{loop, ...}` responses with `handle_info/3`
- Port WebSocket handlers to `roadrunner_ws_handler`
- Move `cowboy_middleware` modules and response-changing stream handlers to
  `roadrunner_middleware`
- Point `cowboy_static` routes at `roadrunner_static` with a `*path` wildcard
- Replace `cowboy_metrics_h` with an event handler, or set
  `roadrunner_telemetry` as the event handler to keep your telemetry handlers
