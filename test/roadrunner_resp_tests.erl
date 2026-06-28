-module(roadrunner_resp_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Convenience response builders
%% =============================================================================

text_test() ->
    ?assertEqual(
        {200,
            [
                {~"content-type", ~"text/plain; charset=utf-8"},
                {~"content-length", ~"5"}
            ],
            ~"hello"},
        roadrunner_resp:text(200, ~"hello")
    ).

text_with_iolist_body_test() ->
    %% iolist body: content-length is the byte count, body passes through.
    {200, Headers, Body} = roadrunner_resp:text(200, [~"hel", ~"lo"]),
    ?assertEqual(~"5", proplists:get_value(~"content-length", Headers)),
    ?assertEqual([~"hel", ~"lo"], Body).

html_test() ->
    Body = ~"<h1>Hi</h1>",
    {200, Headers, Body} = roadrunner_resp:html(200, Body),
    ?assertEqual(
        ~"text/html; charset=utf-8",
        proplists:get_value(~"content-type", Headers)
    ),
    ?assertEqual(
        integer_to_binary(byte_size(Body)),
        proplists:get_value(~"content-length", Headers)
    ).

json_test() ->
    %% Use binary keys — `json:decode/1` returns binary-keyed maps, so
    %% encoding atom-keyed input would round-trip to a different shape.
    Term = #{~"name" => ~"Alice", ~"age" => 30},
    {200, Headers, Body} = roadrunner_resp:json(200, Term),
    ?assertEqual(
        ~"application/json",
        proplists:get_value(~"content-type", Headers)
    ),
    Decoded = json:decode(iolist_to_binary(Body)),
    ?assertEqual(Term, Decoded).

ndjson_test() ->
    Items = [#{~"id" => 1}, #{~"id" => 2}],
    {200, Headers, Body} = roadrunner_resp:ndjson(200, Items),
    ?assertEqual(
        ~"application/x-ndjson",
        proplists:get_value(~"content-type", Headers)
    ),
    Bin = iolist_to_binary(Body),
    ?assertEqual(~"{\"id\":1}\n{\"id\":2}\n", Bin),
    %% Content-Length is the byte count of the framed lines.
    ?assertEqual(
        integer_to_binary(byte_size(Bin)),
        proplists:get_value(~"content-length", Headers)
    ),
    %% Each line round-trips as one JSON document.
    [L1, L2, <<>>] = binary:split(Bin, ~"\n", [global]),
    ?assertEqual(#{~"id" => 1}, json:decode(L1)),
    ?assertEqual(#{~"id" => 2}, json:decode(L2)).

ndjson_empty_list_test() ->
    %% No items → empty body, Content-Length 0.
    ?assertEqual(
        {200,
            [
                {~"content-type", ~"application/x-ndjson"},
                {~"content-length", ~"0"}
            ],
            []},
        roadrunner_resp:ndjson(200, [])
    ).

redirect_test() ->
    ?assertEqual(
        {302,
            [
                {~"location", ~"/new"},
                {~"content-length", ~"0"}
            ],
            ~""},
        roadrunner_resp:redirect(302, ~"/new")
    ).

%% --- add_header/3 ---

add_header_prepends_test() ->
    Resp0 = roadrunner_resp:text(200, ~"hi"),
    Resp = roadrunner_resp:add_header(Resp0, ~"x-trace", ~"abc"),
    {200, [{~"x-trace", ~"abc"} | _], ~"hi"} = Resp.

add_header_flattens_iodata_value_test() ->
    Resp0 = roadrunner_resp:text(200, ~"hi"),
    {200, Headers, _} = roadrunner_resp:add_header(Resp0, ~"x-y", [~"a", $/, ~"b"]),
    ?assertEqual(~"a/b", proplists:get_value(~"x-y", Headers)).

%% --- set_cookie/4 ---

set_cookie_adds_set_cookie_header_test() ->
    Resp0 = roadrunner_resp:text(200, ~"hi"),
    Resp = roadrunner_resp:set_cookie(Resp0, ~"sid", ~"abc", #{path => ~"/", http_only => true}),
    {200, [{~"set-cookie", Cookie} | _], ~"hi"} = Resp,
    ?assertEqual(~"sid=abc; Path=/; HttpOnly", Cookie).

%% --- empty-body status shortcuts ---

no_content_test() ->
    ?assertEqual({204, [{~"content-length", ~"0"}], ~""}, roadrunner_resp:no_content()).

bad_request_test() ->
    ?assertEqual({400, [{~"content-length", ~"0"}], ~""}, roadrunner_resp:bad_request()).

unauthorized_test() ->
    ?assertEqual({401, [{~"content-length", ~"0"}], ~""}, roadrunner_resp:unauthorized()).

forbidden_test() ->
    ?assertEqual({403, [{~"content-length", ~"0"}], ~""}, roadrunner_resp:forbidden()).

not_found_test() ->
    ?assertEqual({404, [{~"content-length", ~"0"}], ~""}, roadrunner_resp:not_found()).

method_not_allowed_test() ->
    %% 405 carries an `Allow` header (prepended, so it wins on lookup)
    %% listing the permitted methods comma-separated.
    ?assertEqual(
        {405, [{~"allow", ~"GET, POST"}, {~"content-length", ~"0"}], ~""},
        roadrunner_resp:method_not_allowed([~"GET", ~"POST"])
    ).

internal_error_test() ->
    ?assertEqual({500, [{~"content-length", ~"0"}], ~""}, roadrunner_resp:internal_error()).

status_with_arbitrary_code_test() ->
    %% 418 isn't in the named shortcuts.
    ?assertEqual({418, [{~"content-length", ~"0"}], ~""}, roadrunner_resp:status(418)),
    ?assertEqual({503, [{~"content-length", ~"0"}], ~""}, roadrunner_resp:status(503)).

status_with_headers_test() ->
    %% status/2 prepends caller headers ahead of the content-length, which
    %% stays present and authoritative on lookup.
    {503, Headers, ~""} = roadrunner_resp:status(503, [{~"retry-after", ~"30"}]),
    ?assertEqual(~"30", proplists:get_value(~"retry-after", Headers)),
    ?assertEqual(~"0", proplists:get_value(~"content-length", Headers)).

%% --- generic body/3,4 builder ---

body_binary_test() ->
    ?assertEqual(
        {200,
            [
                {~"content-type", ~"application/octet-stream"},
                {~"content-length", ~"5"}
            ],
            ~"hello"},
        roadrunner_resp:body(200, ~"application/octet-stream", ~"hello")
    ).

body_iolist_body_test() ->
    %% iolist body: content-length is the byte count via iolist_size.
    {200, Headers, Body} = roadrunner_resp:body(200, ~"text/csv", [~"a,", ~"b", $\n]),
    ?assertEqual(~"text/csv", proplists:get_value(~"content-type", Headers)),
    ?assertEqual(~"4", proplists:get_value(~"content-length", Headers)),
    ?assertEqual([~"a,", ~"b", $\n], Body).

body_with_headers_test() ->
    %% Extra headers are additive, after the authoritative content-type and
    %% content-length.
    {201, Headers, ~"x"} = roadrunner_resp:body(
        201, ~"text/plain", [{~"x-cache", ~"HIT"}], ~"x"
    ),
    ?assertEqual(~"text/plain", proplists:get_value(~"content-type", Headers)),
    ?assertEqual(~"1", proplists:get_value(~"content-length", Headers)),
    ?assertEqual(~"HIT", proplists:get_value(~"x-cache", Headers)),
    %% content-type/content-length come first, the caller header trails.
    ?assertMatch(
        [{~"content-type", _}, {~"content-length", _}, {~"x-cache", ~"HIT"}],
        Headers
    ).

%% --- header variants on the typed builders ---

text_with_headers_test() ->
    {200, Headers, ~"hi"} = roadrunner_resp:text(200, [{~"x-cache", ~"HIT"}], ~"hi"),
    ?assertEqual(~"text/plain; charset=utf-8", proplists:get_value(~"content-type", Headers)),
    ?assertEqual(~"2", proplists:get_value(~"content-length", Headers)),
    ?assertEqual(~"HIT", proplists:get_value(~"x-cache", Headers)).

html_with_headers_test() ->
    {200, Headers, ~"<p>x</p>"} = roadrunner_resp:html(
        200, [{~"x-cache", ~"HIT"}], ~"<p>x</p>"
    ),
    ?assertEqual(~"text/html; charset=utf-8", proplists:get_value(~"content-type", Headers)),
    ?assertEqual(~"8", proplists:get_value(~"content-length", Headers)),
    ?assertEqual(~"HIT", proplists:get_value(~"x-cache", Headers)).

json_with_headers_test() ->
    Term = #{~"name" => ~"Alice"},
    {200, Headers, Body} = roadrunner_resp:json(200, [{~"x-cache", ~"HIT"}], Term),
    ?assertEqual(~"application/json", proplists:get_value(~"content-type", Headers)),
    ?assertEqual(~"HIT", proplists:get_value(~"x-cache", Headers)),
    ?assertEqual(
        integer_to_binary(iolist_size(Body)),
        proplists:get_value(~"content-length", Headers)
    ),
    ?assertEqual(Term, json:decode(iolist_to_binary(Body))).

ndjson_with_headers_test() ->
    Items = [#{~"id" => 1}, #{~"id" => 2}],
    {200, Headers, Body} = roadrunner_resp:ndjson(200, [{~"x-cache", ~"HIT"}], Items),
    ?assertEqual(~"application/x-ndjson", proplists:get_value(~"content-type", Headers)),
    ?assertEqual(~"HIT", proplists:get_value(~"x-cache", Headers)),
    Bin = iolist_to_binary(Body),
    ?assertEqual(~"{\"id\":1}\n{\"id\":2}\n", Bin),
    ?assertEqual(
        integer_to_binary(byte_size(Bin)),
        proplists:get_value(~"content-length", Headers)
    ).

redirect_with_headers_test() ->
    %% Caller headers trail the location/content-length, which stay authoritative.
    {302, Headers, ~""} = roadrunner_resp:redirect(302, [{~"x-cache", ~"HIT"}], ~"/new"),
    ?assertEqual(~"/new", proplists:get_value(~"location", Headers)),
    ?assertEqual(~"0", proplists:get_value(~"content-length", Headers)),
    ?assertEqual(~"HIT", proplists:get_value(~"x-cache", Headers)),
    ?assertMatch(
        [{~"location", ~"/new"}, {~"content-length", ~"0"}, {~"x-cache", ~"HIT"}],
        Headers
    ).
