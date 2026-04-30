-module(cactus_req_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Pure accessors over a cactus_http1:request() map.
%% =============================================================================

method_test() ->
    ?assertEqual(~"GET", cactus_req:method(sample_req())).

method_is_match_test() ->
    ?assertEqual(true, cactus_req:method_is(~"GET", sample_req())).

method_is_no_match_test() ->
    ?assertEqual(false, cactus_req:method_is(~"POST", sample_req())).

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

%% --- has_header/2 ---

has_header_present_test() ->
    ?assertEqual(true, cactus_req:has_header(~"host", sample_req())).

has_header_present_mixed_case_test() ->
    ?assertEqual(true, cactus_req:has_header(~"Host", sample_req())).

has_header_absent_test() ->
    ?assertEqual(false, cactus_req:has_header(~"x-missing", sample_req())).

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

%% --- body/1 ---

body_present_test() ->
    Req = (sample_req())#{body => ~"hello world"},
    ?assertEqual(~"hello world", cactus_req:body(Req)).

body_absent_returns_empty_test() ->
    %% A request map with no body field returns empty bytes.
    ?assertEqual(~"", cactus_req:body(sample_req())).

%% --- has_body/1 ---

has_body_present_test() ->
    Req = (sample_req())#{body => ~"hello"},
    ?assertEqual(true, cactus_req:has_body(Req)).

has_body_empty_returns_false_test() ->
    Req = (sample_req())#{body => ~""},
    ?assertEqual(false, cactus_req:has_body(Req)).

%% --- read_body/1,2 ---

read_body_auto_mode_returns_buffered_body_test() ->
    Req = (sample_req())#{body => ~"already buffered"},
    ?assertEqual({ok, ~"already buffered", Req}, cactus_req:read_body(Req)).

read_body_no_body_field_returns_empty_test() ->
    Req = sample_req(),
    ?assertEqual({ok, ~"", Req}, cactus_req:read_body(Req)).

read_body_manual_state_full_drain_test() ->
    BS = #{
        framing => {content_length, 5},
        buffered => ~"hello",
        bytes_read => 0,
        recv => fun() -> error(unused) end,
        max => 1000
    },
    Req = (sample_req())#{body_state => BS},
    {ok, Bytes, Req2} = cactus_req:read_body(Req),
    ?assertEqual(~"hello", Bytes),
    ?assertEqual(~"hello", cactus_req:body(Req2)).

read_body_manual_state_partial_returns_more_test() ->
    BS = #{
        framing => {content_length, 6},
        buffered => ~"abcdef",
        bytes_read => 0,
        recv => fun() -> error(unused) end,
        max => 1000
    },
    Req = (sample_req())#{body_state => BS},
    {more, First, Req2} = cactus_req:read_body(Req, #{length => 4}),
    ?assertEqual(~"abcd", First),
    {ok, Last, _Req3} = cactus_req:read_body(Req2, #{length => 4}),
    ?assertEqual(~"ef", Last).

read_body_manual_state_error_propagates_test() ->
    BS = #{
        framing => {content_length, 100},
        buffered => <<>>,
        bytes_read => 0,
        recv => fun() -> {error, closed} end,
        max => 1000
    },
    Req = (sample_req())#{body_state => BS},
    ?assertEqual({error, closed}, cactus_req:read_body(Req)).

has_body_absent_returns_false_test() ->
    ?assertEqual(false, cactus_req:has_body(sample_req())).

%% --- bindings/1 ---

bindings_present_test() ->
    Req = (sample_req())#{bindings => #{~"id" => ~"42"}},
    ?assertEqual(#{~"id" => ~"42"}, cactus_req:bindings(Req)).

bindings_absent_returns_empty_map_test() ->
    ?assertEqual(#{}, cactus_req:bindings(sample_req())).

%% --- peer/1 ---

peer_present_test() ->
    Req = (sample_req())#{peer => {{127, 0, 0, 1}, 54321}},
    ?assertEqual({{127, 0, 0, 1}, 54321}, cactus_req:peer(Req)).

peer_absent_returns_undefined_test() ->
    ?assertEqual(undefined, cactus_req:peer(sample_req())).

%% --- scheme/1 ---

scheme_http_test() ->
    Req = (sample_req())#{scheme => http},
    ?assertEqual(http, cactus_req:scheme(Req)).

scheme_https_test() ->
    Req = (sample_req())#{scheme => https},
    ?assertEqual(https, cactus_req:scheme(Req)).

scheme_absent_defaults_to_http_test() ->
    ?assertEqual(http, cactus_req:scheme(sample_req())).

%% --- route_opts/1 ---

route_opts_present_test() ->
    Req = (sample_req())#{route_opts => #{dir => ~"/var/www"}},
    ?assertEqual(#{dir => ~"/var/www"}, cactus_req:route_opts(Req)).

route_opts_absent_returns_undefined_test() ->
    ?assertEqual(undefined, cactus_req:route_opts(sample_req())).

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
