-module(cactus_router_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% compile/1 + match/2 — literal paths
%% =============================================================================

compile_empty_test() ->
    Compiled = cactus_router:compile([]),
    ?assertEqual(not_found, cactus_router:match(~"/", Compiled)).

match_root_path_test() ->
    Compiled = cactus_router:compile([{~"/", home_handler}]),
    ?assertEqual({ok, home_handler, #{}}, cactus_router:match(~"/", Compiled)).

match_literal_paths_test() ->
    Compiled = cactus_router:compile([
        {~"/", home_handler},
        {~"/about", about_handler},
        {~"/users", users_handler}
    ]),
    ?assertEqual({ok, home_handler, #{}}, cactus_router:match(~"/", Compiled)),
    ?assertEqual({ok, about_handler, #{}}, cactus_router:match(~"/about", Compiled)),
    ?assertEqual({ok, users_handler, #{}}, cactus_router:match(~"/users", Compiled)).

match_missing_path_returns_not_found_test() ->
    Compiled = cactus_router:compile([{~"/", home_handler}]),
    ?assertEqual(not_found, cactus_router:match(~"/nope", Compiled)).

match_is_case_sensitive_test() ->
    %% Paths are case-sensitive per RFC 3986 — `/About` is not `/about`.
    Compiled = cactus_router:compile([{~"/about", about_handler}]),
    ?assertEqual(not_found, cactus_router:match(~"/About", Compiled)).

%% =============================================================================
%% Parameterized segments
%% =============================================================================

match_single_param_test() ->
    Compiled = cactus_router:compile([{~"/users/:id", users_handler}]),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~"42"}},
        cactus_router:match(~"/users/42", Compiled)
    ).

match_multiple_params_test() ->
    Compiled = cactus_router:compile([{~"/users/:id/posts/:post_id", post_handler}]),
    ?assertEqual(
        {ok, post_handler, #{~"id" => ~"42", ~"post_id" => ~"7"}},
        cactus_router:match(~"/users/42/posts/7", Compiled)
    ).

match_too_few_segments_test() ->
    Compiled = cactus_router:compile([{~"/users/:id", users_handler}]),
    ?assertEqual(not_found, cactus_router:match(~"/users", Compiled)).

match_too_many_segments_test() ->
    Compiled = cactus_router:compile([{~"/users/:id", users_handler}]),
    ?assertEqual(not_found, cactus_router:match(~"/users/42/extra", Compiled)).

match_wrong_literal_segment_test() ->
    Compiled = cactus_router:compile([{~"/users/:id", users_handler}]),
    ?assertEqual(not_found, cactus_router:match(~"/posts/42", Compiled)).

match_first_route_wins_test() ->
    %% Earlier routes are tried first — a literal entry shadows a wildcard
    %% one written below it.
    Compiled = cactus_router:compile([
        {~"/users/me", me_handler},
        {~"/users/:id", users_handler}
    ]),
    ?assertEqual(
        {ok, me_handler, #{}},
        cactus_router:match(~"/users/me", Compiled)
    ),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~"42"}},
        cactus_router:match(~"/users/42", Compiled)
    ).
