-module(roadrunner_stream_body_reader_tests).

-include_lib("eunit/include/eunit.hrl").
-include("../include/roadrunner_body_reader.hrl").

%% The stream body reader of an HTTP/2 manual-mode request
%% (`roadrunner_conn:stream_body_reader/5`), read through
%% `roadrunner_req:read_body/1,2` and `read_body_chunked/1` with a scripted
%% recv standing in for the connection.

%% --- read_body/1 ---

reads_all_test() ->
    Req = req([{~"ab", false}, {[~"c", ~"d"], true}], 64),
    {ok, Body, _} = roadrunner_req:read_body(Req),
    ?assertEqual(~"abcd", iolist_to_binary(Body)).

reads_nothing_once_done_test() ->
    Req = #{body_reader => roadrunner_conn:stream_body_reader(self(), 1, 0, 64, true)},
    {ok, Body, _} = roadrunner_req:read_body(Req),
    ?assertEqual(<<>>, iolist_to_binary(Body)),
    ?assertMatch({ok, <<>>, _}, roadrunner_req:read_body_chunked(Req)).

over_max_test() ->
    ?assertEqual(
        {error, content_length_too_large}, roadrunner_req:read_body(req([{~"abcd", true}], 3))
    ).

recv_error_test() ->
    ?assertEqual({error, closed}, roadrunner_req:read_body(req([{error, closed}], 64))),
    ?assertEqual({error, closed}, roadrunner_req:read_body_chunked(req([{error, closed}], 64))),
    ?assertEqual(
        {error, closed}, roadrunner_req:read_body(req([{error, closed}], 64), #{length => 2})
    ).

%% --- read_body/2 with a length ---

reads_in_lengths_test() ->
    %% Pieces of 3 across DATA boundaries: the leftover of one read starts the
    %% next, and the last piece ends the body.
    Req = req([{~"ab", false}, {~"cd", true}], 64),
    {more, P1, Req1} = roadrunner_req:read_body(Req, #{length => 3}),
    ?assertEqual(~"abc", iolist_to_binary(P1)),
    {ok, P2, _} = roadrunner_req:read_body(Req1, #{length => 3}),
    ?assertEqual(~"d", iolist_to_binary(P2)).

length_ending_the_body_test() ->
    Req = req([{~"abc", true}], 64),
    {ok, P, _} = roadrunner_req:read_body(Req, #{length => 3}),
    ?assertEqual(~"abc", iolist_to_binary(P)).

%% --- read_body_chunked/1 ---

reads_chunks_test() ->
    Req = req([{~"ab", false}, {~"", false}, {~"cd", true}], 64),
    {more, ~"ab", Req1} = roadrunner_req:read_body_chunked(Req),
    {ok, ~"cd", Req2} = roadrunner_req:read_body_chunked(Req1),
    ?assertMatch({ok, <<>>, _}, roadrunner_req:read_body_chunked(Req2)).

chunk_after_a_length_read_test() ->
    %% What a length-bounded read left over comes first.
    Req = req([{~"abcd", false}, {~"e", true}], 64),
    {more, _, Req1} = roadrunner_req:read_body(Req, #{length => 1}),
    {more, P, Req2} = roadrunner_req:read_body_chunked(Req1),
    ?assertEqual(~"bcd", iolist_to_binary(P)),
    {ok, ~"e", _} = roadrunner_req:read_body_chunked(Req2).

leftover_ending_the_body_test() ->
    Req = req([{~"abcd", true}], 64),
    {more, _, Req1} = roadrunner_req:read_body(Req, #{length => 1}),
    {ok, P, _} = roadrunner_req:read_body_chunked(Req1),
    ?assertEqual(~"bcd", iolist_to_binary(P)).

%% --- the recv asking the connection ---

recv_asks_the_connection_test_() ->
    {spawn, fun() ->
        Conn = spawn_link(fun() -> serve([{~"ab", false}, {~"cd", true}]) end),
        Reader = roadrunner_conn:stream_body_reader(Conn, 7, deadline(5000), 64, false),
        {ok, Body, _} = roadrunner_req:read_body(#{body_reader => Reader}),
        ?assertEqual(~"abcd", iolist_to_binary(Body))
    end}.

recv_errors_test_() ->
    {spawn, fun() ->
        %% The connection's refusal, its exit, and the deadline end the read.
        Refusing = spawn_link(fun() -> serve([{error, closed}]) end),
        ?assertEqual({error, closed}, read(Refusing, deadline(5000))),
        Gone = spawn(fun() -> ok end),
        ?assertEqual({error, closed}, read(Gone, deadline(5000))),
        Silent = spawn_link(fun() -> serve_late(~"") end),
        ?assertEqual({error, request_timeout}, read(Silent, deadline(0)))
    end}.

%% --- withdrawing a timed-out read ---

%% A late body error is dropped with the read, and a connection that goes
%% away instead of answering the withdrawal does not leave the read
%% waiting.
withdrawn_read_test_() ->
    {spawn, fun() ->
        Erring = spawn_link(fun() ->
            serve_late_message({roadrunner_body_error, 7, closed})
        end),
        ?assertEqual({error, request_timeout}, read(Erring, deadline(0))),
        ?assertEqual(
            none,
            receive
                {roadrunner_body_error, 7, _} = Late -> Late
            after 0 -> none
            end
        ),
        Leaving = spawn(fun() ->
            receive
                {roadrunner_body_demand, _, 7} -> ok
            end,
            receive
                {roadrunner_body_withdraw, _, 7} -> ok
            end
        end),
        ?assertEqual({error, request_timeout}, read(Leaving, deadline(0)))
    end}.

%% --- moving the deadline ---

%% A reader whose deadline has passed reads again once
%% `set_body_timeout/2` moves it, here to never, before the read.
set_body_timeout_moves_the_deadline_test_() ->
    {spawn, fun() ->
        Conn = spawn_link(fun() -> serve([{~"abcd", true}]) end),
        Req = #{body_reader => roadrunner_conn:stream_body_reader(Conn, 7, deadline(0), 64, false)},
        Req1 = roadrunner_req:set_body_timeout(infinity, Req),
        {ok, Body, _} = roadrunner_req:read_body(Req1),
        ?assertEqual(~"abcd", iolist_to_binary(Body))
    end}.

%% A read that fails ends the body: a later read fails the same way, even
%% with a deadline moved past it.
failed_read_ends_the_body_test_() ->
    {spawn, fun() ->
        Conn = spawn_link(fun() -> serve_late(~"late") end),
        Req = #{body_reader => roadrunner_conn:stream_body_reader(Conn, 7, deadline(0), 64, false)},
        ?assertEqual({error, request_timeout}, roadrunner_req:read_body(Req)),
        Req1 = roadrunner_req:set_body_timeout(infinity, Req),
        ?assertEqual({error, request_timeout}, roadrunner_req:read_body(Req1)),
        %% The DATA handed over just before the demand was withdrawn was
        %% dropped, not left in the mailbox.
        ?assertEqual(
            none,
            receive
                {roadrunner_body, 7, _, _} = Late -> Late
            after 0 -> none
            end
        )
    end}.

set_body_timeout_from_now_test() ->
    Req = #{body_reader => roadrunner_conn:stream_body_reader(self(), 7, deadline(0), 64, false)},
    Before = erlang:monotonic_time(millisecond),
    #{body_reader := #stream_body_reader{deadline = Deadline}} = roadrunner_req:set_body_timeout(
        1000, Req
    ),
    ?assert(Deadline >= Before + 1000).

%% Without a reader (`auto` mode) the body is already read: nothing moves.
set_body_timeout_without_a_reader_test() ->
    Req = #{body => ~"read"},
    ?assertEqual(Req, roadrunner_req:set_body_timeout(1000, Req)),
    ?assertEqual(Req, roadrunner_req:set_body_timeout(infinity, Req)).

%% A timeout longer than a `receive` can wait fails at the call, on either
%% shape, rather than when a later read arms its wait.
set_body_timeout_over_the_receive_limit_test() ->
    Req = #{body_reader => roadrunner_conn:stream_body_reader(self(), 7, deadline(0), 64, false)},
    #{body_reader := #stream_body_reader{deadline = _}} = roadrunner_req:set_body_timeout(
        16#FFFFFFFF, Req
    ),
    ?assertError(function_clause, roadrunner_req:set_body_timeout(16#100000000, Req)),
    ?assertError(function_clause, roadrunner_req:set_body_timeout(16#100000000, #{body => ~""})).

%% --- reading in two steps ---

%% A demand goes to the connection, and its answer, taken in from the
%% mailbox, comes back as a `next_chunk` read would: `more` until the body
%% ends. Messages that are not the answer, another stream's included, are
%% ignored.
demand_and_answer_test_() ->
    {spawn, fun() ->
        Conn = spawn_link(fun() -> serve([{~"ab", false}, {~"", false}, {~"cd", true}]) end),
        Req = #{
            body_reader => roadrunner_conn:stream_body_reader(Conn, 7, deadline(5000), 64, false)
        },
        ?assertEqual(demanded, roadrunner_req:demand_body(Req)),
        {more, ~"ab", Req1} = roadrunner_req:body_message(answer(), Req),
        ?assertEqual(ignore, roadrunner_req:body_message({roadrunner_body, 8, ~"x", true}, Req1)),
        ?assertEqual(ignore, roadrunner_req:body_message(other, Req1)),
        demanded = roadrunner_req:demand_body(Req1),
        {more, ~"", Req2} = roadrunner_req:body_message(answer(), Req1),
        demanded = roadrunner_req:demand_body(Req2),
        {ok, ~"cd", Req3} = roadrunner_req:body_message(answer(), Req2),
        %% The body has ended: the next read returns at once.
        ?assertEqual(ready, roadrunner_req:demand_body(Req3))
    end}.

%% A reader whose next read returns at once is `ready`: one holding bytes a
%% length-bounded read left, one whose read failed, one whose body arrived
%% whole, and a request with no reader.
ready_readers_test_() ->
    {spawn, fun() ->
        Conn = spawn_link(fun() -> serve([{~"abcd", false}]) end),
        Req = #{
            body_reader => roadrunner_conn:stream_body_reader(Conn, 7, deadline(5000), 64, false)
        },
        {more, _, Leftover} = roadrunner_req:read_body(Req, #{length => 1}),
        ?assertEqual(ready, roadrunner_req:demand_body(Leftover)),
        Silent = spawn_link(fun() -> serve_late(~"") end),
        Failing = #{
            body_reader => roadrunner_conn:stream_body_reader(Silent, 7, deadline(0), 64, false)
        },
        {error, request_timeout} = roadrunner_req:read_body(Failing),
        ?assertEqual(ready, roadrunner_req:demand_body(Failing)),
        ?assertEqual(ready, roadrunner_req:demand_body(req([{~"a", true}], 64))),
        ?assertEqual(ready, roadrunner_req:demand_body(#{body => ~"a"}))
    end}.

%% An answer over the reader's cap, or a refusal, fails the read, and every
%% later one.
failed_answers_test_() ->
    {spawn, fun() ->
        Conn = spawn_link(fun() -> serve([{~"abcd", false}]) end),
        Req = #{
            body_reader => roadrunner_conn:stream_body_reader(Conn, 7, deadline(5000), 3, false)
        },
        demanded = roadrunner_req:demand_body(Req),
        ?assertEqual({error, content_length_too_large}, roadrunner_req:body_message(answer(), Req)),
        ?assertEqual({error, content_length_too_large}, roadrunner_req:read_body(Req)),
        ?assertEqual(
            {error, closed},
            roadrunner_req:body_message({roadrunner_body_error, 7, closed}, Req)
        )
    end}.

%% `await_body/1` waits for the answer to the demand already sent, until
%% the reader's deadline, or until the connection goes away.
await_body_test_() ->
    {spawn, fun() ->
        Conn = spawn_link(fun() -> serve([{~"ab", true}]) end),
        Req = #{
            body_reader => roadrunner_conn:stream_body_reader(Conn, 7, deadline(5000), 64, false)
        },
        demanded = roadrunner_req:demand_body(Req),
        ?assertMatch({ok, ~"ab", _}, roadrunner_req:await_body(Req)),
        Silent = spawn_link(fun() -> serve_late(~"late") end),
        Late = #{
            body_reader => roadrunner_conn:stream_body_reader(Silent, 7, deadline(0), 64, false)
        },
        demanded = roadrunner_req:demand_body(Late),
        ?assertEqual({error, request_timeout}, roadrunner_req:await_body(Late)),
        Gone = spawn(fun() -> ok end),
        Lost = #{
            body_reader => roadrunner_conn:stream_body_reader(Gone, 7, deadline(5000), 64, false)
        },
        ?assertEqual({error, closed}, roadrunner_req:await_body(Lost))
    end}.

%% `withdraw_body/1` takes the demand back: what was handed over before is
%% dropped, and the body ends with `request_timeout`.
withdraw_body_test_() ->
    {spawn, fun() ->
        Conn = spawn_link(fun() -> serve_late(~"late") end),
        Req = #{
            body_reader => roadrunner_conn:stream_body_reader(Conn, 7, deadline(5000), 64, false)
        },
        demanded = roadrunner_req:demand_body(Req),
        ?assertEqual({error, request_timeout}, roadrunner_req:withdraw_body(Req)),
        ?assertEqual(
            none,
            receive
                {roadrunner_body, 7, _, _} = Late -> Late
            after 0 -> none
            end
        ),
        ?assertEqual({error, request_timeout}, roadrunner_req:read_body(Req))
    end}.

%% --- helpers ---

%% The connection's answer to a demand, from the mailbox.
answer() ->
    receive
        {roadrunner_body, 7, _, _} = Body -> Body;
        {roadrunner_body_error, 7, _} = Error -> Error
    end.

%% A request whose reader's recv hands out `Script`, one entry a call:
%% `{Data, Fin}` or `{error, Reason}`.
req(Script, Max) ->
    Key = make_ref(),
    put(Key, Script),
    Recv = fun() ->
        case get(Key) of
            [{error, _} = E | Rest] ->
                put(Key, Rest),
                E;
            [{Data, Fin} | Rest] ->
                put(Key, Rest),
                {ok, Data, Fin}
        end
    end,
    #{
        body_reader => #stream_body_reader{
            buffered = <<>>,
            bytes_read = 0,
            done = false,
            deadline = infinity,
            id = erlang:unique_integer(),
            recv = fun(_Deadline) -> Recv() end,
            max = Max
        }
    }.

read(Conn, Deadline) ->
    Reader = roadrunner_conn:stream_body_reader(Conn, 7, Deadline, 64, false),
    roadrunner_req:read_body(#{body_reader => Reader}).

deadline(Ms) ->
    erlang:monotonic_time(millisecond) + Ms.

%% A stand-in connection answering each demand for stream 7 from `Script`.
serve([]) ->
    ok;
serve([Next | Rest]) ->
    receive
        {roadrunner_body_demand, Worker, 7} ->
            _ =
                case Next of
                    {error, Reason} -> Worker ! {roadrunner_body_error, 7, Reason};
                    {Data, Fin} -> Worker ! {roadrunner_body, 7, Data, Fin}
                end,
            serve(Rest)
    end.

%% A connection that leaves the ask unanswered until the read times out,
%% then hands over `Data` just before it confirms the demand is withdrawn.
serve_late(Data) ->
    serve_late_message({roadrunner_body, 7, Data, false}).

serve_late_message(Late) ->
    receive
        {roadrunner_body_demand, _Worker, 7} -> ok
    end,
    receive
        {roadrunner_body_withdraw, Worker, 7} ->
            Worker ! Late,
            Worker ! {roadrunner_body_withdrawn, 7}
    end.

continue_before_stream_when_the_conn_is_gone_test() ->
    %% The connection that owes the 100 is gone: nothing to wait for.
    {Dead, MRef} = spawn_monitor(fun() -> ok end),
    receive
        {'DOWN', MRef, process, Dead, _} -> ok
    end,
    Req = #{body_reader => #stream_body_reader{continue = {Dead, 1}}},
    ?assertEqual(ok, roadrunner_conn:continue_before_stream(Req)).
