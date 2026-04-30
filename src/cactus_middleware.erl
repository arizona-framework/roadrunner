-module(cactus_middleware).
-moduledoc """
Continuation-style middleware for cactus handlers.

A middleware is a function that wraps the rest of the request
pipeline:

```erlang
-callback call(Request, Next) -> Response when
    Request :: cactus_http1:request(),
    Next :: fun((Request) -> Response),
    Response :: cactus_handler:response().
```

Each middleware decides:

- **pass through unchanged** — `Next(Req)`
- **transform the request** — `Next(Req#{...})`
- **short-circuit / halt** — return a `cactus_handler:response()`
  without calling `Next`
- **wrap the response** — let `Next(Req)` run, then transform what it
  returned (status, headers, body)
- **side effects around the call** — log, time, instrument

This shape is deliberately lighter than cowboy's deprecated
`(Req, Env)` middlewares (which couldn't see the response) and
much lighter than cowboy stream handlers (which split the request
lifecycle into five callbacks). It matches the modern
continuation/decorator pattern used by Plug.Builder, Express.js,
Tower, and Servant.

## Where middlewares live

- **Listener-level**: `cactus_listener:start_link(_, #{middlewares => [...]})`.
  These run for every request — single-handler and routed.
- **Per-route**: in the 3-tuple route opts under the `middlewares` key:
  `{~"/path", handler_mod, #{middlewares => [...]}}`.

When both are configured, listener middlewares wrap route middlewares
which wrap the handler — first in each list runs outermost.

## Middleware shape

Each entry in a middlewares list is one of:

- `module()` — the module's `call/2` (this behaviour callback) is invoked.
- `fun((Request, Next) -> Response)` — invoked directly.

## Examples

```erlang
%% Auth check — halt with 401 when missing.
auth(Req, Next) ->
    case cactus_req:header(~"authorization", Req) of
        undefined -> cactus_resp:unauthorized();
        _ -> Next(Req)
    end.

%% Around: time the whole request including the response write.
timing(Req, Next) ->
    Start = erlang:monotonic_time(millisecond),
    Resp = Next(Req),
    logger:info(#{took_ms => erlang:monotonic_time(millisecond) - Start}),
    Resp.

%% Inject a server header on every response.
server_header(Req, Next) ->
    {S, H, B} = Next(Req),
    {S, [{~"server", ~"cactus"} | H], B}.
```
""".

-export([compose/2]).
-export_type([middleware/0, middleware_list/0, next/0]).

-type next() :: fun((cactus_http1:request()) -> cactus_handler:response()).
-type middleware() ::
    module()
    | fun((cactus_http1:request(), next()) -> cactus_handler:response()).
-type middleware_list() :: [middleware()].

-callback call(Request :: cactus_http1:request(), Next :: next()) ->
    cactus_handler:response().

-doc """
Compose a middleware list around a handler call, returning a single
`next()` fun that runs the full pipeline.

The first middleware in the list runs **outermost** — it gets the
first crack at the request and the last crack at the response. The
handler is the innermost call; an empty list returns the handler fun
unchanged.
""".
-spec compose(middleware_list(), next()) -> next().
compose([], Handler) ->
    Handler;
compose([Mw | Rest], Handler) ->
    Inner = compose(Rest, Handler),
    fun(Req) -> apply_one(Mw, Req, Inner) end.

-spec apply_one(middleware(), cactus_http1:request(), next()) ->
    cactus_handler:response().
apply_one(Mod, Req, Next) when is_atom(Mod) ->
    Mod:call(Req, Next);
apply_one(Fun, Req, Next) when is_function(Fun, 2) ->
    Fun(Req, Next).
