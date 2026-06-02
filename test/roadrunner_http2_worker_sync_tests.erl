-module(roadrunner_http2_worker_sync_tests).

-include_lib("eunit/include/eunit.hrl").

%% `sync/2` returns ok once the conn acks the frame.
ack_returns_ok_test() ->
    Parent = self(),
    Worker = spawn(fun() ->
        Res = roadrunner_http2_worker_sync:sync(Parent, fun(Ref) ->
            Parent ! {sent, self(), Ref},
            ok
        end),
        Parent ! {worker_result, self(), Res}
    end),
    Ref =
        receive
            {sent, Worker, R0} -> R0
        after 1000 -> error(send_fun_not_called)
        end,
    Worker ! {h2_send_ack, Ref},
    receive
        {worker_result, Worker, Res} -> ?assertEqual(ok, Res)
    after 1000 -> error(no_worker_result)
    end.

%% A conn-side stream reset exits the worker with `stream_reset`.
stream_reset_exits_worker_test() ->
    Parent = self(),
    Worker = spawn(fun() ->
        _ = roadrunner_http2_worker_sync:sync(Parent, fun(_Ref) ->
            Parent ! {sent, self()},
            ok
        end)
    end),
    WorkerRef = monitor(process, Worker),
    receive
        {sent, Worker} -> ok
    after 1000 -> error(send_fun_not_called)
    end,
    Worker ! {h2_stream_reset, 1},
    receive
        {'DOWN', WorkerRef, process, Worker, Reason} ->
            ?assertEqual(stream_reset, Reason)
    after 1000 -> error(worker_did_not_exit)
    end.

%% A worker that monitored the conn and is blocked in `sync/2` wakes
%% with `conn_down` when the conn dies, instead of hanging on an ack
%% that will never come until TCP teardown reaps it.
conn_death_exits_worker_test() ->
    Parent = self(),
    Conn = spawn(fun() -> timer:sleep(infinity) end),
    Worker = spawn(fun() ->
        _ = roadrunner_http2_worker_sync:monitor_conn(Conn),
        Parent ! {ready, self()},
        %% The SendFun never triggers an ack: the conn is a black hole,
        %% so only its death can release the sync.
        _ = roadrunner_http2_worker_sync:sync(Conn, fun(_Ref) -> ok end)
    end),
    WorkerRef = monitor(process, Worker),
    receive
        {ready, Worker} -> ok
    after 1000 -> error(worker_not_ready)
    end,
    exit(Conn, kill),
    receive
        {'DOWN', WorkerRef, process, Worker, Reason} ->
            ?assertEqual(conn_down, Reason)
    after 1000 -> error(worker_did_not_wake)
    end.
