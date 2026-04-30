-module(cactus_resp_tests).

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
        cactus_resp:text(200, ~"hello")
    ).

text_with_iolist_body_test() ->
    %% iolist body: content-length is the byte count, body passes through.
    {200, Headers, Body} = cactus_resp:text(200, [~"hel", ~"lo"]),
    ?assertEqual(~"5", proplists:get_value(~"content-length", Headers)),
    ?assertEqual([~"hel", ~"lo"], Body).

html_test() ->
    Body = ~"<h1>Hi</h1>",
    {200, Headers, Body} = cactus_resp:html(200, Body),
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
    {200, Headers, Body} = cactus_resp:json(200, Term),
    ?assertEqual(
        ~"application/json",
        proplists:get_value(~"content-type", Headers)
    ),
    Decoded = json:decode(iolist_to_binary(Body)),
    ?assertEqual(Term, Decoded).

redirect_test() ->
    ?assertEqual(
        {302,
            [
                {~"location", ~"/new"},
                {~"content-length", ~"0"}
            ],
            ~""},
        cactus_resp:redirect(302, ~"/new")
    ).

%% --- add_header/3 ---

add_header_prepends_test() ->
    Resp0 = cactus_resp:text(200, ~"hi"),
    Resp = cactus_resp:add_header(Resp0, ~"x-trace", ~"abc"),
    {200, [{~"x-trace", ~"abc"} | _], ~"hi"} = Resp.

add_header_flattens_iodata_value_test() ->
    Resp0 = cactus_resp:text(200, ~"hi"),
    {200, Headers, _} = cactus_resp:add_header(Resp0, ~"x-y", [~"a", $/, ~"b"]),
    ?assertEqual(~"a/b", proplists:get_value(~"x-y", Headers)).

%% --- set_cookie/4 ---

set_cookie_adds_set_cookie_header_test() ->
    Resp0 = cactus_resp:text(200, ~"hi"),
    Resp = cactus_resp:set_cookie(Resp0, ~"sid", ~"abc", #{path => ~"/", http_only => true}),
    {200, [{~"set-cookie", Cookie} | _], ~"hi"} = Resp,
    ?assertEqual(~"sid=abc; Path=/; HttpOnly", Cookie).

%% --- empty-body status shortcuts ---

no_content_test() ->
    ?assertEqual({204, [{~"content-length", ~"0"}], ~""}, cactus_resp:no_content()).

bad_request_test() ->
    ?assertEqual({400, [{~"content-length", ~"0"}], ~""}, cactus_resp:bad_request()).

unauthorized_test() ->
    ?assertEqual({401, [{~"content-length", ~"0"}], ~""}, cactus_resp:unauthorized()).

forbidden_test() ->
    ?assertEqual({403, [{~"content-length", ~"0"}], ~""}, cactus_resp:forbidden()).

not_found_test() ->
    ?assertEqual({404, [{~"content-length", ~"0"}], ~""}, cactus_resp:not_found()).

internal_error_test() ->
    ?assertEqual({500, [{~"content-length", ~"0"}], ~""}, cactus_resp:internal_error()).
