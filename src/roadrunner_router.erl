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
  => [Mw, ...], methods => [~"GET", ...]}` — full map form. Use this
  when you want to attach per-route middlewares, an HTTP-method
  allowlist, or any future per-route framework knob. Only `path` and
  `handler` are required; an absent `methods` answers every method.

The tuple shorthand intentionally cannot carry middlewares — that
keeps the simple case syntactically light and pushes "more than just
state" to the more verbose map form.

A route may restrict the HTTP methods it answers via the map form's
`methods` key (a list of **uppercase** method binaries, e.g.
`[~"GET", ~"POST"]`). A request whose path matches a route but whose
method is not in that route's list does not match — `match/3` keeps
scanning, and if no route on that path accepts the method it returns
`{method_not_allowed, Allowed}` carrying the union of the methods
declared by the path-matching routes (for a `405` `Allow` header). A
route with no `methods` answers every method.

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

-export([compile/2, match/3]).

-export_type([route/0, routes/0, compiled/0, bindings/0, methods/0]).

-doc """
A single route entry. Three shapes are accepted:

- `{Path, Handler}` — shorthand: no state, no middlewares.
- `{Path, Handler, State}` — shorthand with state only.
- `#{path := Path, handler := Handler, state => State,
   middlewares => Mws, methods => [~"GET", ...]}` — map form; use this
  to attach per-route middlewares, an HTTP-method allowlist, or future
  per-route framework knobs.

`Path` is a binary pattern (literal segments, `:param` captures, or
`*wildcard` catch-all). `Handler` is the module implementing
`roadrunner_handler`. `State` is opaque per-route data threaded back
to the handler via `roadrunner_req:state/1`; unset → `undefined`.
`methods` is a list of uppercase method binaries the route answers;
unset → every method.
""".
-type route() ::
    {Path :: binary(), Handler :: module()}
    | {Path :: binary(), Handler :: module(), State :: term()}
    | #{
        path := binary(),
        handler := module(),
        state => term(),
        middlewares => roadrunner_middleware:middleware_list(),
        methods => methods()
    }.

-doc """
An HTTP-method allowlist for a route: a list of **uppercase** method
binaries (`[~"GET", ~"POST"]`), or `undefined` to answer every method.
`compile/2` turns the list into a `#{Method => true}` set-map so match
time is an O(1) `is_map_key/2` rather than a list scan; methods are
matched byte-exact against `roadrunner_req:method/1` (already uppercase
on the wire), so callers must pass uppercase.

Matching is **literal**: a `[~"GET"]` route does *not* implicitly answer
`HEAD` (or any other verb) -- list every method the route accepts.
A present `methods` must be a non-empty list of binaries; `compile/2`
raises `{invalid_route_methods, _}` on an empty list or non-binary
entries (both would otherwise silently reject every request).
""".
-type methods() :: [binary()] | undefined.

%% The compiled form of `methods()`: a set-as-map for O(1) membership,
%% or `undefined` for a route that answers every method.
-type method_lookup() :: #{binary() => true} | undefined.

-doc "An ordered list of routes; matched first-to-last.".
-type routes() :: [route()].

-doc """
Captured route parameters, populated by `match/3`.

`:param` segments produce a single binary value
(`#{~"id" => ~"42"}`). `*wildcard` segments produce the list of
remaining path segments
(`#{~"rest" => [~"a", ~"b"]}`). Empty for routes with no captures.
""".
-type bindings() :: #{binary() => binary() | [binary()]}.

-type segment() :: {literal, binary()} | {param, binary()} | {wildcard, binary()}.

-doc """
The compiled-routes representation `match/3` consumes. Treat as
opaque: the shape is an implementation detail and may change.
""".
-opaque compiled() :: [
    {[segment()], module(), roadrunner_middleware:next(), term(), method_lookup()}
].

-doc """
Compile a list of routes into the lookup form `match/3` expects.

Each path is split on `/` (empty leading/trailing segments dropped),
and segments starting with `:` are recorded as named captures.

`ListenerMws` is the listener-wide middleware list; it is resolved
**once** (running each module's `init/1` a single time) and reused
across every route, composed outermost around each route's own
`middlewares` (with any per-route `state` injected before middlewares
run). The conn loop calls the composed fun straight with the request —
zero closure allocations per request. Pass `[]` for `ListenerMws`
when compiling routes outside a listener (typically only in tests).
""".
-spec compile(routes(), roadrunner_middleware:middleware_list()) -> compiled().
compile(Routes, ListenerMws) when is_list(Routes), is_list(ListenerMws) ->
    ResolvedListener = roadrunner_middleware:resolve(ListenerMws),
    [compile_route(R, ResolvedListener) || R <- Routes].

-spec compile_route(route(), [roadrunner_middleware:resolved()]) ->
    {[segment()], module(), roadrunner_middleware:next(), term(), method_lookup()}.
compile_route({Path, Handler}, ResolvedListener) when is_binary(Path), is_atom(Handler) ->
    {
        compile_path(Path),
        Handler,
        roadrunner_middleware:compile_pipeline(ResolvedListener, [], Handler, no_state),
        undefined,
        undefined
    };
compile_route({Path, Handler, State}, ResolvedListener) when is_binary(Path), is_atom(Handler) ->
    {
        compile_path(Path),
        Handler,
        roadrunner_middleware:compile_pipeline(ResolvedListener, [], Handler, {state, State}),
        State,
        undefined
    };
compile_route(#{path := Path, handler := Handler} = Route, ResolvedListener) when
    is_binary(Path), is_atom(Handler)
->
    RouteMws = maps:get(middlewares, Route, []),
    Methods = compile_methods(maps:get(methods, Route, undefined)),
    {StateArg, StateValue} =
        case Route of
            #{state := S} -> {{state, S}, S};
            _ -> {no_state, undefined}
        end,
    {
        compile_path(Path),
        Handler,
        roadrunner_middleware:compile_pipeline(ResolvedListener, RouteMws, Handler, StateArg),
        StateValue,
        Methods
    }.

-spec compile_path(binary()) -> [segment()].
compile_path(Path) ->
    [compile_segment(S) || S <- path_segments(Path)].

-spec compile_segment(binary()) -> segment().
compile_segment(<<":", Name/binary>>) -> {param, Name};
compile_segment(<<"*", Name/binary>>) -> {wildcard, Name};
compile_segment(Lit) -> {literal, Lit}.

%% Compile a route's `methods` allowlist into a set-map for O(1) match-time
%% membership; `undefined` (no allowlist) passes through to answer every method.
%% A present `methods` must be a non-empty list of binaries -- an empty list
%% (a route that answers nothing) or non-binary entries (which could never
%% match the binary wire method) are config errors, raised loudly rather than
%% silently 405-ing every request.
-spec compile_methods(methods()) -> method_lookup().
compile_methods(undefined) ->
    undefined;
compile_methods(Methods) when is_list(Methods), Methods =/= [] ->
    case lists:all(fun is_binary/1, Methods) of
        true -> maps:from_keys(Methods, true);
        false -> error({invalid_route_methods, Methods})
    end;
compile_methods(Methods) ->
    error({invalid_route_methods, Methods}).

-doc """
Look up the handler for a given request method + path.

Returns `{ok, Handler, Bindings, Pipeline, State}` on a match —
`Bindings` is a map populated with captures from `:param` segments
(empty for purely literal routes); `Pipeline` is the pre-composed
`next()` fun built at compile time (listener mws ++ per-route mws,
optionally wrapped in a state-injecting outermost closure, ending in
`fun Handler:handle/1`); `State` is the per-route opaque state
attached by the user at compile time (or `undefined` when the route
shape didn't carry any). The conn loop just calls `Pipeline` —
`State` is for callers who need to introspect a route outside the
request flow.

`Method` is the uppercase request-method binary. A route with no
`methods` allowlist answers every method; otherwise the method must be
a member. When a route's path matches but its method does not, the
scan continues (so a later same-path route can answer the method —
that is how same-path method dispatch works). If at least one route's
path matched but none answered the method, returns
`{method_not_allowed, Allowed}` where `Allowed` is the sorted,
de-duplicated union of those routes' methods (for a `405` `Allow`
header). Returns `not_found` when no compiled route's path matches at
all.
""".
-spec match(Method :: binary(), Path :: binary(), compiled()) ->
    {ok, module(), bindings(), roadrunner_middleware:next(), term()}
    | {method_not_allowed, [binary()]}
    | not_found.
match(Method, Path, Compiled) when is_binary(Method), is_binary(Path), is_list(Compiled) ->
    Segments = path_segments(Path),
    match_first(Method, Segments, Compiled, #{}).

%% `Allow` is a set-map accumulator of the methods declared by every
%% path-matching-but-method-rejected route; `maps:merge/2` unions and
%% de-duplicates it. At the end its sorted keys become the `405` Allow
%% header (sort makes the header deterministic regardless of map order).
-spec match_first(binary(), [binary()], compiled(), #{binary() => true}) ->
    {ok, module(), bindings(), roadrunner_middleware:next(), term()}
    | {method_not_allowed, [binary()]}
    | not_found.
match_first(_Method, _Segments, [], Allow) when map_size(Allow) =:= 0 ->
    not_found;
match_first(_Method, _Segments, [], Allow) ->
    {method_not_allowed, lists:sort(maps:keys(Allow))};
match_first(Method, Segments, [{Pattern, Handler, Pipeline, State, Methods} | Rest], Allow) ->
    case match_pattern(Pattern, Segments, #{}) of
        no_match ->
            match_first(Method, Segments, Rest, Allow);
        Bindings ->
            case method_allowed(Method, Methods) of
                true -> {ok, Handler, Bindings, Pipeline, State};
                false -> match_first(Method, Segments, Rest, maps:merge(Allow, Methods))
            end
    end.

%% A route with no `methods` allowlist answers every method; otherwise
%% the request method must be a key in the compiled set-map.
-spec method_allowed(binary(), method_lookup()) -> boolean().
method_allowed(_Method, undefined) ->
    true;
method_allowed(Method, MethodsMap) ->
    is_map_key(Method, MethodsMap).

%% Returns the bare bindings map on a match (no `{ok, _}` wrap) so the
%% caller `match_first/4` can splice it straight into its own
%% `{ok, Handler, Bindings, _, _}` tuple without paying the intermediate
%% 2-tuple alloc per matched route. `no_match` is the sentinel for the
%% miss path — disjoint from any map shape `match_pattern` would produce.
-spec match_pattern([segment()], [binary()], bindings()) ->
    bindings() | no_match.
match_pattern([], [], Bindings) ->
    Bindings;
match_pattern([{literal, S} | P], [S | Segs], Bindings) ->
    match_pattern(P, Segs, Bindings);
match_pattern([{param, Name} | P], [Value | Segs], Bindings) ->
    match_pattern(P, Segs, Bindings#{Name => Value});
match_pattern([{wildcard, Name}], Segs, Bindings) ->
    Bindings#{Name => Segs};
match_pattern(_, _, _) ->
    no_match.

-spec path_segments(binary()) -> [binary()].
path_segments(Path) ->
    binary:split(Path, persistent_term:get(?SLASH_CP_KEY), [global, trim_all]).

%% `-on_load` callback. Compiles the path-segment separator once at
%% module load into `persistent_term` so the hot path reads a constant.
-spec init_patterns() -> ok.
init_patterns() ->
    persistent_term:put(?SLASH_CP_KEY, binary:compile_pattern(~"/")),
    ok.
