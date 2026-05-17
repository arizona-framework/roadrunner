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

-export_type([route/0, routes/0, compiled/0, bindings/0]).

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
-opaque compiled() :: [{[segment()], module(), roadrunner_middleware:next()}].

-doc """
Compile a list of routes into the lookup form `match/2` expects.

Each path is split on `/` (empty leading/trailing segments dropped),
and segments starting with `:` are recorded as named captures.

`ListenerMws` is the listener-wide middleware list; it is prepended
to each route's own `middlewares` and composed once into a single
`next()` fun (with any per-route `state` injected before middlewares
run). The conn loop calls that fun straight with the request —
zero closure allocations per request. Pass `[]` for `ListenerMws`
when compiling routes outside a listener (typically only in tests).
""".
-spec compile(routes(), roadrunner_middleware:middleware_list()) -> compiled().
compile(Routes, ListenerMws) when is_list(Routes), is_list(ListenerMws) ->
    [compile_route(R, ListenerMws) || R <- Routes].

-spec compile_route(route(), roadrunner_middleware:middleware_list()) ->
    {[segment()], module(), roadrunner_middleware:next()}.
compile_route({Path, Handler}, ListenerMws) when is_binary(Path), is_atom(Handler) ->
    {
        compile_path(Path),
        Handler,
        roadrunner_middleware:compile_pipeline(ListenerMws, Handler, no_state)
    };
compile_route({Path, Handler, State}, ListenerMws) when is_binary(Path), is_atom(Handler) ->
    {
        compile_path(Path),
        Handler,
        roadrunner_middleware:compile_pipeline(ListenerMws, Handler, {state, State})
    };
compile_route(#{path := Path, handler := Handler} = Route, ListenerMws) when
    is_binary(Path), is_atom(Handler)
->
    RouteMws = maps:get(middlewares, Route, []),
    Mws = ListenerMws ++ RouteMws,
    StateArg =
        case Route of
            #{state := S} -> {state, S};
            _ -> no_state
        end,
    {compile_path(Path), Handler, roadrunner_middleware:compile_pipeline(Mws, Handler, StateArg)}.

-spec compile_path(binary()) -> [segment()].
compile_path(Path) ->
    [compile_segment(S) || S <- path_segments(Path)].

-spec compile_segment(binary()) -> segment().
compile_segment(<<":", Name/binary>>) -> {param, Name};
compile_segment(<<"*", Name/binary>>) -> {wildcard, Name};
compile_segment(Lit) -> {literal, Lit}.

-doc """
Look up the handler for a given request path.

Returns `{ok, Handler, Bindings, Pipeline}` on a match — `Bindings`
is a map populated with captures from `:param` segments (empty for
purely literal routes); `Pipeline` is the pre-composed `next()` fun
built at compile time (listener mws ++ per-route mws, optionally
wrapped in a state-injecting outermost closure, ending in
`fun Handler:handle/1`). The conn loop calls it with the request.
Returns `not_found` when no compiled route matches.
""".
-spec match(Path :: binary(), compiled()) ->
    {ok, module(), bindings(), roadrunner_middleware:next()} | not_found.
match(Path, Compiled) when is_binary(Path), is_list(Compiled) ->
    Segments = path_segments(Path),
    match_first(Segments, Compiled).

-spec match_first([binary()], compiled()) ->
    {ok, module(), bindings(), roadrunner_middleware:next()} | not_found.
match_first(_Segments, []) ->
    not_found;
match_first(Segments, [{Pattern, Handler, Pipeline} | Rest]) ->
    case match_pattern(Pattern, Segments, #{}) of
        {ok, Bindings} -> {ok, Handler, Bindings, Pipeline};
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
