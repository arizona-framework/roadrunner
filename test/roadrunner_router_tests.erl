-module(roadrunner_router_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% compile/1 + match/3 — literal paths
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

%% =============================================================================
%% Percent-decoded captures
%% =============================================================================

match_param_is_percent_decoded_test() ->
    Compiled = roadrunner_router:compile([{~"/users/:name", users_handler}], []),
    ?assertEqual(
        {ok, users_handler, #{~"name" => <<"café"/utf8>>}, #{}},
        match_no_pipeline(~"/users/caf%C3%A9", Compiled)
    ).

match_param_decodes_encoded_slash_within_segment_test() ->
    %% `%2F` is not a raw `/`, so the router does not split on it — it stays one
    %% captured segment that decodes to a literal `/` in the value.
    Compiled = roadrunner_router:compile([{~"/files/:name", files_handler}], []),
    ?assertEqual(
        {ok, files_handler, #{~"name" => ~"a/b"}, #{}},
        match_no_pipeline(~"/files/a%2Fb", Compiled)
    ).

match_param_malformed_escape_kept_raw_test() ->
    %% A bad %-escape (non-hex) is left as the raw segment rather than failing
    %% the match on attacker-controllable input.
    Compiled = roadrunner_router:compile([{~"/users/:name", users_handler}], []),
    ?assertEqual(
        {ok, users_handler, #{~"name" => ~"a%ZZ"}, #{}},
        match_no_pipeline(~"/users/a%ZZ", Compiled)
    ).

match_param_literal_plus_preserved_test() ->
    %% No `+` -> space: that is a query-string convention. A `+` in a path
    %% segment is literal data.
    Compiled = roadrunner_router:compile([{~"/tags/:tag", tags_handler}], []),
    ?assertEqual(
        {ok, tags_handler, #{~"tag" => ~"a+b"}, #{}},
        match_no_pipeline(~"/tags/a+b", Compiled)
    ).

match_wildcard_segments_are_percent_decoded_test() ->
    %% Each captured wildcard segment decodes independently; an encoded slash
    %% stays within its segment (the split already happened on raw `/`).
    Compiled = roadrunner_router:compile([{~"/static/*path", static_handler}], []),
    ?assertEqual(
        {ok, static_handler, #{~"path" => [<<"café"/utf8>>, ~"a/b"]}, #{}},
        match_no_pipeline(~"/static/caf%C3%A9/a%2Fb", Compiled)
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
            #{
                path => ~"/admin/*p",
                handler => admin_handler,
                middlewares => [roadrunner_test_middlewares, roadrunner_test_init_middleware]
            }
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
                middlewares => [roadrunner_test_middlewares]
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
            #{
                path => ~"/api/*p",
                handler => api_handler,
                middlewares => [roadrunner_test_middlewares]
            }
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
    %% The router percent-decodes captured segments, so `%20` becomes a space
    %% (consistent with query params).
    Compiled = roadrunner_router:compile([{~"/users/:id", users_handler}], []),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~"joe bob"}, #{}},
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
    %% with a NUL, but a caller invoking `match/3` directly with a
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
    %% fun in the 4th element of `match/3`'s return. Behavior is
    %% covered by `roadrunner_middleware_tests`.
    Compiled = roadrunner_router:compile(
        [
            {~"/", h},
            {~"/x", h, undefined},
            #{path => ~"/y", handler => h, middlewares => [roadrunner_test_middlewares]}
        ],
        []
    ),
    [
        ?assert(is_function(P, 1))
     || Path <- [~"/", ~"/x", ~"/y"],
        {ok, _, _, P, _} <- [roadrunner_router:match(~"GET", Path, Compiled)]
    ].

compile_bakes_state_into_pipeline_test() ->
    %% State attached at compile time is injected onto the req by the
    %% pipeline's outermost closure, so middlewares + handler see it.
    %% The fixture handler echoes `roadrunner_req:state(Req)` as the
    %% response body.
    Compiled = roadrunner_router:compile(
        [{~"/", roadrunner_state_echo_handler, #{my => state}}], []
    ),
    {ok, _, _, Pipeline, _State} = roadrunner_router:match(~"GET", ~"/", Compiled),
    {{200, _, Body}, _} = Pipeline(empty_req()),
    ?assertEqual(#{my => state}, binary_to_term(Body)).

match_exposes_state_as_5th_element_test() ->
    %% State is also surfaced statically as the 5th element so callers
    %% that need to introspect a route can read it without running
    %% the pipeline.
    Compiled = roadrunner_router:compile(
        [
            {~"/none", h},
            {~"/legacy", h, undefined},
            {~"/three", h, #{role => admin}},
            #{path => ~"/map_no_state", handler => h},
            #{path => ~"/map_with_state", handler => h, state => keep_me}
        ],
        []
    ),
    [
        ?assertEqual(Expected, element(5, roadrunner_router:match(~"GET", P, Compiled)))
     || {P, Expected} <- [
            {~"/none", undefined},
            {~"/legacy", undefined},
            {~"/three", #{role => admin}},
            {~"/map_no_state", undefined},
            {~"/map_with_state", keep_me}
        ]
    ].

%% =============================================================================
%% Method-aware routing (map-form `methods` allowlist)
%% =============================================================================

match_method_in_allowlist_test() ->
    Compiled = roadrunner_router:compile(
        [#{path => ~"/account", handler => acct_handler, methods => [~"POST"]}], []
    ),
    ?assertEqual(
        {ok, acct_handler, #{}, #{}},
        match_no_pipeline(~"POST", ~"/account", Compiled)
    ).

match_method_not_in_allowlist_returns_405_test() ->
    Compiled = roadrunner_router:compile(
        [#{path => ~"/account", handler => acct_handler, methods => [~"POST"]}], []
    ),
    ?assertEqual(
        {method_not_allowed, [~"POST"]},
        roadrunner_router:match(~"GET", ~"/account", Compiled)
    ).

match_no_methods_key_answers_every_method_test() ->
    %% A route with no `methods` allowlist accepts any verb.
    Compiled = roadrunner_router:compile(
        [#{path => ~"/any", handler => any_handler}], []
    ),
    [
        ?assertEqual(
            {ok, any_handler, #{}, #{}},
            match_no_pipeline(M, ~"/any", Compiled)
        )
     || M <- [~"GET", ~"POST", ~"DELETE", ~"PROPFIND"]
    ].

match_same_path_dispatches_on_method_test() ->
    %% Two routes share a path with disjoint methods — the verb selects
    %% the handler (REST-style dispatch).
    Compiled = roadrunner_router:compile(
        [
            #{path => ~"/users", handler => users_index, methods => [~"GET"]},
            #{path => ~"/users", handler => users_create, methods => [~"POST"]}
        ],
        []
    ),
    ?assertEqual(
        {ok, users_index, #{}, #{}},
        match_no_pipeline(~"GET", ~"/users", Compiled)
    ),
    ?assertEqual(
        {ok, users_create, #{}, #{}},
        match_no_pipeline(~"POST", ~"/users", Compiled)
    ).

match_405_allow_unions_same_path_methods_test() ->
    %% A method matching neither same-path route yields a 405 whose Allow
    %% set is the sorted, de-duplicated union — sorted regardless of the
    %% order the methods were declared in (here `HEAD` before `GET`).
    Compiled = roadrunner_router:compile(
        [
            #{path => ~"/users", handler => users_index, methods => [~"HEAD", ~"GET"]},
            #{path => ~"/users", handler => users_create, methods => [~"GET", ~"POST"]}
        ],
        []
    ),
    ?assertEqual(
        {method_not_allowed, [~"GET", ~"HEAD", ~"POST"]},
        roadrunner_router:match(~"DELETE", ~"/users", Compiled)
    ).

match_method_mismatch_with_no_path_match_is_not_found_test() ->
    %% A disallowed method only yields 405 when some path matched; an
    %% unknown path is still a 404, not a 405.
    Compiled = roadrunner_router:compile(
        [#{path => ~"/account", handler => acct_handler, methods => [~"POST"]}], []
    ),
    ?assertEqual(not_found, roadrunner_router:match(~"GET", ~"/nope", Compiled)).

compile_rejects_empty_methods_list_test() ->
    %% An empty `methods` (a route that answers nothing) is a config error.
    ?assertError(
        {invalid_route_methods, []},
        roadrunner_router:compile([#{path => ~"/x", handler => h, methods => []}], [])
    ).

compile_rejects_non_binary_methods_test() ->
    %% Atom methods would never match the binary wire method — raise loudly.
    ?assertError(
        {invalid_route_methods, [get, post]},
        roadrunner_router:compile([#{path => ~"/x", handler => h, methods => [get, post]}], [])
    ).

match_all_methods_route_shadows_later_specific_test() ->
    %% Declaration order wins: an all-methods route on a path short-circuits
    %% before a later same-path method-specific route is considered.
    Compiled = roadrunner_router:compile(
        [
            #{path => ~"/x", handler => catch_all},
            #{path => ~"/x", handler => only_post, methods => [~"POST"]}
        ],
        []
    ),
    ?assertEqual(
        {ok, catch_all, #{}, #{}},
        match_no_pipeline(~"POST", ~"/x", Compiled)
    ),
    ?assertEqual(
        {ok, catch_all, #{}, #{}},
        match_no_pipeline(~"GET", ~"/x", Compiled)
    ).

%% --- helpers ---

%% Drop the pipeline (4th element) and state (5th) so the handler
%% module + bindings can be asserted with `?assertEqual`. The
%% pipeline is funs-are-not-comparable, and state has its own
%% dedicated test (`match_exposes_state_as_5th_element_test`).
%% Defaults the method to GET — the path-matching tests use routes with
%% no `methods` allowlist, so every method (incl. GET) is accepted.
match_no_pipeline(Path, Compiled) ->
    match_no_pipeline(~"GET", Path, Compiled).

match_no_pipeline(Method, Path, Compiled) ->
    case roadrunner_router:match(Method, Path, Compiled) of
        {ok, Mod, Bindings, _Pipeline, _State} -> {ok, Mod, Bindings, #{}};
        Other -> Other
    end.

empty_req() ->
    #{method => ~"GET", target => ~"/", version => {1, 1}, headers => []}.

%% =============================================================================
%% compile_rate_limits/1 + match_rate_limit/3 — per-route rate-limit overrides
%% =============================================================================

rate_limits_none_is_undefined_test() ->
    %% No route declares a rate_limit → undefined (the gate skips the lookup).
    ?assertEqual(
        undefined,
        roadrunner_router:compile_rate_limits([{~"/", h}, #{path => ~"/x", handler => h}])
    ).

rate_limits_match_hit_test() ->
    Limits = roadrunner_router:compile_rate_limits([
        #{path => ~"/login", handler => h, rate_limit => #{rate => 1}}
    ]),
    %% rate 1, burst/period default → {1, 1000, 1000}, keyed on the path binary.
    ?assertEqual(
        {1, 1000, 1000, ~"/login"},
        roadrunner_router:match_rate_limit(~"POST", ~"/login", Limits)
    ).

rate_limits_match_miss_test() ->
    Limits = roadrunner_router:compile_rate_limits([
        #{path => ~"/login", handler => h, rate_limit => #{rate => 1}}
    ]),
    ?assertEqual(nomatch, roadrunner_router:match_rate_limit(~"GET", ~"/other", Limits)).

rate_limits_undefined_subset_is_nomatch_test() ->
    ?assertEqual(nomatch, roadrunner_router:match_rate_limit(~"GET", ~"/login", undefined)).

rate_limits_method_specific_test() ->
    %% A method allowlist scopes the override; other methods fall through.
    Limits = roadrunner_router:compile_rate_limits([
        #{path => ~"/login", handler => h, methods => [~"POST"], rate_limit => #{rate => 1}}
    ]),
    ?assertMatch(
        {1, 1000, 1000, ~"/login"}, roadrunner_router:match_rate_limit(~"POST", ~"/login", Limits)
    ),
    ?assertEqual(nomatch, roadrunner_router:match_rate_limit(~"GET", ~"/login", Limits)).

rate_limits_param_path_test() ->
    Limits = roadrunner_router:compile_rate_limits([
        #{path => ~"/users/:id", handler => h, rate_limit => #{rate => 5}}
    ]),
    ?assertMatch(
        {5, 5000, 1000, ~"/users/:id"},
        roadrunner_router:match_rate_limit(~"GET", ~"/users/42", Limits)
    ).

rate_limits_first_match_wins_test() ->
    Limits = roadrunner_router:compile_rate_limits([
        #{path => ~"/a", handler => h, rate_limit => #{rate => 1}},
        #{path => ~"/a", handler => h, rate_limit => #{rate => 9}}
    ]),
    ?assertMatch({1, _, _, ~"/a"}, roadrunner_router:match_rate_limit(~"GET", ~"/a", Limits)).

rate_limits_bad_config_raises_test() ->
    ?assertError(
        {invalid_rate_limit, _},
        roadrunner_router:compile_rate_limits([
            #{path => ~"/x", handler => h, rate_limit => #{rate => 0}}
        ])
    ).

%% =============================================================================
%% compile_body_limits/1 + match_body_limit/3 — per-route body-size overrides
%% =============================================================================

body_limits_none_is_undefined_test() ->
    ?assertEqual(
        undefined,
        roadrunner_router:compile_body_limits([{~"/", h}, #{path => ~"/x", handler => h}])
    ).

body_limits_match_hit_test() ->
    Limits = roadrunner_router:compile_body_limits([
        #{path => ~"/login", handler => h, max_body => 65536}
    ]),
    ?assertEqual(65536, roadrunner_router:match_body_limit(~"POST", ~"/login", Limits)).

body_limits_match_miss_test() ->
    Limits = roadrunner_router:compile_body_limits([
        #{path => ~"/login", handler => h, max_body => 65536}
    ]),
    ?assertEqual(nomatch, roadrunner_router:match_body_limit(~"GET", ~"/other", Limits)).

body_limits_undefined_subset_is_nomatch_test() ->
    ?assertEqual(nomatch, roadrunner_router:match_body_limit(~"GET", ~"/login", undefined)).

body_limits_method_specific_test() ->
    Limits = roadrunner_router:compile_body_limits([
        #{path => ~"/upload", handler => h, methods => [~"POST"], max_body => 1024}
    ]),
    ?assertEqual(1024, roadrunner_router:match_body_limit(~"POST", ~"/upload", Limits)),
    ?assertEqual(nomatch, roadrunner_router:match_body_limit(~"GET", ~"/upload", Limits)).

body_limits_zero_allowed_test() ->
    %% max_body => 0 (reject any body) is valid.
    Limits = roadrunner_router:compile_body_limits([
        #{path => ~"/nobody", handler => h, max_body => 0}
    ]),
    ?assertEqual(0, roadrunner_router:match_body_limit(~"GET", ~"/nobody", Limits)).

body_limits_param_path_test() ->
    Limits = roadrunner_router:compile_body_limits([
        #{path => ~"/users/:id", handler => h, max_body => 4096}
    ]),
    ?assertEqual(4096, roadrunner_router:match_body_limit(~"PUT", ~"/users/7", Limits)).

body_limits_bad_value_raises_test() ->
    ?assertError(
        {invalid_route_max_body, ~"/x", -1},
        roadrunner_router:compile_body_limits([#{path => ~"/x", handler => h, max_body => -1}])
    ).

body_limits_non_integer_raises_test() ->
    ?assertError(
        {invalid_route_max_body, ~"/x", big},
        roadrunner_router:compile_body_limits([#{path => ~"/x", handler => h, max_body => big}])
    ).
