-module(roadrunner_router_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% compile/1 + match/2 — literal paths
%% =============================================================================

compile_empty_test() ->
    Compiled = roadrunner_router:compile([], []),
    ?assertEqual(not_found, match_no_pipeline(~"/", Compiled)).

match_root_path_test() ->
    Compiled = roadrunner_router:compile([{~"/", home_handler}], []),
    ?assertEqual({ok, home_handler, #{}, #{}}, match_no_pipeline(~"/", Compiled)).

match_literal_paths_test() ->
    Compiled = roadrunner_router:compile(
        [
            {~"/", home_handler},
            {~"/about", about_handler},
            {~"/users", users_handler}
        ],
        []
    ),
    ?assertEqual({ok, home_handler, #{}, #{}}, match_no_pipeline(~"/", Compiled)),
    ?assertEqual({ok, about_handler, #{}, #{}}, match_no_pipeline(~"/about", Compiled)),
    ?assertEqual({ok, users_handler, #{}, #{}}, match_no_pipeline(~"/users", Compiled)).

match_missing_path_returns_not_found_test() ->
    Compiled = roadrunner_router:compile([{~"/", home_handler}], []),
    ?assertEqual(not_found, match_no_pipeline(~"/nope", Compiled)).

match_is_case_sensitive_test() ->
    %% Paths are case-sensitive per RFC 3986 — `/About` is not `/about`.
    Compiled = roadrunner_router:compile([{~"/about", about_handler}], []),
    ?assertEqual(not_found, match_no_pipeline(~"/About", Compiled)).

%% =============================================================================
%% Parameterized segments
%% =============================================================================

match_single_param_test() ->
    Compiled = roadrunner_router:compile([{~"/users/:id", users_handler}], []),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~"42"}, #{}},
        match_no_pipeline(~"/users/42", Compiled)
    ).

match_multiple_params_test() ->
    Compiled = roadrunner_router:compile([{~"/users/:id/posts/:post_id", post_handler}], []),
    ?assertEqual(
        {ok, post_handler, #{~"id" => ~"42", ~"post_id" => ~"7"}, #{}},
        match_no_pipeline(~"/users/42/posts/7", Compiled)
    ).

match_too_few_segments_test() ->
    Compiled = roadrunner_router:compile([{~"/users/:id", users_handler}], []),
    ?assertEqual(not_found, match_no_pipeline(~"/users", Compiled)).

match_too_many_segments_test() ->
    Compiled = roadrunner_router:compile([{~"/users/:id", users_handler}], []),
    ?assertEqual(not_found, match_no_pipeline(~"/users/42/extra", Compiled)).

match_wrong_literal_segment_test() ->
    Compiled = roadrunner_router:compile([{~"/users/:id", users_handler}], []),
    ?assertEqual(not_found, match_no_pipeline(~"/posts/42", Compiled)).

match_first_route_wins_test() ->
    %% Earlier routes are tried first — a literal entry shadows a wildcard
    %% one written below it.
    Compiled = roadrunner_router:compile(
        [
            {~"/users/me", me_handler},
            {~"/users/:id", users_handler}
        ],
        []
    ),
    ?assertEqual(
        {ok, me_handler, #{}, #{}},
        match_no_pipeline(~"/users/me", Compiled)
    ),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~"42"}, #{}},
        match_no_pipeline(~"/users/42", Compiled)
    ).

%% =============================================================================
%% Wildcard segments (*name)
%% =============================================================================

match_wildcard_captures_remainder_test() ->
    Compiled = roadrunner_router:compile([{~"/static/*path", static_handler}], []),
    ?assertEqual(
        {ok, static_handler, #{~"path" => [~"css", ~"main.css"]}, #{}},
        match_no_pipeline(~"/static/css/main.css", Compiled)
    ).

match_wildcard_captures_single_segment_test() ->
    Compiled = roadrunner_router:compile([{~"/static/*path", static_handler}], []),
    ?assertEqual(
        {ok, static_handler, #{~"path" => [~"file.txt"]}, #{}},
        match_no_pipeline(~"/static/file.txt", Compiled)
    ).

match_wildcard_captures_empty_remainder_test() ->
    %% Pattern has prefix + wildcard; URL stops at the prefix — wildcard
    %% binds to an empty list.
    Compiled = roadrunner_router:compile([{~"/static/*path", static_handler}], []),
    ?assertEqual(
        {ok, static_handler, #{~"path" => []}, #{}},
        match_no_pipeline(~"/static", Compiled)
    ).

match_root_wildcard_test() ->
    Compiled = roadrunner_router:compile([{~"/*all", catchall_handler}], []),
    ?assertEqual(
        {ok, catchall_handler, #{~"all" => [~"a", ~"b", ~"c"]}, #{}},
        match_no_pipeline(~"/a/b/c", Compiled)
    ),
    ?assertEqual(
        {ok, catchall_handler, #{~"all" => []}, #{}},
        match_no_pipeline(~"/", Compiled)
    ).

match_route_with_state_test() ->
    %% 3-tuple route attaches per-handler state. State is baked into
    %% the pipeline closure (verified behaviorally by
    %% `compile_bakes_state_into_pipeline_test`); the structural test
    %% here just confirms the route resolves to the right handler +
    %% bindings.
    Compiled = roadrunner_router:compile(
        [
            {~"/static/*path", static_handler, #{dir => ~"/var/www"}}
        ],
        []
    ),
    ?assertEqual(
        {ok, static_handler, #{~"path" => [~"a.css"]}, #{}},
        match_no_pipeline(~"/static/a.css", Compiled)
    ).

match_two_tuple_route_returns_empty_cfg_test() ->
    %% 2-tuple shorthand: empty route cfg map.
    Compiled = roadrunner_router:compile([{~"/", home_handler}], []),
    ?assertEqual(
        {ok, home_handler, #{}, #{}},
        match_no_pipeline(~"/", Compiled)
    ).

match_two_tuple_with_params_test() ->
    Compiled = roadrunner_router:compile([{~"/users/:id", users_handler}], []),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~"42"}, #{}},
        match_no_pipeline(~"/users/42", Compiled)
    ).

match_mixed_two_and_three_tuple_routes_test() ->
    Compiled = roadrunner_router:compile(
        [
            {~"/", home_handler},
            {~"/static/*path", static_handler, #{dir => ~"/var/www"}}
        ],
        []
    ),
    ?assertEqual(
        {ok, home_handler, #{}, #{}},
        match_no_pipeline(~"/", Compiled)
    ),
    ?assertEqual(
        {ok, static_handler, #{~"path" => [~"a.css"]}, #{}},
        match_no_pipeline(~"/static/a.css", Compiled)
    ).

%% =============================================================================
%% Map-form route entries
%% =============================================================================

match_map_route_minimum_test() ->
    %% `#{path, handler}` — no state, no middlewares; cfg map is empty.
    Compiled = roadrunner_router:compile(
        [
            #{path => ~"/", handler => home_handler}
        ],
        []
    ),
    ?assertEqual(
        {ok, home_handler, #{}, #{}},
        match_no_pipeline(~"/", Compiled)
    ).

match_map_route_with_state_test() ->
    Compiled = roadrunner_router:compile(
        [
            #{path => ~"/users/:id", handler => users_handler, state => #{role => admin}}
        ],
        []
    ),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~"42"}, #{}},
        match_no_pipeline(~"/users/42", Compiled)
    ).

match_map_route_with_middlewares_test() ->
    %% Map-form route with middlewares: cfg carries `pipeline` post-compile;
    %% the per-route mws are baked into it. Behavior (mws actually fire) is
    %% covered end-to-end in `roadrunner_middleware_tests`.
    Compiled = roadrunner_router:compile(
        [
            #{path => ~"/admin/*p", handler => admin_handler, middlewares => [auth_mw, log_mw]}
        ],
        []
    ),
    ?assertEqual(
        {ok, admin_handler, #{~"p" => [~"x"]}, #{}},
        match_no_pipeline(~"/admin/x", Compiled)
    ).

match_map_route_with_state_and_middlewares_test() ->
    Compiled = roadrunner_router:compile(
        [
            #{
                path => ~"/api/:resource",
                handler => api_handler,
                state => #{db => primary},
                middlewares => [auth_mw]
            }
        ],
        []
    ),
    ?assertEqual(
        {ok, api_handler, #{~"resource" => ~"users"}, #{}},
        match_no_pipeline(~"/api/users", Compiled)
    ).

match_mixed_tuple_and_map_routes_test() ->
    %% Tuple and map entries coexist; each carries its own cfg.
    Compiled = roadrunner_router:compile(
        [
            {~"/", home_handler},
            {~"/about", about_handler, ~"hello"},
            #{path => ~"/api/*p", handler => api_handler, middlewares => [auth_mw]}
        ],
        []
    ),
    ?assertEqual(
        {ok, home_handler, #{}, #{}},
        match_no_pipeline(~"/", Compiled)
    ),
    ?assertEqual(
        {ok, about_handler, #{}, #{}},
        match_no_pipeline(~"/about", Compiled)
    ),
    ?assertEqual(
        {ok, api_handler, #{~"p" => [~"users"]}, #{}},
        match_no_pipeline(~"/api/users", Compiled)
    ).

match_wildcard_not_last_falls_through_test() ->
    %% A wildcard mid-pattern doesn't match — extra literal after it never
    %% reaches a matching clause, and a fallback route still works.
    Compiled = roadrunner_router:compile(
        [
            {~"/foo/*rest/bar", weird_handler},
            {~"/foo/*rest", normal_handler}
        ],
        []
    ),
    ?assertEqual(
        {ok, normal_handler, #{~"rest" => [~"x", ~"y"]}, #{}},
        match_no_pipeline(~"/foo/x/y", Compiled)
    ).

%% =============================================================================
%% Adversarial path edge cases.
%% =============================================================================

match_double_slash_collapses_to_single_test() ->
    %% Lenient: `path_segments/1` uses `trim_all` so `//` is the same as
    %% `/`. Probably what most apps expect; document via assertion.
    Compiled = roadrunner_router:compile([{~"/users/:id", users_handler}], []),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~"42"}, #{}},
        match_no_pipeline(~"/users//42", Compiled)
    ).

match_trailing_slash_treated_as_no_slash_test() ->
    Compiled = roadrunner_router:compile([{~"/about", about_handler}], []),
    ?assertEqual(
        {ok, about_handler, #{}, #{}},
        match_no_pipeline(~"/about/", Compiled)
    ).

match_empty_path_matches_root_route_test() ->
    %% `<<>>` and `<<"/">>` both produce zero segments — equivalent.
    Compiled = roadrunner_router:compile([{~"/", home_handler}], []),
    ?assertEqual({ok, home_handler, #{}, #{}}, match_no_pipeline(~"", Compiled)).

match_param_captures_percent_encoded_segment_test() ->
    %% Router does not percent-decode — handlers see the raw segment.
    %% Documented as "literal segments must match byte-exactly".
    Compiled = roadrunner_router:compile([{~"/users/:id", users_handler}], []),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~"joe%20bob"}, #{}},
        match_no_pipeline(~"/users/joe%20bob", Compiled)
    ).

match_param_with_special_chars_in_segment_test() ->
    %% A segment containing `:`, `*`, `.` etc. is just bytes — no special
    %% meaning at match time (only the pattern's leading char matters).
    Compiled = roadrunner_router:compile([{~"/users/:id", users_handler}], []),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~":star*dot."}, #{}},
        match_no_pipeline(~"/users/:star*dot.", Compiled)
    ).

match_route_path_with_only_slashes_test() ->
    %% Pattern of all slashes compiles to an empty segment list — only
    %% empty paths match.
    Compiled = roadrunner_router:compile([{~"////", root_handler}], []),
    ?assertEqual(
        {ok, root_handler, #{}, #{}},
        match_no_pipeline(~"/", Compiled)
    ),
    ?assertEqual(
        not_found,
        match_no_pipeline(~"/anything", Compiled)
    ).

%% =============================================================================
%% Adversarial / corner cases — document observable behavior so regressions
%% are caught at the router boundary instead of leaking into handlers.
%% =============================================================================

match_empty_param_name_binds_under_empty_binary_test() ->
    %% `/:` parses as `{param, <<>>}`. The capture goes under the empty
    %% binary key — surprising but harmless; documenting the behavior so a
    %% future "reject empty param name" change is a deliberate decision,
    %% not a silent break.
    Compiled = roadrunner_router:compile([{~"/:", h}], []),
    ?assertEqual(
        {ok, h, #{<<>> => ~"foo"}, #{}},
        match_no_pipeline(~"/foo", Compiled)
    ).

match_empty_wildcard_name_binds_remainder_under_empty_binary_test() ->
    %% Same shape for `/*` — captures the tail as a list under `<<>>`.
    Compiled = roadrunner_router:compile([{~"/*", h}], []),
    ?assertEqual(
        {ok, h, #{<<>> => [~"a", ~"b", ~"c"]}, #{}},
        match_no_pipeline(~"/a/b/c", Compiled)
    ).

match_duplicate_param_names_keep_last_binding_test() ->
    %% A pattern repeats the same `:x` — bindings is a map, so the
    %% second value silently overwrites the first. Footgun; locking
    %% in the behavior so we don't accidentally start raising.
    Compiled = roadrunner_router:compile([{~"/:x/:x", h}], []),
    ?assertEqual(
        {ok, h, #{~"x" => ~"second"}, #{}},
        match_no_pipeline(~"/first/second", Compiled)
    ).

match_multiple_wildcards_pattern_does_not_match_test() ->
    %% Wildcard match clause requires the wildcard segment to be last.
    %% A pattern with two wildcards therefore can never match — the
    %% second is treated as a literal. Document so a future change to
    %% allow nested wildcards is intentional.
    Compiled = roadrunner_router:compile([{~"/*a/*b", h}], []),
    ?assertEqual(not_found, match_no_pipeline(~"/x/y/z", Compiled)).

match_wildcard_followed_by_literal_does_not_match_test() ->
    %% Same constraint: anything declared after a wildcard segment is
    %% unreachable.
    Compiled = roadrunner_router:compile([{~"/*tail/post", h}], []),
    ?assertEqual(not_found, match_no_pipeline(~"/a/b/post", Compiled)).

match_nul_byte_in_segment_is_captured_raw_test() ->
    %% NUL is just a byte to the router — the request-line parser
    %% rejects NUL upstream so a real wire request can't reach here
    %% with a NUL, but a caller invoking `match/2` directly with a
    %% poisoned binary gets it back verbatim. Documented as caller's
    %% responsibility to validate.
    Compiled = roadrunner_router:compile([{~"/admin/:p", h}], []),
    ?assertEqual(
        {ok, h, #{~"p" => <<"sec", 0, "ret">>}, #{}},
        match_no_pipeline(<<"/admin/sec", 0, "ret">>, Compiled)
    ).

match_path_without_leading_slash_resolves_same_as_with_test() ->
    %% `binary:split(_, ~"/", [global, trim_all])` strips empty leading
    %% segments, so `~"users/joe"` and `~"/users/joe"` both produce
    %% `[~"users", ~"joe"]` and match identically.
    Compiled = roadrunner_router:compile([{~"/users/:id", h}], []),
    Expected = {ok, h, #{~"id" => ~"joe"}, #{}},
    ?assertEqual(Expected, match_no_pipeline(~"/users/joe", Compiled)),
    ?assertEqual(Expected, match_no_pipeline(~"users/joe", Compiled)).

%% =============================================================================
%% Pipeline shape + state injection (the post-compile 4th element is the
%% pre-composed `next()` fun; state on 3-tuple / map-with-state routes is
%% injected onto the req before the chain runs)
%% =============================================================================

compile_returns_callable_pipeline_test() ->
    %% Every compiled route, regardless of shape, ends with a 1-arity
    %% fun in the 4th element of `match/2`'s return. Behavior is
    %% covered by `roadrunner_middleware_tests`.
    Compiled = roadrunner_router:compile(
        [
            {~"/", h},
            {~"/x", h, undefined},
            #{path => ~"/y", handler => h, middlewares => [auth_mw]}
        ],
        []
    ),
    [
        ?assert(is_function(P, 1))
     || Path <- [~"/", ~"/x", ~"/y"],
        {ok, _, _, P} <- [roadrunner_router:match(Path, Compiled)]
    ].

compile_bakes_state_into_pipeline_test() ->
    %% State attached at compile time is injected onto the req by the
    %% pipeline's outermost closure, so middlewares + handler see it.
    %% The fixture handler echoes `roadrunner_req:state(Req)` as the
    %% response body.
    Compiled = roadrunner_router:compile(
        [{~"/", roadrunner_state_echo_handler, #{my => state}}], []
    ),
    {ok, _, _, Pipeline} = roadrunner_router:match(~"/", Compiled),
    {{200, _, Body}, _} = Pipeline(empty_req()),
    ?assertEqual(#{my => state}, binary_to_term(Body)).

%% --- helpers ---

%% Drop the 4th element (the pipeline fun, funs-are-not-comparable) so
%% the handler module + bindings can be asserted with `?assertEqual`.
%% State injection is covered separately by
%% `compile_bakes_state_into_pipeline_test`.
match_no_pipeline(Path, Compiled) ->
    case roadrunner_router:match(Path, Compiled) of
        {ok, Mod, Bindings, _Pipeline} -> {ok, Mod, Bindings, #{}};
        Other -> Other
    end.

empty_req() ->
    #{method => ~"GET", target => ~"/", version => {1, 1}, headers => []}.
