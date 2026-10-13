-module(roadrunner_stream_body_reader_tests).

-include_lib("eunit/include/eunit.hrl").

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
        Silent = spawn_link(fun() -> receive
            after infinity -> ok
            end end),
        ?assertEqual({error, request_timeout}, read(Silent, deadline(0)))
    end}.

%% --- helpers ---

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
        body_reader => #{
            framing => stream,
            buffered => <<>>,
            bytes_read => 0,
            done => false,
            recv => Recv,
            max => Max
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

continue_before_stream_when_the_conn_is_gone_test() ->
    %% The connection that owes the 100 is gone: nothing to wait for.
    {Dead, MRef} = spawn_monitor(fun() -> ok end),
    receive
        {'DOWN', MRef, process, Dead, _} -> ok
    end,
    Req = #{body_reader => #{continue => {Dead, 1}}},
    ?assertEqual(ok, roadrunner_conn:continue_before_stream(Req)).
