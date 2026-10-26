-module(roadrunner_respond_writer_tests).
-include_lib("eunit/include/eunit.hrl").

%% `roadrunner_respond_writer` driven with a stand-in protocol writer: the
%% edges the protocol suites do not reach.

no_tuple_headers_leaves_the_call_headers_test() ->
    Self = self(),
    Emit = fun({reply, Status, Headers, _Body} = Op, _Req) ->
        Self ! {emitted, Op},
        {ok, Status, Headers}
    end,
    Fun = fun(Req) ->
        ok = roadrunner_respond:reply(200, [{~"x-call", ~"1"}], ~"b", Req),
        Req
    end,
    ?assertMatch(
        {done, {buffered, 200, [{~"x-call", ~"1"}]}, #{}},
        roadrunner_respond_writer:run(?MODULE, Fun, [], #{method => ~"GET"}, Emit)
    ),
    ?assertEqual(
        {reply, 200, [{~"x-call", ~"1"}], ~"b"},
        receive
            {emitted, Op} -> Op
        after 0 -> none
        end
    ).

vary_from_both_is_combined_test() ->
    Emit = fun({reply, Status, Headers, _Body}, _Req) -> {ok, Status, Headers} end,
    Fun = fun(Req) ->
        ok = roadrunner_respond:reply(200, [{~"vary", ~"accept-encoding"}], ~"b", Req),
        Req
    end,
    {done, {buffered, 200, Headers}, _} = roadrunner_respond_writer:run(
        ?MODULE, Fun, [{~"vary", ~"Origin"}, {~"x-mw", ~"1"}], #{method => ~"GET"}, Emit
    ),
    ?assertEqual(~"accept-encoding, Origin", proplists:get_value(~"vary", Headers)),
    ?assertEqual(~"1", proplists:get_value(~"x-mw", Headers)),
    ?assertEqual(1, length(proplists:get_all_values(~"vary", Headers))).

failed_stream_head_returns_the_error_test() ->
    Send = fun(_Data, _Fin) -> ok end,
    ?assertEqual({error, closed}, roadrunner_respond_writer:started({error, closed}, Send)),
    ?assertEqual({ok, Send}, roadrunner_respond_writer:started(ok, Send)).

respond_tuple_has_no_returned_kind_test() ->
    %% Its kind is the response its fun sent; a respond tuple reaching the
    %% returned-shape helper is a dispatch bug, not a buffered response.
    ?assertError(
        function_clause,
        roadrunner_conn:response_kind({respond, [], fun(Req) -> Req end})
    ),
    ?assertEqual(buffered, roadrunner_conn:response_kind({200, [], <<>>})).
