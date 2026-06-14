-module(roadrunner_middleware).
-moduledoc """
Continuation-style middleware for roadrunner handlers.

A middleware wraps the rest of the request pipeline:

```erlang
-callback call(Request, Next, State) -> Result when
    Request :: roadrunner_req:request(),
    Next :: fun((Request) -> Result),
    State :: state(),
    Result :: roadrunner_handler:result().
```

The pipeline (handler at its core) returns `{Response, Req2}`. Each
middleware sees the same shape and is expected to return it — either
straight from `Next` or after transforming it.

Each middleware decides:

- **pass through unchanged** — `Next(Req)`
- **transform the request** — `Next(Req#{...})`
- **short-circuit / halt** — return `{Response, Req}` without calling
  `Next`
- **wrap the response** — let `Next(Req)` run, then transform what it
  returned (status, headers, body)
- **side effects around the call** — log, time, instrument

This shape is deliberately lighter than cowboy's deprecated
`(Req, Env)` middlewares (which couldn't see the response) and
much lighter than cowboy stream handlers (which split the request
lifecycle into five callbacks). It matches the modern
continuation/decorator pattern used by Plug.Builder, Express.js,
Tower, and Servant.

## No direct wire writes from middleware

Middleware code never has access to the underlying socket — the
`Request` map intentionally excludes any socket reference. To
respond, a middleware **must** return a `Result` (either the one
from `Next(Req)` or its own response triple); there is no `reply`
escape hatch equivalent to cowboy's mid-flight `cowboy_req:reply/4`.

This is a feature, not a limitation. Bytes only hit the wire from
one place — the conn process — which means:

- `[roadrunner, request, stop]` telemetry fires for every request,
  with consistent duration and status metadata.
- gzip wrapping, response transforms, and `Content-Length` framing
  are applied uniformly regardless of which middleware produced
  the response.
- Send errors are handled in one place (`[roadrunner, response,
  send_failed]` telemetry, drain bookkeeping, slot release).
- The "halt" pattern is structurally simple: don't call `Next`, just
  return a response. There's no second halt protocol to maintain
  (compare: an arizona cowboy adapter has to support BOTH stashed
  redirects AND raw-write-from-middleware to stay backward-compatible
  with cowboy's permissiveness; the roadrunner adapter only handles
  the stashed-redirect path).

If you're porting middleware from cowboy that called
`cowboy_req:reply/4` directly, replace the call with returning a
response triple — `{Status, Headers, Body}` — from the middleware,
and the framework writes the bytes.

## Where middlewares live

- **Listener-level**: `roadrunner_listener:start_link(_, #{middlewares => [...]})`.
  These run for every request — single-handler and routed.
- **Per-route**: as the `middlewares` key on a map-shape route entry:
  `#{path => ~"/path", handler => handler_mod, middlewares => [...]}`.
  The tuple shorthands (`{Path, Handler}` /
  `{Path, Handler, State}`) intentionally cannot carry middlewares —
  use the map form when you want them.

When both are configured, listener middlewares wrap route middlewares
which wrap the handler — first in each list runs outermost.

## Middleware shape

Each entry in a middlewares list is a `Callable`, optionally paired with
its config as `{Callable, Config}`. A bare `Callable` is shorthand for
`{Callable, #{}}` (empty config), the same way a `{Path, Handler}` route
omits the state a `{Path, Handler, State}` route carries.

- `module()` / `{module(), Config}` — a module implementing this
  behaviour. Its `init(Config)` callback runs **once**, at
  pipeline-compile time, and the value it returns becomes the `State`
  handed to every `Mod:call(Req, Next, State)`. See "init/1" below.
- `fun((Request, Next, State) -> Result)` / `{Fun, State}` — a fun has no
  init step, so its paired `State` is threaded verbatim as the third
  argument: `Fun(Req, Next, State)`. Reach for a fun for lightweight
  inline middleware, a module when you want compile-time setup.

Config (module) and `State` (fun) default to `#{}` for the bare forms.
The same callable can appear more than once with different config, e.g.
`[{rate_limit, #{rps => 10}}, {rate_limit, #{rps => 100}}]`.

Middleware `State` is **not** the request's `state` field. Route state
(`{Path, Handler, State}`) is injected onto the request map and read
with `roadrunner_req:state/1`; middleware `State` is handed to `call/3`
as an argument and never touches the request.

## init/1: compile-time setup (modules only)

A module middleware **must** implement `init/1`. It runs once when the
pipeline is compiled (listener boot and every `reload_routes/2`), never
per request, and turns the user's raw config into the runtime state
`call/3` receives:

```erlang
init(Config) -> State.            %% once, at compile time
call(Req, Next, State) -> Result. %% per request, the same State reused
```

Do config validation and any precompute (compile patterns, pre-join
binaries, build lookup tables) in `init/1`: a bad config then fails
loudly at listener start rather than on a request, and the work is paid
once instead of per request. A bare `module()` entry is initialised with
`#{}`, so an `init/1` that reads an all-defaults config should accept the
empty map.

A fun-form middleware has no `init/1` (there's no module to host the
callback); its paired `State` is used as-is, so precompute it yourself or
pass a module if you want the compile-time hook.

## Examples

```erlang
%% Stateless auth check — halt with 401 when missing. Wire it as a
%% bare `fun ?MODULE:auth/3`.
auth(Req, Next, _State) ->
    case roadrunner_req:header(~"authorization", Req) of
        undefined -> {roadrunner_resp:unauthorized(), Req};
        _ -> Next(Req)
    end.

%% Around: time the whole request including the response write.
timing(Req, Next, _State) ->
    Start = erlang:monotonic_time(millisecond),
    Result = Next(Req),
    logger:info(#{took_ms => erlang:monotonic_time(millisecond) - Start}),
    Result.

%% Stateful: inject a configurable `server` header on every response.
%% Wire it as `{fun ?MODULE:server_header/3, ~"roadrunner"}`.
server_header(Req, Next, Server) ->
    {{S, H, B}, Req2} = Next(Req),
    {{S, [{~"server", Server} | H], B}, Req2}.
```
""".

-export([compose/2, build_pipeline/2, compile_pipeline/3, compile_pipeline/4, resolve/1]).
-export_type([
    middleware/0, middleware_fun/0, middleware_list/0, next/0, config/0, state/0, resolved/0
]).

-doc """
The continuation passed to a middleware's `call/3`: a fun that runs
the rest of the pipeline (other middlewares + the inner handler)
and returns the same `t:roadrunner_handler:result/0` shape every
middleware returns.
""".
-type next() :: fun((roadrunner_req:request()) -> roadrunner_handler:result()).

-doc """
A middleware entry's raw per-instance config: the second element of a
`{Callable, Config}` entry, and the `#{}` default for a bare `Callable`.
For a module it is the argument handed to `init/1`; a fun has no init, so
its config is threaded straight through as the `call/3` state. Typically a
map.
""".
-type config() :: term().

-doc """
A middleware entry's runtime state, passed as the third argument of
`call/3`. For a module entry it is whatever `init/1` returned at compile
time; for a fun entry it is the entry's `t:config/0` used verbatim.
""".
-type state() :: term().

-doc """
A middleware entry after resolution: the `{Callable, State}` pair produced
by running `resolve/1` (which calls each module's `init/1` once). Opaque —
callers thread it back into `compile_pipeline/4` without inspecting it.
""".
-opaque resolved() :: {module() | middleware_fun(), state()}.

-doc """
The function shape of a fun-form middleware: it receives the request,
the continuation, and the entry's `t:state/0`.
""".
-type middleware_fun() ::
    fun((roadrunner_req:request(), next(), state()) -> roadrunner_handler:result()).

-doc """
A single entry in a `middlewares` list: a `Callable`, or a
`{Callable, Config}` pair. `Callable` is either a module
implementing `-behaviour(roadrunner_middleware)` (its `init/1` runs at
compile time, its `call/3` per request) or a `t:middleware_fun/0` invoked
directly. The pair's second element is the entry's `t:config/0` — fed to
`init/1` for a module, used verbatim as the `call/3` state for a fun; a
bare `Callable` defaults it to `#{}`.
""".
-type middleware() ::
    module()
    | middleware_fun()
    | {module(), config()}
    | {middleware_fun(), config()}.

-doc "An ordered list of `t:middleware/0` entries.".
-type middleware_list() :: [middleware()].

-doc """
Compile-time setup. Runs **once** when the pipeline is built (listener
boot and every `roadrunner_listener:reload_routes/2`), never per request,
and turns the entry's raw `t:config/0` into the `t:state/0` handed to
every `call/3`. A bare `module()` entry is initialised with `#{}`.

This is the place for config validation and precompute (compile patterns,
pre-join binaries, build lookup tables): a bad config fails loudly at
listener start, and the work is paid once rather than per request.
""".
-callback init(Config :: config()) -> state().

-doc """
The middleware contract. `Request` is the current request map;
`Next` is a continuation that runs the rest of the pipeline (other
middlewares + the inner handler) and returns the same
`t:roadrunner_handler:result/0` shape every middleware returns. `State`
is what this entry's `init/1` returned at compile time.

The middleware decides whether to:
- pass through unchanged (`Next(Req)`),
- transform the request (`Next(Req#{...})`),
- short-circuit (return `{Response, Req}` without calling `Next`),
- wrap the response (let `Next(Req)` run, then transform what it
  returned),
- run side effects around the call (log, time, instrument).
""".
-callback call(
    Request :: roadrunner_req:request(),
    Next :: next(),
    State :: state()
) ->
    roadrunner_handler:result().

-doc """
Resolve a middleware list to its runtime `t:resolved/0` pairs, running each
module's `init/1` **once**. Use this to resolve listener-wide middlewares a
single time and reuse the result across every route (via
`compile_pipeline/4`) instead of re-running their init per route.
""".
-spec resolve(middleware_list()) -> [resolved()].
resolve(Mws) ->
    [resolve_entry(Mw) || Mw <- Mws].

%% Resolve one entry to its `{Callable, State}` runtime pair. A module entry
%% runs its required `init/1` callback here, so the per-request closure reuses
%% the returned state; a fun entry has no init, so its config is the state
%% verbatim. A bare entry defaults its config to `#{}`.
-spec resolve_entry(middleware()) -> resolved().
resolve_entry({Mod, Config}) when is_atom(Mod) ->
    {Mod, Mod:init(Config)};
resolve_entry({Fun, Config}) when is_function(Fun, 3) ->
    {Fun, Config};
resolve_entry(Mod) when is_atom(Mod) ->
    {Mod, Mod:init(#{})};
resolve_entry(Fun) when is_function(Fun, 3) ->
    {Fun, #{}}.

-doc """
Compose a middleware list around a handler call, returning a single
`next()` fun that runs the full pipeline.

Each module entry's `init/1` is run **here**, once, as the pipeline is
built (via `resolve/1`); the resulting `t:state/0` is captured in the
entry's closure and reused on every request. The first middleware in the
list runs **outermost** — it gets the first crack at the request and the
last crack at the response. The handler is the innermost call; an empty
list returns the handler fun unchanged.
""".
-spec compose(middleware_list(), next()) -> next().
compose(Mws, Handler) ->
    compose_resolved(resolve(Mws), Handler).

%% Compose already-resolved entries around a handler. No `init/1` runs here
%% (it ran in `resolve/1`); the captured state is reused per request. Split
%% from `compose/2` so pre-resolved listener middlewares can be composed
%% without re-resolving them.
-spec compose_resolved([resolved()], next()) -> next().
compose_resolved([], Handler) ->
    Handler;
compose_resolved([{Callable, State} | Rest], Handler) ->
    Inner = compose_resolved(Rest, Handler),
    fun(Req) -> apply_one(Callable, State, Req, Inner) end.

%% Build the handler pipeline from a combined middleware list
%% (listener-level ++ per-route) and a target handler module. The
%% resulting `next()` fun captures only `Mw` and
%% `fun Handler:handle/1`, both compile-time constants — no request
%% state — so it's safe to compose once and reuse across every
%% request that matches the route.
%%
%% Called once per route at listener init / `reload_routes/2` time,
%% from the router compile path (router-form routes) and the
%% listener's dispatch builder (single-handler dispatch tag). The
%% resulting `next()` fun lands directly in the compiled route entry
%% (and the `{handler, Mod, Pipeline, State}` dispatch tag) — no
%% wrapper map. The conn loops just call it with the request.
%%
%% Empty list → returns `fun Handler:handle/1` directly, skipping
%% `compose/2` to save one closure allocation + one indirection on the
%% no-mws fast path most production handlers hit.
-doc false.
-spec build_pipeline(middleware_list(), module()) -> next().
build_pipeline([], Handler) ->
    fun Handler:handle/1;
build_pipeline(Mws, Handler) ->
    compose(Mws, fun Handler:handle/1).

%% Compile a per-request pipeline `next()` fun from one combined middleware
%% list: composes the mws ending in `fun Handler:handle/1`, optionally wrapped
%% in an outermost closure that injects `state` onto the request before
%% middlewares run. Used by `roadrunner_listener:build_dispatch/2` for
%% single-handler dispatch (one pipeline, so no listener/route split). Routes
%% use `compile_pipeline/4`.
-doc false.
-spec compile_pipeline(middleware_list(), module(), no_state | {state, term()}) -> next().
compile_pipeline(Mws, Handler, no_state) ->
    build_pipeline(Mws, Handler);
compile_pipeline(Mws, Handler, {state, State}) ->
    Inner = build_pipeline(Mws, Handler),
    fun(Req) -> Inner(Req#{state => State}) end.

%% Compile a route's pipeline from listener middlewares already resolved once
%% (shared across all routes) and the route's own raw middlewares. Only the
%% route's mws are resolved here; the listener entries wrap them (and the
%% handler), staying outermost. Used by `roadrunner_router:compile/2` so a
%% listener-wide middleware's `init/1` runs once, not once per route.
-doc false.
-spec compile_pipeline([resolved()], middleware_list(), module(), no_state | {state, term()}) ->
    next().
compile_pipeline(ResolvedListener, RouteMws, Handler, no_state) ->
    build_resolved_pipeline(ResolvedListener, RouteMws, Handler);
compile_pipeline(ResolvedListener, RouteMws, Handler, {state, State}) ->
    Inner = build_resolved_pipeline(ResolvedListener, RouteMws, Handler),
    fun(Req) -> Inner(Req#{state => State}) end.

%% Wrap the resolved listener middlewares (outermost) around the route's own
%% middlewares (resolved here) around the handler. An empty listener + route
%% list collapses to `fun Handler:handle/1` (no closures) via the
%% `compose_resolved/2` empty-list clause.
-spec build_resolved_pipeline([resolved()], middleware_list(), module()) -> next().
build_resolved_pipeline(ResolvedListener, RouteMws, Handler) ->
    Inner = compose_resolved(resolve(RouteMws), fun Handler:handle/1),
    compose_resolved(ResolvedListener, Inner).

%% Invoke a resolved entry with the request and continuation. `Callable`
%% and `State` are threaded individually (no per-request tuple rebuild);
%% the `{Callable, State}` pair was already split by `resolve/1` at bake
%% time.
-spec apply_one(module() | middleware_fun(), state(), roadrunner_req:request(), next()) ->
    roadrunner_handler:result().
apply_one(Mod, State, Req, Next) when is_atom(Mod) ->
    Mod:call(Req, Next, State);
apply_one(Fun, State, Req, Next) when is_function(Fun, 3) ->
    Fun(Req, Next, State).
