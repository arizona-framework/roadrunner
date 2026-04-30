-module(cactus_req_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Pure accessors over a cactus_http1:request() map.
%% =============================================================================

method_test() ->
    ?assertEqual(~"GET", cactus_req:method(sample_req())).

version_test() ->
    ?assertEqual({1, 1}, cactus_req:version(sample_req())).

headers_test() ->
    ?assertEqual(
        [{~"host", ~"example.com"}, {~"accept", ~"*/*"}],
        cactus_req:headers(sample_req())
    ).

%% --- path / qs ---

path_no_query_test() ->
    ?assertEqual(~"/foo", cactus_req:path(sample_req_target(~"/foo"))).

path_with_query_test() ->
    ?assertEqual(~"/foo", cactus_req:path(sample_req_target(~"/foo?a=1&b=2"))).

qs_no_query_test() ->
    ?assertEqual(~"", cactus_req:qs(sample_req_target(~"/foo"))).

qs_with_query_test() ->
    ?assertEqual(~"a=1&b=2", cactus_req:qs(sample_req_target(~"/foo?a=1&b=2"))).

qs_empty_after_question_test() ->
    %% "/foo?" — split returns ["/foo", ""], qs is empty.
    ?assertEqual(~"", cactus_req:qs(sample_req_target(~"/foo?"))).

%% --- header/2 ---

header_found_test() ->
    ?assertEqual(~"example.com", cactus_req:header(~"host", sample_req())).

header_not_found_test() ->
    ?assertEqual(undefined, cactus_req:header(~"x-missing", sample_req())).

header_case_insensitive_test() ->
    %% Caller passes mixed case; lookup finds the lowercased entry.
    ?assertEqual(~"example.com", cactus_req:header(~"Host", sample_req())).

%% --- parse_qs/1 ---

parse_qs_empty_test() ->
    ?assertEqual([], cactus_req:parse_qs(sample_req_target(~"/foo"))).

parse_qs_single_test() ->
    ?assertEqual(
        [{~"a", ~"1"}],
        cactus_req:parse_qs(sample_req_target(~"/foo?a=1"))
    ).

parse_qs_multiple_test() ->
    ?assertEqual(
        [{~"a", ~"1"}, {~"b", ~"2"}],
        cactus_req:parse_qs(sample_req_target(~"/foo?a=1&b=2"))
    ).

parse_qs_decodes_percent_test() ->
    ?assertEqual(
        [{~"q", ~"hello world"}],
        cactus_req:parse_qs(sample_req_target(~"/foo?q=hello%20world"))
    ).

%% --- parse_cookies/1 ---

parse_cookies_no_header_test() ->
    ?assertEqual([], cactus_req:parse_cookies(sample_req())).

parse_cookies_single_test() ->
    Req = with_cookie(~"sid=abc"),
    ?assertEqual([{~"sid", ~"abc"}], cactus_req:parse_cookies(Req)).

parse_cookies_multiple_test() ->
    Req = with_cookie(~"sid=abc; theme=dark"),
    ?assertEqual(
        [{~"sid", ~"abc"}, {~"theme", ~"dark"}],
        cactus_req:parse_cookies(Req)
    ).

%% --- fixtures ---

sample_req() ->
    #{
        method => ~"GET",
        target => ~"/foo?a=1",
        version => {1, 1},
        headers => [{~"host", ~"example.com"}, {~"accept", ~"*/*"}]
    }.

sample_req_target(Target) ->
    (sample_req())#{target := Target}.

with_cookie(CookieValue) ->
    Req = sample_req(),
    Req#{headers := [{~"cookie", CookieValue} | maps:get(headers, Req)]}.
