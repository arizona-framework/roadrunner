-module(cactus_router_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% compile/1 + match/2 — literal path matching
%% =============================================================================

compile_empty_test() ->
    Compiled = cactus_router:compile([]),
    ?assertEqual(not_found, cactus_router:match(~"/", Compiled)).

compile_single_route_test() ->
    Compiled = cactus_router:compile([{~"/", home_handler}]),
    ?assertEqual({ok, home_handler}, cactus_router:match(~"/", Compiled)).

compile_multiple_routes_test() ->
    Compiled = cactus_router:compile([
        {~"/", home_handler},
        {~"/about", about_handler},
        {~"/users", users_handler}
    ]),
    ?assertEqual({ok, home_handler}, cactus_router:match(~"/", Compiled)),
    ?assertEqual({ok, about_handler}, cactus_router:match(~"/about", Compiled)),
    ?assertEqual({ok, users_handler}, cactus_router:match(~"/users", Compiled)).

match_missing_path_returns_not_found_test() ->
    Compiled = cactus_router:compile([{~"/", home_handler}]),
    ?assertEqual(not_found, cactus_router:match(~"/nope", Compiled)).

match_is_case_sensitive_test() ->
    %% Paths are case-sensitive per RFC 3986 — `/About` is not `/about`.
    Compiled = cactus_router:compile([{~"/about", about_handler}]),
    ?assertEqual(not_found, cactus_router:match(~"/About", Compiled)).
