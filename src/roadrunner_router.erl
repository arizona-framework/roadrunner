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

-export([
    compile/2,
    match/3,
    compile_rate_limits/1,
    match_rate_limit/3,
    compile_body_limits/1,
    match_body_limit/3
]).

-export_type([
    route/0, routes/0, compiled/0, bindings/0, methods/0, route_rate_limits/0, route_body_limits/0
]).

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
        methods => methods(),
        rate_limit => map(),
        max_body => non_neg_integer()
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

Captured values are percent-decoded (`/users/caf%C3%A9` binds
`<<"café"/utf8>>`), consistent with query params; a segment whose
percent-escapes are malformed (a `%` not followed by two hex digits)
is kept raw. Decoding does not validate UTF-8, so `%FF` binds the raw
`0xFF` byte. There is no `+` -> space translation -- that is a
query-string convention, so a literal `+` in a path stays a `+`.

Because decoding happens after the path is split on raw `/`, a decoded
value can contain a `/` (`%2F`), a `..`, or a leading `/` — it is not a
single clean path component. A handler that builds a filesystem path or
an outbound URL from a captured value must reject `..` and absolute
segments itself; see `roadrunner_static` for the reference check.
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
The compiled per-route `rate_limit` overrides `match_rate_limit/3` consumes: a
path+method-keyed subset of the routes that declare a `rate_limit`, each with
its pre-derived `{Rate, Cap, Cost}` unit triple and the route's path binary as
the bucket-namespace key. `undefined` when no route declares one (so the gate
pays nothing) — `roadrunner_conn` matches that to take its global-only fast
path, so this is a plain (non-opaque) type.
""".
-type route_rate_limits() ::
    [{[segment()], method_lookup(), {pos_integer(), pos_integer(), pos_integer()}, binary()}]
    | undefined.

-doc """
The compiled per-route `max_body` overrides `match_body_limit/3` consumes: a
path+method-keyed subset of the routes that declare a `max_body`, each with its
byte cap. `undefined` when no route declares one (so the body path pays
nothing). A plain (non-opaque) type — the conn loops match `undefined` to take
the global-limit fast path.
""".
-type route_body_limits() ::
    [{[segment()], method_lookup(), non_neg_integer()}]
    | undefined.

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
                true -> {ok, Handler, decode_bindings(Bindings), Pipeline, State};
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

%% Percent-decode the captured bindings of the matched route. `match/3` splits
%% the path on raw `/`, so a `:param`/`*wildcard` segment arrives still
%% percent-encoded (`/users/caf%C3%A9` captures `<<"caf%C3%A9">>`); decode each
%% captured segment so handlers see the real characters, consistent with query
%% params (`roadrunner_qs`). Decoding runs once, on the winning route only, and
%% short-circuits the common capture-free route. Done here rather than in
%% `match_pattern/3` so a partially-matching route that later fails does not pay
%% to decode captures it then discards.
-spec decode_bindings(bindings()) -> bindings().
decode_bindings(Bindings) when map_size(Bindings) =:= 0 ->
    Bindings;
decode_bindings(Bindings) ->
    #{Name => decode_value(Value) || Name := Value <- Bindings}.

%% A `:param` value is a single segment; a `*wildcard` value is the list of
%% remaining segments -- decode each element.
-spec decode_value(binary() | [binary()]) -> binary() | [binary()].
decode_value(Value) when is_binary(Value) ->
    decode_segment(Value);
decode_value(Segments) when is_list(Segments) ->
    [decode_segment(Segment) || Segment <- Segments].

%% Percent-decode one captured segment, keeping it raw on a malformed escape (a
%% `%` not followed by two hex digits) rather than failing the match on
%% attacker-controllable input. Decoding does not validate UTF-8, so non-UTF-8
%% escapes pass through as their raw bytes. No `+` -> space: that is a
%% query/form-encoding convention, not a path one (a literal `+` is valid,
%% unencoded path data).
-spec decode_segment(binary()) -> binary().
decode_segment(Segment) ->
    case roadrunner_uri:percent_decode(Segment) of
        {ok, Decoded} -> Decoded;
        {error, badarg} -> Segment
    end.

-doc """
Compile the per-route `rate_limit` overrides out of a route list.

Keeps only the map-form routes that carry a `rate_limit` key, pairing each
route's compiled path + method allowlist with its pre-derived `{Rate, Cap, Cost}`
triple (validated and derived by `roadrunner_rate_limit`) and its path binary
(the bucket-namespace key). Returns `undefined` when no route declares one, so
the caller can bake an absent subset and skip the lookup entirely. Raises
`{invalid_rate_limit, Opts}` (from the config compiler) on a bad per-route
config, at listener init.
""".
-spec compile_rate_limits(routes()) -> route_rate_limits().
compile_rate_limits(Routes) when is_list(Routes) ->
    case [compile_rate_limit(R) || R <- Routes, is_rate_limited(R)] of
        [] -> undefined;
        Limits -> Limits
    end.

-spec is_rate_limited(route()) -> boolean().
is_rate_limited(#{rate_limit := _}) -> true;
is_rate_limited(_) -> false.

-spec compile_rate_limit(map()) ->
    {[segment()], method_lookup(), {pos_integer(), pos_integer(), pos_integer()}, binary()}.
compile_rate_limit(#{path := Path, rate_limit := Opts} = Route) when is_binary(Path) ->
    {
        compile_path(Path),
        compile_methods(maps:get(methods, Route, undefined)),
        roadrunner_rate_limit:compile_route_config(Opts),
        Path
    }.

-doc """
Find the per-route `rate_limit` for a request method + path, or `nomatch`.

First-match-wins over the compiled subset (declaration order), reusing the same
path + method matchers as `match/3`. A path-match whose method is not in the
route's allowlist keeps scanning, so a per-route limit only applies to the
methods that route declares; an exhausted scan returns `nomatch` and the caller
falls back to the listener-global limit.

A matched per-route limit **replaces** the listener-global one for that request,
it does not stack with it. A route declaring a budget larger than the global
limit therefore escapes the global limit entirely, which is the point of an
override but is worth stating: the global limit is a default, not a ceiling.
""".
-spec match_rate_limit(binary(), binary(), route_rate_limits()) ->
    {pos_integer(), pos_integer(), pos_integer(), binary()} | nomatch.
match_rate_limit(_Method, _Path, undefined) ->
    nomatch;
match_rate_limit(Method, Path, Limits) when is_binary(Method), is_binary(Path) ->
    match_rate_limit_1(Method, path_segments(Path), Limits).

-spec match_rate_limit_1(binary(), [binary()], [tuple()]) ->
    {pos_integer(), pos_integer(), pos_integer(), binary()} | nomatch.
match_rate_limit_1(_Method, _Segments, []) ->
    nomatch;
match_rate_limit_1(Method, Segments, [{Pattern, Methods, Units, Key} | Rest]) ->
    case match_pattern(Pattern, Segments, #{}) of
        no_match ->
            match_rate_limit_1(Method, Segments, Rest);
        _Bindings ->
            case method_allowed(Method, Methods) of
                true ->
                    {Rate, Cap, Cost} = Units,
                    {Rate, Cap, Cost, Key};
                false ->
                    match_rate_limit_1(Method, Segments, Rest)
            end
    end.

-doc """
Compile the per-route `max_body` overrides out of a route list.

Keeps only the map-form routes that carry a `max_body` key, pairing each route's
compiled path + method allowlist with its byte cap. Returns `undefined` when no
route declares one, so the caller can bake an absent subset and keep the global
limit. Raises `{invalid_route_max_body, Path, Value}` on a non-`non_neg_integer`
cap, at listener init.
""".
-spec compile_body_limits(routes()) -> route_body_limits().
compile_body_limits(Routes) when is_list(Routes) ->
    case [compile_body_limit(R) || R <- Routes, is_body_limited(R)] of
        [] -> undefined;
        Limits -> Limits
    end.

-spec is_body_limited(route()) -> boolean().
is_body_limited(#{max_body := _}) -> true;
is_body_limited(_) -> false.

-spec compile_body_limit(map()) -> {[segment()], method_lookup(), non_neg_integer()}.
compile_body_limit(#{path := Path, max_body := MaxBody} = Route) when
    is_binary(Path), is_integer(MaxBody), MaxBody >= 0
->
    {compile_path(Path), compile_methods(maps:get(methods, Route, undefined)), MaxBody};
compile_body_limit(#{path := Path, max_body := MaxBody}) ->
    error({invalid_route_max_body, Path, MaxBody}).

-doc """
Find the per-route `max_body` byte cap for a request method + path, or `nomatch`.

First-match-wins over the compiled subset, reusing the same path + method
matchers as `match/3`; a path-match whose method is not in the route's allowlist
keeps scanning. `nomatch` means the caller keeps the listener-global
`max_content_length`.

Where the cap takes effect differs by protocol. HTTP/1 and HTTP/2 bound what the
request buffers: h1 caps the body read, h2 resolves the route's cap once the
header block is decoded and enforces it as DATA frames arrive. HTTP/3 keeps its
QPACK header block raw until dispatch, so it cannot know the path while the body
accumulates; there the route cap is applied after accumulation (bounded by the
listener-global `max_content_length`) and changes the response rather than the
buffering.
""".
-spec match_body_limit(binary(), binary(), route_body_limits()) ->
    non_neg_integer() | nomatch.
match_body_limit(_Method, _Path, undefined) ->
    nomatch;
match_body_limit(Method, Path, Limits) when is_binary(Method), is_binary(Path) ->
    match_body_limit_1(Method, path_segments(Path), Limits).

-spec match_body_limit_1(binary(), [binary()], [tuple()]) -> non_neg_integer() | nomatch.
match_body_limit_1(_Method, _Segments, []) ->
    nomatch;
match_body_limit_1(Method, Segments, [{Pattern, Methods, MaxBody} | Rest]) ->
    case match_pattern(Pattern, Segments, #{}) of
        no_match ->
            match_body_limit_1(Method, Segments, Rest);
        _Bindings ->
            case method_allowed(Method, Methods) of
                true -> MaxBody;
                false -> match_body_limit_1(Method, Segments, Rest)
            end
    end.

-spec path_segments(binary()) -> [binary()].
path_segments(Path) ->
    binary:split(Path, persistent_term:get(?SLASH_CP_KEY), [global, trim_all]).

%% `-on_load` callback. Compiles the path-segment separator once at
%% module load into `persistent_term` so the hot path reads a constant.
-spec init_patterns() -> ok.
init_patterns() ->
    persistent_term:put(?SLASH_CP_KEY, binary:compile_pattern(~"/")),
    ok.
