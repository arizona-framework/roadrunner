-module(roadrunner_http2_stream_response_tests).

-include_lib("eunit/include/eunit.hrl").

%% `run/5` monitors the conn itself (the worker does not), so a stream
%% blocked on a DATA ack wakes with `conn_down` when the conn dies,
%% instead of hanging until TCP teardown reaps it.
conn_death_wakes_blocked_stream_test_() ->
    {spawn, fun() ->
        Self = self(),
        Conn = spawn(fun() -> hold_first_data(Self) end),
        Worker = spawn(fun() ->
            roadrunner_http2_stream_response:run(Conn, 1, 200, [], fun(Send) ->
                Send(~"x", nofin)
            end)
        end),
        WorkerRef = monitor(process, Worker),
        receive
            {data_held, Worker} -> ok
        after 1000 -> error(worker_not_blocked)
        end,
        exit(Conn, kill),
        receive
            {'DOWN', WorkerRef, process, Worker, Reason} ->
                ?assertEqual(conn_down, Reason)
        after 1000 -> error(worker_did_not_wake)
        end
    end}.

%% A conn that acks the HEADERS, then holds the first DATA without an
%% ack (as when flow control stalls it) and reports the worker blocked.
hold_first_data(Reporter) ->
    receive
        {h2_send_headers, From, Ref, _StreamId, _Status, _Headers, _EndStream} ->
            From ! {h2_send_ack, Ref}
    end,
    receive
        {h2_send_data, Worker, _, _, _, _} ->
            Reporter ! {data_held, Worker}
    end,
    receive
        stop -> ok
    end.
