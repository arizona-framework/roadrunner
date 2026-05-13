-module(roadrunner_default_handler_tests).

-include_lib("eunit/include/eunit.hrl").

handle_returns_404_with_quickstart_body_test() ->
    Req = #{},
    {Resp, Req2} = roadrunner_default_handler:handle(Req),
    ?assertEqual(Req, Req2),
    {Status, Headers, Body} = Resp,
    ?assertEqual(404, Status),
    ?assertEqual(
        ~"text/plain; charset=utf-8",
        proplists:get_value(~"content-type", Headers)
    ),
    ?assertEqual(
        integer_to_binary(byte_size(Body)),
        proplists:get_value(~"content-length", Headers)
    ),
    %% Body is the quickstart blurb — verify a couple of stable
    %% landmark phrases instead of the whole text so the test
    %% survives wording polish.
    {match, _} = re:run(Body, ~"no routes configured"),
    {match, _} = re:run(Body, ~"start_listener").
