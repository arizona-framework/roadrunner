-module(roadrunner_router).
-on_load(init_patterns/0).

-define(SLASH_CP_KEY, {?MODULE, slash_cp}).
-moduledoc """
Path → handler dispatch with parameterized segments.

A route is either a tuple shorthand or a map. Both forms share the
same `Path` and `Handler`:

- `{Path, Handler}` — only routes the path; no state, no per-route
  middlewares.
- `{Path, Handler, State}` — adds opaque per-handler state surfaced
  via `roadrunner_req:state/1`.
- `#{path => Path, handler => Handler, state => State, middlewares
  => [Mw, ...]}` — full map form. Use this when you want to attach
  per-route middlewares (or any future per-route framework knob).
  Only `path` and `handler` are required.

The tuple shorthand intentionally cannot carry middlewares — that
keeps the simple case syntactically light and pushes "more than just
state" to the more verbose map form.

`Path` is a binary like `/users/:id/posts/:post_id`. Segments
starting with `:` capture a single segment into bindings keyed by
the **binary** name that follows the colon — we deliberately avoid
`binary_to_atom/1` on the parsed name to keep the "everything is
binary on the wire" rule we already use for header names.

Segments starting with `*` (e.g. `/static/*path`) are wildcard
captures: they consume all remaining path segments and bind them as
a list under the given name. A wildcard must be the last segment in
a pattern; anything after it never matches.

Literal segments must match byte-exactly; comparison is
case-sensitive per RFC 3986.

Routes are tried in declaration order — earlier entries win. The
opaque `compiled()` shape is a list of pre-parsed segment patterns;
swapping to a trie/DAG later is a non-breaking change for callers.
""".

-export([compile/2, match/2]).

-export_type([route/0, routes/0, route_cfg/0, compiled/0, bindings/0]).

-doc """
A single route entry. Three shapes are accepted:

- `{Path, Handler}` — shorthand: no state, no middlewares.
- `{Path, Handler, State}` — shorthand with state only.
- `#{path := Path, handler := Handler, state => State,
   middlewares => Mws}` — map form; use this to attach per-route
  middlewares or future per-route framework knobs.

`Path` is a binary pattern (literal segments, `:param` captures, or
`*wildcard` catch-all). `Handler` is the module implementing
`roadrunner_handler`. `State` is opaque per-route data threaded back
to the handler via `roadrunner_req:state/1`; unset → `undefined`.
""".
-type route() ::
    {Path :: binary(), Handler :: module()}
    | {Path :: binary(), Handler :: module(), State :: term()}
    | #{
        path := binary(),
        handler := module(),
        state => term(),
        middlewares => roadrunner_middleware:middleware_list()
    }.

-doc """
Per-route configuration carried alongside the matched handler.

- `pipeline` is the pre-composed middleware chain ending in
  `fun Handler:handle/1`. Built once at compile / `reload_routes/2`
  time from the listener-wide mws prepended onto the route's own
  mws, so the conn loop calls it with the request and gets the
  handler result back, zero closure allocations per request. Always
  present in the 4th element of `match/2`'s `{ok, ...}` return; the
  `=>` arity covers the pre-compile shape the bake helpers accept as
  input.
- `state` mirrors what the route entry attached (absent when the
  route used the 2-tuple shorthand or the bare-atom single-handler
  form).
""".
-type route_cfg() :: #{
    pipeline => roadrunner_middleware:next(),
    state => term()
}.

-doc "An ordered list of routes; matched first-to-last.".
-type routes() :: [route()].

-doc """
Captured route parameters, populated by `match/2`.

`:param` segments produce a single binary value
(`#{~"id" => ~"42"}`). `*wildcard` segments produce the list of
remaining path segments
(`#{~"rest" => [~"a", ~"b"]}`). Empty for routes with no captures.
""".
-type bindings() :: #{binary() => binary() | [binary()]}.

-type segment() :: {literal, binary()} | {param, binary()} | {wildcard, binary()}.

-doc """
The compiled-routes representation `match/2` consumes. Treat as
opaque: the shape is an implementation detail and may change.
""".
-opaque compiled() :: [{[segment()], module(), route_cfg()}].

-doc """
Compile a list of routes into the lookup form `match/2` expects.

Each path is split on `/` (empty leading/trailing segments dropped),
and segments starting with `:` are recorded as named captures.

`ListenerMws` is the listener-wide middleware list; it is prepended
to each route's own `middlewares` so the conn loop reads the full
pipeline straight from the matched route's cfg — no per-request
concatenation. Pass `[]` when compiling routes outside a listener
(typically only in tests).
""".
-spec compile(routes(), roadrunner_middleware:middleware_list()) -> compiled().
compile(Routes, ListenerMws) when is_list(Routes), is_list(ListenerMws) ->
    [compile_route(R, ListenerMws) || R <- Routes].

-spec compile_route(route(), roadrunner_middleware:middleware_list()) ->
    {[segment()], module(), route_cfg()}.
compile_route({Path, Handler}, ListenerMws) when is_binary(Path), is_atom(Handler) ->
    {compile_path(Path), Handler, base_cfg(Handler, ListenerMws, #{})};
compile_route({Path, Handler, State}, ListenerMws) when is_binary(Path), is_atom(Handler) ->
    {compile_path(Path), Handler, base_cfg(Handler, ListenerMws, #{state => State})};
compile_route(#{path := Path, handler := Handler} = Route, ListenerMws) when
    is_binary(Path), is_atom(Handler)
->
    RouteMws = maps:get(middlewares, Route, []),
    Cfg = maps:without([path, handler, middlewares], Route),
    {compile_path(Path), Handler, base_cfg(Handler, ListenerMws ++ RouteMws, Cfg)}.

%% Compose the combined mws ending in `fun Handler:handle/1` once and
%% stash the result under `pipeline` on the cfg. The conn loop reads
%% the fun and calls it with the request — no per-request closure
%% allocation, regardless of mws count.
-spec base_cfg(module(), roadrunner_middleware:middleware_list(), route_cfg()) -> route_cfg().
base_cfg(Handler, Mws, Cfg) ->
    Cfg#{pipeline => roadrunner_middleware:build_pipeline(Mws, Handler)}.

-spec compile_path(binary()) -> [segment()].
compile_path(Path) ->
    [compile_segment(S) || S <- path_segments(Path)].

-spec compile_segment(binary()) -> segment().
compile_segment(<<":", Name/binary>>) -> {param, Name};
compile_segment(<<"*", Name/binary>>) -> {wildcard, Name};
compile_segment(Lit) -> {literal, Lit}.

-doc """
Look up the handler for a given request path.

Returns `{ok, Handler, Bindings, RouteCfg}` on a match — `Bindings`
is a map populated with captures from `:param` segments (empty for
purely literal routes); `RouteCfg` is the per-route configuration
map produced at compile time. See `t:route_cfg/0` for its shape.
Returns `not_found` when no compiled route matches.
""".
-spec match(Path :: binary(), compiled()) ->
    {ok, module(), bindings(), route_cfg()} | not_found.
match(Path, Compiled) when is_binary(Path), is_list(Compiled) ->
    Segments = path_segments(Path),
    match_first(Segments, Compiled).

-spec match_first([binary()], compiled()) ->
    {ok, module(), bindings(), route_cfg()} | not_found.
match_first(_Segments, []) ->
    not_found;
match_first(Segments, [{Pattern, Handler, Cfg} | Rest]) ->
    case match_pattern(Pattern, Segments, #{}) of
        {ok, Bindings} -> {ok, Handler, Bindings, Cfg};
        no_match -> match_first(Segments, Rest)
    end.

-spec match_pattern([segment()], [binary()], bindings()) ->
    {ok, bindings()} | no_match.
match_pattern([], [], Bindings) ->
    {ok, Bindings};
match_pattern([{literal, S} | P], [S | Segs], Bindings) ->
    match_pattern(P, Segs, Bindings);
match_pattern([{param, Name} | P], [Value | Segs], Bindings) ->
    match_pattern(P, Segs, Bindings#{Name => Value});
match_pattern([{wildcard, Name}], Segs, Bindings) ->
    {ok, Bindings#{Name => Segs}};
match_pattern(_, _, _) ->
    no_match.

-spec path_segments(binary()) -> [binary()].
path_segments(Path) ->
    binary:split(Path, persistent_term:get(?SLASH_CP_KEY), [global, trim_all]).

%% `-on_load` callback. Compiles the path-segment separator once at
%% module load — see the `feedback_compile_pattern_convention`
%% project rule.
-spec init_patterns() -> ok.
init_patterns() ->
    persistent_term:put(?SLASH_CP_KEY, binary:compile_pattern(~"/")),
    ok.
