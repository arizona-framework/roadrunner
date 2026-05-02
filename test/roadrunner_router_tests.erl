-module(roadrunner_router_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% compile/1 + match/2 — literal paths
%% =============================================================================

compile_empty_test() ->
    Compiled = roadrunner_router:compile([]),
    ?assertEqual(not_found, roadrunner_router:match(~"/", Compiled)).

match_root_path_test() ->
    Compiled = roadrunner_router:compile([{~"/", home_handler, undefined}]),
    ?assertEqual({ok, home_handler, #{}, undefined}, roadrunner_router:match(~"/", Compiled)).

match_literal_paths_test() ->
    Compiled = roadrunner_router:compile([
        {~"/", home_handler, undefined},
        {~"/about", about_handler, undefined},
        {~"/users", users_handler, undefined}
    ]),
    ?assertEqual({ok, home_handler, #{}, undefined}, roadrunner_router:match(~"/", Compiled)),
    ?assertEqual({ok, about_handler, #{}, undefined}, roadrunner_router:match(~"/about", Compiled)),
    ?assertEqual({ok, users_handler, #{}, undefined}, roadrunner_router:match(~"/users", Compiled)).

match_missing_path_returns_not_found_test() ->
    Compiled = roadrunner_router:compile([{~"/", home_handler, undefined}]),
    ?assertEqual(not_found, roadrunner_router:match(~"/nope", Compiled)).

match_is_case_sensitive_test() ->
    %% Paths are case-sensitive per RFC 3986 — `/About` is not `/about`.
    Compiled = roadrunner_router:compile([{~"/about", about_handler, undefined}]),
    ?assertEqual(not_found, roadrunner_router:match(~"/About", Compiled)).

%% =============================================================================
%% Parameterized segments
%% =============================================================================

match_single_param_test() ->
    Compiled = roadrunner_router:compile([{~"/users/:id", users_handler, undefined}]),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~"42"}, undefined},
        roadrunner_router:match(~"/users/42", Compiled)
    ).

match_multiple_params_test() ->
    Compiled = roadrunner_router:compile([{~"/users/:id/posts/:post_id", post_handler, undefined}]),
    ?assertEqual(
        {ok, post_handler, #{~"id" => ~"42", ~"post_id" => ~"7"}, undefined},
        roadrunner_router:match(~"/users/42/posts/7", Compiled)
    ).

match_too_few_segments_test() ->
    Compiled = roadrunner_router:compile([{~"/users/:id", users_handler, undefined}]),
    ?assertEqual(not_found, roadrunner_router:match(~"/users", Compiled)).

match_too_many_segments_test() ->
    Compiled = roadrunner_router:compile([{~"/users/:id", users_handler, undefined}]),
    ?assertEqual(not_found, roadrunner_router:match(~"/users/42/extra", Compiled)).

match_wrong_literal_segment_test() ->
    Compiled = roadrunner_router:compile([{~"/users/:id", users_handler, undefined}]),
    ?assertEqual(not_found, roadrunner_router:match(~"/posts/42", Compiled)).

match_first_route_wins_test() ->
    %% Earlier routes are tried first — a literal entry shadows a wildcard
    %% one written below it.
    Compiled = roadrunner_router:compile([
        {~"/users/me", me_handler, undefined},
        {~"/users/:id", users_handler, undefined}
    ]),
    ?assertEqual(
        {ok, me_handler, #{}, undefined},
        roadrunner_router:match(~"/users/me", Compiled)
    ),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~"42"}, undefined},
        roadrunner_router:match(~"/users/42", Compiled)
    ).

%% =============================================================================
%% Wildcard segments (*name)
%% =============================================================================

match_wildcard_captures_remainder_test() ->
    Compiled = roadrunner_router:compile([{~"/static/*path", static_handler, undefined}]),
    ?assertEqual(
        {ok, static_handler, #{~"path" => [~"css", ~"main.css"]}, undefined},
        roadrunner_router:match(~"/static/css/main.css", Compiled)
    ).

match_wildcard_captures_single_segment_test() ->
    Compiled = roadrunner_router:compile([{~"/static/*path", static_handler, undefined}]),
    ?assertEqual(
        {ok, static_handler, #{~"path" => [~"file.txt"]}, undefined},
        roadrunner_router:match(~"/static/file.txt", Compiled)
    ).

match_wildcard_captures_empty_remainder_test() ->
    %% Pattern has prefix + wildcard; URL stops at the prefix — wildcard
    %% binds to an empty list.
    Compiled = roadrunner_router:compile([{~"/static/*path", static_handler, undefined}]),
    ?assertEqual(
        {ok, static_handler, #{~"path" => []}, undefined},
        roadrunner_router:match(~"/static", Compiled)
    ).

match_root_wildcard_test() ->
    Compiled = roadrunner_router:compile([{~"/*all", catchall_handler, undefined}]),
    ?assertEqual(
        {ok, catchall_handler, #{~"all" => [~"a", ~"b", ~"c"]}, undefined},
        roadrunner_router:match(~"/a/b/c", Compiled)
    ),
    ?assertEqual(
        {ok, catchall_handler, #{~"all" => []}, undefined},
        roadrunner_router:match(~"/", Compiled)
    ).

match_route_with_opts_test() ->
    %% 3-tuple route attaches an opaque per-route opts term that comes
    %% back from match/2.
    Compiled = roadrunner_router:compile([
        {~"/static/*path", static_handler, #{dir => ~"/var/www"}}
    ]),
    ?assertEqual(
        {ok, static_handler, #{~"path" => [~"a.css"]}, #{dir => ~"/var/www"}},
        roadrunner_router:match(~"/static/a.css", Compiled)
    ).

match_wildcard_not_last_falls_through_test() ->
    %% A wildcard mid-pattern doesn't match — extra literal after it never
    %% reaches a matching clause, and a fallback route still works.
    Compiled = roadrunner_router:compile([
        {~"/foo/*rest/bar", weird_handler, undefined},
        {~"/foo/*rest", normal_handler, undefined}
    ]),
    ?assertEqual(
        {ok, normal_handler, #{~"rest" => [~"x", ~"y"]}, undefined},
        roadrunner_router:match(~"/foo/x/y", Compiled)
    ).

%% =============================================================================
%% Adversarial path edge cases.
%% =============================================================================

match_double_slash_collapses_to_single_test() ->
    %% Lenient: `path_segments/1` uses `trim_all` so `//` is the same as
    %% `/`. Probably what most apps expect; document via assertion.
    Compiled = roadrunner_router:compile([{~"/users/:id", users_handler, undefined}]),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~"42"}, undefined},
        roadrunner_router:match(~"/users//42", Compiled)
    ).

match_trailing_slash_treated_as_no_slash_test() ->
    Compiled = roadrunner_router:compile([{~"/about", about_handler, undefined}]),
    ?assertEqual(
        {ok, about_handler, #{}, undefined},
        roadrunner_router:match(~"/about/", Compiled)
    ).

match_empty_path_matches_root_route_test() ->
    %% `<<>>` and `<<"/">>` both produce zero segments — equivalent.
    Compiled = roadrunner_router:compile([{~"/", home_handler, undefined}]),
    ?assertEqual({ok, home_handler, #{}, undefined}, roadrunner_router:match(~"", Compiled)).

match_param_captures_percent_encoded_segment_test() ->
    %% Router does not percent-decode — handlers see the raw segment.
    %% Documented as "literal segments must match byte-exactly".
    Compiled = roadrunner_router:compile([{~"/users/:id", users_handler, undefined}]),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~"joe%20bob"}, undefined},
        roadrunner_router:match(~"/users/joe%20bob", Compiled)
    ).

match_param_with_special_chars_in_segment_test() ->
    %% A segment containing `:`, `*`, `.` etc. is just bytes — no special
    %% meaning at match time (only the pattern's leading char matters).
    Compiled = roadrunner_router:compile([{~"/users/:id", users_handler, undefined}]),
    ?assertEqual(
        {ok, users_handler, #{~"id" => ~":star*dot."}, undefined},
        roadrunner_router:match(~"/users/:star*dot.", Compiled)
    ).

match_route_path_with_only_slashes_test() ->
    %% Pattern of all slashes compiles to an empty segment list — only
    %% empty paths match.
    Compiled = roadrunner_router:compile([{~"////", root_handler, undefined}]),
    ?assertEqual(
        {ok, root_handler, #{}, undefined},
        roadrunner_router:match(~"/", Compiled)
    ),
    ?assertEqual(
        not_found,
        roadrunner_router:match(~"/anything", Compiled)
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
    Compiled = roadrunner_router:compile([{~"/:", h, undefined}]),
    ?assertEqual(
        {ok, h, #{<<>> => ~"foo"}, undefined},
        roadrunner_router:match(~"/foo", Compiled)
    ).

match_empty_wildcard_name_binds_remainder_under_empty_binary_test() ->
    %% Same shape for `/*` — captures the tail as a list under `<<>>`.
    Compiled = roadrunner_router:compile([{~"/*", h, undefined}]),
    ?assertEqual(
        {ok, h, #{<<>> => [~"a", ~"b", ~"c"]}, undefined},
        roadrunner_router:match(~"/a/b/c", Compiled)
    ).

match_duplicate_param_names_keep_last_binding_test() ->
    %% A pattern repeats the same `:x` — bindings is a map, so the
    %% second value silently overwrites the first. Footgun; locking
    %% in the behavior so we don't accidentally start raising.
    Compiled = roadrunner_router:compile([{~"/:x/:x", h, undefined}]),
    ?assertEqual(
        {ok, h, #{~"x" => ~"second"}, undefined},
        roadrunner_router:match(~"/first/second", Compiled)
    ).

match_multiple_wildcards_pattern_does_not_match_test() ->
    %% Wildcard match clause requires the wildcard segment to be last.
    %% A pattern with two wildcards therefore can never match — the
    %% second is treated as a literal. Document so a future change to
    %% allow nested wildcards is intentional.
    Compiled = roadrunner_router:compile([{~"/*a/*b", h, undefined}]),
    ?assertEqual(not_found, roadrunner_router:match(~"/x/y/z", Compiled)).

match_wildcard_followed_by_literal_does_not_match_test() ->
    %% Same constraint: anything declared after a wildcard segment is
    %% unreachable.
    Compiled = roadrunner_router:compile([{~"/*tail/post", h, undefined}]),
    ?assertEqual(not_found, roadrunner_router:match(~"/a/b/post", Compiled)).

match_nul_byte_in_segment_is_captured_raw_test() ->
    %% NUL is just a byte to the router — the request-line parser
    %% rejects NUL upstream so a real wire request can't reach here
    %% with a NUL, but a caller invoking `match/2` directly with a
    %% poisoned binary gets it back verbatim. Documented as caller's
    %% responsibility to validate.
    Compiled = roadrunner_router:compile([{~"/admin/:p", h, undefined}]),
    ?assertEqual(
        {ok, h, #{~"p" => <<"sec", 0, "ret">>}, undefined},
        roadrunner_router:match(<<"/admin/sec", 0, "ret">>, Compiled)
    ).

match_path_without_leading_slash_resolves_same_as_with_test() ->
    %% `binary:split(_, ~"/", [global, trim_all])` strips empty leading
    %% segments, so `~"users/joe"` and `~"/users/joe"` both produce
    %% `[~"users", ~"joe"]` and match identically.
    Compiled = roadrunner_router:compile([{~"/users/:id", h, undefined}]),
    Expected = {ok, h, #{~"id" => ~"joe"}, undefined},
    ?assertEqual(Expected, roadrunner_router:match(~"/users/joe", Compiled)),
    ?assertEqual(Expected, roadrunner_router:match(~"users/joe", Compiled)).
