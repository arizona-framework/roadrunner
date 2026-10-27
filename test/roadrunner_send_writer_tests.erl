-module(roadrunner_send_writer_tests).
-include_lib("eunit/include/eunit.hrl").

%% `roadrunner_send_writer` driven with a stand-in protocol writer: the
%% edges the protocol suites do not reach.

no_tuple_headers_leaves_the_call_headers_test() ->
    Self = self(),
    Emit = fun({reply, Status, Headers, _Body} = Op, _Req) ->
        Self ! {emitted, Op},
        {ok, Status, Headers}
    end,
    Fun = fun(Req) ->
        ok = roadrunner_send:reply(200, [{~"x-call", ~"1"}], ~"b", Req),
        Req
    end,
    ?assertMatch(
        {done, {buffered, 200, [{~"x-call", ~"1"}]}, #{}},
        roadrunner_send_writer:run(?MODULE, Fun, [], #{method => ~"GET"}, Emit)
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
        ok = roadrunner_send:reply(200, [{~"vary", ~"accept-encoding"}], ~"b", Req),
        Req
    end,
    {done, {buffered, 200, Headers}, _} = roadrunner_send_writer:run(
        ?MODULE, Fun, [{~"vary", ~"Origin"}, {~"x-mw", ~"1"}], #{method => ~"GET"}, Emit
    ),
    ?assertEqual(~"accept-encoding, Origin", proplists:get_value(~"vary", Headers)),
    ?assertEqual(~"1", proplists:get_value(~"x-mw", Headers)),
    ?assertEqual(1, length(proplists:get_all_values(~"vary", Headers))).

failed_stream_head_returns_the_error_test() ->
    Send = fun(_Data, _Fin) -> ok end,
    ?assertEqual({error, closed}, roadrunner_send_writer:started({error, closed}, Send)),
    ?assertEqual({ok, Send}, roadrunner_send_writer:started(ok, Send)).

send_tuple_has_no_returned_kind_test() ->
    %% Its kind is the response its fun sent; a send tuple reaching the
    %% returned-shape helper is a dispatch bug, not a buffered response.
    ?assertError(
        function_clause,
        roadrunner_conn:response_kind({send, [], fun(Req) -> Req end})
    ),
    ?assertEqual(buffered, roadrunner_conn:response_kind({200, [], <<>>})).

crash_in_the_protocol_writer_cuts_the_response_test() ->
    %% Part of the response may be out when the writer crashes: no 500 is
    %% sent after it, and the response counts as open, to be cut.
    Emit = fun({reply, _, _, _}, _Req) -> error(wire_failed) end,
    Fun = fun(Req) ->
        ok = roadrunner_send:reply(200, [], ~"b", Req),
        Req
    end,
    ?assertMatch(
        {crashed, error, wire_failed, _, open},
        roadrunner_send_writer:run(?MODULE, Fun, [], #{method => ~"GET"}, Emit)
    ).

caught_writer_crash_is_a_handler_bug_test() ->
    %% A fun that swallows the writer's crash and returns leaves a response
    %% in an unknown state: the caller crashes, which cuts it.
    Emit = fun({reply, _, _, _}, _Req) -> error(wire_failed) end,
    Fun = fun(Req) ->
        try
            roadrunner_send:reply(200, [], ~"b", Req)
        catch
            error:wire_failed -> ok
        end,
        Req
    end,
    ?assertError(
        unfinished_response,
        roadrunner_send_writer:run(?MODULE, Fun, [], #{method => ~"GET"}, Emit)
    ).
