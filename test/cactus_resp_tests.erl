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
