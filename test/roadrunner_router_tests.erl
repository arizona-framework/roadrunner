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

compile_rejects_wildcard_followed_by_a_literal_test() ->
    %% A segment after the wildcard is never reached by the match clauses, so
    %% the route could only ever be dead weight in the table.
    ?assertError(
        {invalid_route_path, ~"/foo/*rest/bar", wildcard_not_last},
        roadrunner_router:compile(
            [
                {~"/foo/*rest/bar", weird_handler},
                {~"/foo/*rest", normal_handler}
            ],
            []
        )
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

compile_rejects_multiple_wildcards_test() ->
    %% The wildcard match clause requires the wildcard segment to be last, so
    %% the second `*b` could only ever be read as a literal sitting after a
    %% wildcard. Rejected rather than registered as a route that never matches;
    %% allowing nested wildcards later stays a deliberate change.
    ?assertError(
        {invalid_route_path, ~"/*a/*b", wildcard_not_last},
        roadrunner_router:compile([{~"/*a/*b", h}], [])
    ).

compile_rejects_root_wildcard_followed_by_a_literal_test() ->
    %% Same constraint from the root: anything declared after a wildcard
    %% segment is unreachable.
    ?assertError(
        {invalid_route_path, ~"/*tail/post", wildcard_not_last},
        roadrunner_router:compile([{~"/*tail/post", h}], [])
    ).

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

compile_rejects_method_specific_route_below_an_all_methods_one_test() ->
    %% An all-methods route short-circuits every method on its path, so a later
    %% same-path method-specific route never gets a request.
    ?assertError(
        {unreachable_route, 2, ~"/x", [{1, ~"/x"}]},
        roadrunner_router:compile(
            [
                #{path => ~"/x", handler => catch_all},
                #{path => ~"/x", handler => only_post, methods => [~"POST"]}
            ],
            []
        )
    ).

%% =============================================================================
%% Route reachability — compile/2 rejects a route the entries above it already
%% answer in full, so a mis-ordered table fails at boot instead of 404-ing.
%% =============================================================================

compile_rejects_duplicate_path_test() ->
    ?assertError(
        {unreachable_route, 2, ~"/a", [{1, ~"/a"}]},
        roadrunner_router:compile([{~"/a", first_handler}, {~"/a", second_handler}], [])
    ).

compile_rejects_duplicate_root_path_test() ->
    %% Both compile to an empty segment list, so the walk bottoms out on two
    %% empty patterns and still reports the shadow.
    ?assertError(
        {unreachable_route, 2, ~"////", [{1, ~"/"}]},
        roadrunner_router:compile([{~"/", home_handler}, {~"////", root_handler}], [])
    ).

compile_rejects_route_swallowed_by_an_earlier_wildcard_test() ->
    %% The wildcard is often generated rather than typed (a framework expanding
    %% an asset route to `<Path>/*path`), so someone reordering two lines gets
    %% no visual cue that the one above carries a catch-all.
    ?assertError(
        {unreachable_route, 2, ~"/static/assets/*path", [{1, ~"/static/*path"}]},
        roadrunner_router:compile(
            [
                {~"/static/*path", site_handler},
                {~"/static/assets/*path", assets_handler}
            ],
            []
        )
    ).

compile_rejects_route_shadowed_by_a_non_adjacent_earlier_route_test() ->
    %% The shadower is two lines up with an unrelated route between them, and
    %% carries state, so the reported positions have to come from the table
    %% rather than from adjacency.
    ?assertError(
        {unreachable_route, 3, ~"/a", [{1, ~"/a"}]},
        roadrunner_router:compile(
            [
                {~"/a", first_handler, #{tier => primary}},
                {~"/b", second_handler},
                {~"/a", third_handler}
            ],
            []
        )
    ).

compile_rejects_trailing_slash_duplicate_test() ->
    %% `/a` and `/a/` compile to the same segment list, so the second is a
    %% duplicate rather than a route on a distinct path. The error says so.
    ?assertError(
        {unreachable_route, 2, ~"/a/", [{1, ~"/a"}]},
        roadrunner_router:compile([{~"/a", first_handler}, {~"/a/", second_handler}], [])
    ).

compile_rejects_method_route_below_a_covering_wildcard_test() ->
    %% Path coverage and method coverage compose: the wildcard answers every
    %% path below `/api` for every method, which includes this route's GET.
    ?assertError(
        {unreachable_route, 2, ~"/api/users", [{1, ~"/api/*p"}]},
        roadrunner_router:compile(
            [
                {~"/api/*p", api_handler},
                #{path => ~"/api/users", handler => users_handler, methods => [~"GET"]}
            ],
            []
        )
    ).

compile_rejects_method_union_across_different_path_shapes_test() ->
    %% The two routes above cover this one's path in different ways (a literal
    %% prefix with a capture, then two captures) and take one method each
    %% between them.
    ?assertError(
        {unreachable_route, 3, ~"/x/y", [{1, ~"/x/:id"}, {2, ~"/:a/:b"}]},
        roadrunner_router:compile(
            [
                #{path => ~"/x/:id", handler => get_handler, methods => [~"GET"]},
                #{path => ~"/:a/:b", handler => post_handler, methods => [~"POST"]},
                #{path => ~"/x/y", handler => rw_handler, methods => [~"GET", ~"POST"]}
            ],
            []
        )
    ).

compile_allows_route_a_covering_path_leaves_a_method_open_test() ->
    %% `/x/:id` covers `/x/y` but only answers GET, so the POST on the deeper
    %% route keeps it alive.
    Compiled = roadrunner_router:compile(
        [
            #{path => ~"/x/:id", handler => get_handler, methods => [~"GET"]},
            #{path => ~"/x/y", handler => rw_handler, methods => [~"GET", ~"POST"]}
        ],
        []
    ),
    ?assertEqual({ok, rw_handler, #{}, #{}}, match_no_pipeline(~"POST", ~"/x/y", Compiled)),
    ?assertEqual(
        {ok, get_handler, #{~"id" => ~"y"}, #{}}, match_no_pipeline(~"GET", ~"/x/y", Compiled)
    ).

compile_rejects_literal_below_a_covering_param_test() ->
    ?assertError(
        {unreachable_route, 2, ~"/users/me", [{1, ~"/users/:id"}]},
        roadrunner_router:compile(
            [{~"/users/:id", users_handler}, {~"/users/me", me_handler}],
            []
        )
    ).

compile_rejects_param_below_a_covering_param_test() ->
    %% Capture names narrow nothing — `/:a` and `/:b` match the same paths.
    ?assertError(
        {unreachable_route, 2, ~"/:b", [{1, ~"/:a"}]},
        roadrunner_router:compile([{~"/:a", first_handler}, {~"/:b", second_handler}], [])
    ).

compile_rejects_everything_below_a_root_wildcard_test() ->
    ?assertError(
        {unreachable_route, 2, ~"/", [{1, ~"/*all"}]},
        roadrunner_router:compile([{~"/*all", catchall_handler}, {~"/", home_handler}], [])
    ).

compile_rejects_wildcard_prefix_below_its_own_wildcard_test() ->
    %% `/static/*path` matches `/static` itself (empty remainder), so a bare
    %% `/static` written below it never gets there.
    ?assertError(
        {unreachable_route, 2, ~"/static", [{1, ~"/static/*path"}]},
        roadrunner_router:compile(
            [{~"/static/*path", static_handler}, {~"/static", index_handler}],
            []
        )
    ).

compile_allows_specific_route_above_a_wildcard_test() ->
    %% The same two routes in the working order: the specific one is reachable.
    Compiled = roadrunner_router:compile(
        [
            {~"/static/assets/*path", assets_handler},
            {~"/static/*path", site_handler}
        ],
        []
    ),
    ?assertEqual(
        {ok, assets_handler, #{~"path" => [~"app.js"]}, #{}},
        match_no_pipeline(~"/static/assets/app.js", Compiled)
    ),
    ?assertEqual(
        {ok, site_handler, #{~"path" => [~"logo.png"]}, #{}},
        match_no_pipeline(~"/static/logo.png", Compiled)
    ).

compile_allows_sibling_literals_test() ->
    Compiled = roadrunner_router:compile([{~"/a", a_handler}, {~"/b", b_handler}], []),
    ?assertEqual({ok, b_handler, #{}, #{}}, match_no_pipeline(~"/b", Compiled)).

compile_allows_deeper_route_below_a_shorter_one_test() ->
    Compiled = roadrunner_router:compile([{~"/a", a_handler}, {~"/a/b", ab_handler}], []),
    ?assertEqual({ok, ab_handler, #{}, #{}}, match_no_pipeline(~"/a/b", Compiled)).

compile_allows_wildcard_below_a_sibling_param_test() ->
    %% `/:a` takes exactly one segment; `/*p` also answers `/` and deeper
    %% paths, so it keeps work of its own.
    Compiled = roadrunner_router:compile(
        [{~"/:a", param_handler}, {~"/*p", catchall_handler}],
        []
    ),
    ?assertEqual({ok, param_handler, #{~"a" => ~"x"}, #{}}, match_no_pipeline(~"/x", Compiled)),
    ?assertEqual(
        {ok, catchall_handler, #{~"p" => [~"x", ~"y"]}, #{}},
        match_no_pipeline(~"/x/y", Compiled)
    ).

compile_allows_same_path_with_disjoint_methods_test() ->
    %% Same-path method dispatch: neither route can answer the other's method.
    Compiled = roadrunner_router:compile(
        [
            #{path => ~"/x", handler => get_handler, methods => [~"GET"]},
            #{path => ~"/x", handler => post_handler, methods => [~"POST"]}
        ],
        []
    ),
    ?assertEqual({ok, get_handler, #{}, #{}}, match_no_pipeline(~"GET", ~"/x", Compiled)),
    ?assertEqual({ok, post_handler, #{}, #{}}, match_no_pipeline(~"POST", ~"/x", Compiled)).

compile_rejects_same_path_with_a_method_subset_test() ->
    ?assertError(
        {unreachable_route, 2, ~"/x", [{1, ~"/x"}]},
        roadrunner_router:compile(
            [
                #{path => ~"/x", handler => rw_handler, methods => [~"GET", ~"POST"]},
                #{path => ~"/x", handler => ro_handler, methods => [~"GET"]}
            ],
            []
        )
    ).

compile_rejects_route_whose_methods_earlier_routes_cover_between_them_test() ->
    %% No single earlier route covers the third one, but the two above it do
    %% between them, so both are named.
    ?assertError(
        {unreachable_route, 3, ~"/x", [{1, ~"/x"}, {2, ~"/x"}]},
        roadrunner_router:compile(
            [
                #{path => ~"/x", handler => get_handler, methods => [~"GET"]},
                #{path => ~"/x", handler => post_handler, methods => [~"POST"]},
                #{path => ~"/x", handler => rw_handler, methods => [~"GET", ~"POST"]}
            ],
            []
        )
    ).

compile_allows_route_with_a_method_earlier_routes_leave_open_test() ->
    %% Same shape, but the last route also declares PUT — nothing above answers
    %% it, so it stays reachable.
    Compiled = roadrunner_router:compile(
        [
            #{path => ~"/x", handler => get_handler, methods => [~"GET"]},
            #{path => ~"/x", handler => post_handler, methods => [~"POST"]},
            #{path => ~"/x", handler => put_handler, methods => [~"GET", ~"PUT"]}
        ],
        []
    ),
    ?assertEqual({ok, put_handler, #{}, #{}}, match_no_pipeline(~"PUT", ~"/x", Compiled)).

compile_allows_all_methods_route_below_method_specific_ones_test() ->
    %% A route with no allowlist answers every method, and no finite set of
    %% earlier allowlists can exhaust that.
    Compiled = roadrunner_router:compile(
        [
            #{path => ~"/x", handler => get_handler, methods => [~"GET"]},
            {~"/x", catch_all_handler}
        ],
        []
    ),
    ?assertEqual({ok, get_handler, #{}, #{}}, match_no_pipeline(~"GET", ~"/x", Compiled)),
    ?assertEqual({ok, catch_all_handler, #{}, #{}}, match_no_pipeline(~"DELETE", ~"/x", Compiled)).

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
