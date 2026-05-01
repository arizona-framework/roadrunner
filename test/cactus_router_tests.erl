-module(cactus_router_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% compile/1 + match/2 — literal paths
%% =============================================================================

compile_empty_test() ->
    Compiled = cactus_router:compile([]),
    ?assertEqual(not_found, cactus_router:match(~"/", Compiled)).

match_root_path_test() ->
    Compiled = cactus_router:compile([{~"/", home_handler, undefined}]),
    ?assertEqual({ok, home_handler, #{}, undefined}, cactus_router:match(~"/", Compiled)).

match_literal_paths_test() ->
    Compiled = cactus_router:compile([
        {~"/", home_handler, undefined},
        {~"/about", about_handler, undefined},
        {~"/users", users_handler, undefined}
    ]),
    ?assertEqual({ok, home_handler, #{}, undefined}, cactus_router:match(~"/", Compiled)),
    ?assertEqual({ok, about_handler, #{}, undefined}, cactus_router:match(~"/about", Compiled)),
    ?assertEqual({ok, users_handler, #{}, undefined}, cactus_router:match(~"/users", Compiled)).

match_missing_path_returns_not_found_test() ->
    Compiled = cactus_router:compile([{~"/", home_handler, undefined}]),
    ?assertEqual(not_found, cactus_router:match(~"/nope", Compiled)).

match_is_case_sensitive_test() ->
    %% Paths are case-sensitive per RFC 3986 — `/About` is not `/about`.
    Compiled = cactus_router:compile([{~"/about", about_handler, undefined}]),
    ?assertEqual(not_found, cactus_router:match(~"/About", Compiled)).

%% =============================================================================
%% Parameterized segments
%% =============================================================================

match_single_param_test() ->
    Compiled = cactus_router:compile([{~"/users/:id", users_handler, undefined}]),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~"42"}, undefined},
        cactus_router:match(~"/users/42", Compiled)
    ).

match_multiple_params_test() ->
    Compiled = cactus_router:compile([{~"/users/:id/posts/:post_id", post_handler, undefined}]),
    ?assertEqual(
        {ok, post_handler, #{~"id" => ~"42", ~"post_id" => ~"7"}, undefined},
        cactus_router:match(~"/users/42/posts/7", Compiled)
    ).

match_too_few_segments_test() ->
    Compiled = cactus_router:compile([{~"/users/:id", users_handler, undefined}]),
    ?assertEqual(not_found, cactus_router:match(~"/users", Compiled)).

match_too_many_segments_test() ->
    Compiled = cactus_router:compile([{~"/users/:id", users_handler, undefined}]),
    ?assertEqual(not_found, cactus_router:match(~"/users/42/extra", Compiled)).

match_wrong_literal_segment_test() ->
    Compiled = cactus_router:compile([{~"/users/:id", users_handler, undefined}]),
    ?assertEqual(not_found, cactus_router:match(~"/posts/42", Compiled)).

match_first_route_wins_test() ->
    %% Earlier routes are tried first — a literal entry shadows a wildcard
    %% one written below it.
    Compiled = cactus_router:compile([
        {~"/users/me", me_handler, undefined},
        {~"/users/:id", users_handler, undefined}
    ]),
    ?assertEqual(
        {ok, me_handler, #{}, undefined},
        cactus_router:match(~"/users/me", Compiled)
    ),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~"42"}, undefined},
        cactus_router:match(~"/users/42", Compiled)
    ).

%% =============================================================================
%% Wildcard segments (*name)
%% =============================================================================

match_wildcard_captures_remainder_test() ->
    Compiled = cactus_router:compile([{~"/static/*path", static_handler, undefined}]),
    ?assertEqual(
        {ok, static_handler, #{~"path" => [~"css", ~"main.css"]}, undefined},
        cactus_router:match(~"/static/css/main.css", Compiled)
    ).

match_wildcard_captures_single_segment_test() ->
    Compiled = cactus_router:compile([{~"/static/*path", static_handler, undefined}]),
    ?assertEqual(
        {ok, static_handler, #{~"path" => [~"file.txt"]}, undefined},
        cactus_router:match(~"/static/file.txt", Compiled)
    ).

match_wildcard_captures_empty_remainder_test() ->
    %% Pattern has prefix + wildcard; URL stops at the prefix — wildcard
    %% binds to an empty list.
    Compiled = cactus_router:compile([{~"/static/*path", static_handler, undefined}]),
    ?assertEqual(
        {ok, static_handler, #{~"path" => []}, undefined},
        cactus_router:match(~"/static", Compiled)
    ).

match_root_wildcard_test() ->
    Compiled = cactus_router:compile([{~"/*all", catchall_handler, undefined}]),
    ?assertEqual(
        {ok, catchall_handler, #{~"all" => [~"a", ~"b", ~"c"]}, undefined},
        cactus_router:match(~"/a/b/c", Compiled)
    ),
    ?assertEqual(
        {ok, catchall_handler, #{~"all" => []}, undefined},
        cactus_router:match(~"/", Compiled)
    ).

match_route_with_opts_test() ->
    %% 3-tuple route attaches an opaque per-route opts term that comes
    %% back from match/2.
    Compiled = cactus_router:compile([
        {~"/static/*path", static_handler, #{dir => ~"/var/www"}}
    ]),
    ?assertEqual(
        {ok, static_handler, #{~"path" => [~"a.css"]}, #{dir => ~"/var/www"}},
        cactus_router:match(~"/static/a.css", Compiled)
    ).

match_wildcard_not_last_falls_through_test() ->
    %% A wildcard mid-pattern doesn't match — extra literal after it never
    %% reaches a matching clause, and a fallback route still works.
    Compiled = cactus_router:compile([
        {~"/foo/*rest/bar", weird_handler, undefined},
        {~"/foo/*rest", normal_handler, undefined}
    ]),
    ?assertEqual(
        {ok, normal_handler, #{~"rest" => [~"x", ~"y"]}, undefined},
        cactus_router:match(~"/foo/x/y", Compiled)
    ).

%% =============================================================================
%% Adversarial path edge cases.
%% =============================================================================

match_double_slash_collapses_to_single_test() ->
    %% Lenient: `path_segments/1` uses `trim_all` so `//` is the same as
    %% `/`. Probably what most apps expect; document via assertion.
    Compiled = cactus_router:compile([{~"/users/:id", users_handler, undefined}]),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~"42"}, undefined},
        cactus_router:match(~"/users//42", Compiled)
    ).

match_trailing_slash_treated_as_no_slash_test() ->
    Compiled = cactus_router:compile([{~"/about", about_handler, undefined}]),
    ?assertEqual(
        {ok, about_handler, #{}, undefined},
        cactus_router:match(~"/about/", Compiled)
    ).

match_empty_path_matches_root_route_test() ->
    %% `<<>>` and `<<"/">>` both produce zero segments — equivalent.
    Compiled = cactus_router:compile([{~"/", home_handler, undefined}]),
    ?assertEqual({ok, home_handler, #{}, undefined}, cactus_router:match(~"", Compiled)).

match_param_captures_percent_encoded_segment_test() ->
    %% Router does not percent-decode — handlers see the raw segment.
    %% Documented as "literal segments must match byte-exactly".
    Compiled = cactus_router:compile([{~"/users/:id", users_handler, undefined}]),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~"joe%20bob"}, undefined},
        cactus_router:match(~"/users/joe%20bob", Compiled)
    ).

match_param_with_special_chars_in_segment_test() ->
    %% A segment containing `:`, `*`, `.` etc. is just bytes — no special
    %% meaning at match time (only the pattern's leading char matters).
    Compiled = cactus_router:compile([{~"/users/:id", users_handler, undefined}]),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~":star*dot."}, undefined},
        cactus_router:match(~"/users/:star*dot.", Compiled)
    ).

match_route_path_with_only_slashes_test() ->
    %% Pattern of all slashes compiles to an empty segment list — only
    %% empty paths match.
    Compiled = cactus_router:compile([{~"////", root_handler, undefined}]),
    ?assertEqual(
        {ok, root_handler, #{}, undefined},
        cactus_router:match(~"/", Compiled)
    ),
    ?assertEqual(
        not_found,
        cactus_router:match(~"/anything", Compiled)
    ).
