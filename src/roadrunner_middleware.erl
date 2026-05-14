-module(roadrunner_middleware).
-moduledoc false.

%% Continuation-style middleware for roadrunner handlers.
%%
%% A middleware wraps the rest of the request pipeline:
%%
%% ```erlang
%% -callback call(Request, Next) -> Result when
%%     Request :: roadrunner_req:request(),
%%     Next :: fun((Request) -> Result),
%%     Result :: roadrunner_handler:result().
%% ```
%%
%% The pipeline (handler at its core) returns `{Response, Req2}`. Each
%% middleware sees the same shape and is expected to return it — either
%% straight from `Next` or after transforming it.
%%
%% Each middleware decides:
%%
%% - **pass through unchanged** — `Next(Req)`
%% - **transform the request** — `Next(Req#{...})`
%% - **short-circuit / halt** — return `{Response, Req}` without calling
%%   `Next`
%% - **wrap the response** — let `Next(Req)` run, then transform what it
%%   returned (status, headers, body)
%% - **side effects around the call** — log, time, instrument
%%
%% This shape is deliberately lighter than cowboy's deprecated
%% `(Req, Env)` middlewares (which couldn't see the response) and
%% much lighter than cowboy stream handlers (which split the request
%% lifecycle into five callbacks). It matches the modern
%% continuation/decorator pattern used by Plug.Builder, Express.js,
%% Tower, and Servant.
%%
%% ## No direct wire writes from middleware
%%
%% Middleware code never has access to the underlying socket — the
%% `Request` map intentionally excludes any socket reference. To
%% respond, a middleware **must** return a `Result` (either the one
%% from `Next(Req)` or its own response triple); there is no
%% `roadrunner_req:reply/4` equivalent to cowboy's mid-flight
%% `cowboy_req:reply/4`.
%%
%% This is a feature, not a limitation. Bytes only hit the wire from
%% one place — the conn process — which means:
%%
%% - `[roadrunner, request, stop]` telemetry fires for every request,
%%   with consistent duration and status metadata.
%% - gzip wrapping, response transforms, and `Content-Length` framing
%%   are applied uniformly regardless of which middleware produced
%%   the response.
%% - Send errors are handled in one place (`[roadrunner, response,
%%   send_failed]` telemetry, drain bookkeeping, slot release).
%% - The "halt" pattern is structurally simple: don't call `Next`, just
%%   return a response. There's no second halt protocol to maintain
%%   (compare: an arizona cowboy adapter has to support BOTH stashed
%%   redirects AND raw-write-from-middleware to stay backward-compatible
%%   with cowboy's permissiveness; the roadrunner adapter only handles
%%   the stashed-redirect path).
%%
%% If you're porting middleware from cowboy that called
%% `cowboy_req:reply/4` directly, replace the call with returning a
%% response triple — `{Status, Headers, Body}` — from the middleware,
%% and the framework writes the bytes.
%%
%% ## Where middlewares live
%%
%% - **Listener-level**: `roadrunner_listener:start_link(_, #{middlewares => [...]})`.
%%   These run for every request — single-handler and routed.
%% - **Per-route**: in the 3-tuple route opts under the `middlewares` key:
%%   `{~"/path", handler_mod, #{middlewares => [...]}}`.
%%
%% When both are configured, listener middlewares wrap route middlewares
%% which wrap the handler — first in each list runs outermost.
%%
%% ## Middleware shape
%%
%% Each entry in a middlewares list is one of:
%%
%% - `module()` — the module's `call/2` (this behaviour callback) is invoked.
%% - `fun((Request, Next) -> Result)` — invoked directly.
%%
%% ## Examples
%%
%% ```erlang
%% %% Auth check — halt with 401 when missing.
%% auth(Req, Next) ->
%%     case roadrunner_req:header(~"authorization", Req) of
%%         undefined -> {roadrunner_resp:unauthorized(), Req};
%%         _ -> Next(Req)
%%     end.
%%
%% %% Around: time the whole request including the response write.
%% timing(Req, Next) ->
%%     Start = erlang:monotonic_time(millisecond),
%%     Result = Next(Req),
%%     logger:info(#{took_ms => erlang:monotonic_time(millisecond) - Start}),
%%     Result.
%%
%% %% Inject a server header on every response.
%% server_header(Req, Next) ->
%%     {{S, H, B}, Req2} = Next(Req),
%%     {{S, [{~"server", ~"roadrunner"} | H], B}, Req2}.
%% ```

-export([compose/2, build_pipeline/3]).
-export_type([middleware/0, middleware_list/0, next/0]).

-type next() :: fun((roadrunner_req:request()) -> roadrunner_handler:result()).
-type middleware() ::
    module()
    | fun((roadrunner_req:request(), next()) -> roadrunner_handler:result()).
-type middleware_list() :: [middleware()].

-callback call(Request :: roadrunner_req:request(), Next :: next()) ->
    roadrunner_handler:result().

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

-doc """
Build the per-request handler pipeline from listener-level
middlewares + the request's route-level middlewares (read from
`Req#{route_opts}`) + a target handler module.

Listener middlewares wrap the route middlewares wrap the handler.
When BOTH lists are empty, returns `fun Handler:handle/1` directly
— skipping `compose/2` saves one closure allocation + one
indirection on the no-mws fast path most production handlers hit.
Otherwise composes the concatenated list with the handler at the
center.

Takes the request directly (rather than a pre-computed RouteMws)
so the route-mws pattern-match is folded into this function — one
fewer function-call frame than the older `route_middlewares/1`
chain. Used by both the h1 conn loop
(`roadrunner_conn_loop:run_pipeline`) and the h2 stream worker
(`roadrunner_http2_stream_worker:invoke`) so the dispatch shape
stays identical across protocols.
""".
-spec build_pipeline(middleware_list(), roadrunner_req:request(), module()) -> next().
build_pipeline([], Req, Handler) ->
    case route_mws(Req) of
        [] -> fun Handler:handle/1;
        Mws -> compose(Mws, fun Handler:handle/1)
    end;
build_pipeline(ListenerMws, Req, Handler) ->
    compose(ListenerMws ++ route_mws(Req), fun Handler:handle/1).

-spec route_mws(roadrunner_req:request()) -> middleware_list().
route_mws(#{route_opts := #{middlewares := Mws}}) -> Mws;
route_mws(_) -> [].

-spec apply_one(middleware(), roadrunner_req:request(), next()) ->
    roadrunner_handler:result().
apply_one(Mod, Req, Next) when is_atom(Mod) ->
    Mod:call(Req, Next);
apply_one(Fun, Req, Next) when is_function(Fun, 2) ->
    Fun(Req, Next).
