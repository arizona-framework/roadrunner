-module(roadrunner_route_keeper_props).
-moduledoc """
A model check of a route's `max_concurrent_requests` count
(`roadrunner_route_keeper`), run against a real listener and its real
keepers. Two kinds of requesters drive it, one operation at a time:

- HTTP/1.1 connections (`shed`, `long` and `short` waits): a process that
  lives across its requests, so a kept-alive connection's next request
  (`reuse`) takes its home slot without the keeper; refused or released,
  it stays idle;
- stream workers (`reset`) of fake connections that do what the HTTP/2
  connection and HTTP/3's loop do: start and monitor their workers, keep
  the key each takes on its own, and free it on the worker's `'DOWN'`. A
  worker waits until its stream resets or its connection goes, and its
  request ends with it; a connection killed with workers running leaves
  them counted until they end.

The operations: requests, releases, releases racing new requests (a
kept-alive connection's home racing the slot it frees, and any waiter's
claim on it) and stream resets, holder and waiter deaths, a connection
going with its workers waiting or running, keeper crashes (plain, with a
release and a request landing while no keeper runs, in the middle of a
grant, and in the middle of giving a kept-alive connection a new home), reloads changing the ceiling and queue depth, reloads that move
the route to a new key, drop and re-add it while its keeper is behind,
drop it as a request still routed by the old table asks, or fail, and a
listener stop with requests in flight.

After each the system is let settle (every process at rest and two reads
of the state alike) and checked against the model, table by table (a
route moved to a new key keeps its old table until it drains):

- a slot is granted only while fewer than the ceiling hold one, and a
  table never holds more rows than its ceiling, but after a reload that
  lowered it;
- every slot is freed exactly once: each table's rows are exactly the
  requests the model has running on it, each held by a process the keeper
  watches or owned by a connection it registered (and so watches), every
  connection the keeper registered is watched, and every intent belongs to
  a worker holding its row;
- the keeper's waiting count is exactly the requests it has parked, and
  none is parked while a slot is free;
- waiting requests are granted first in, first out: none is granted while
  an older one that cannot time out still waits, even when a new request,
  or a kept-alive connection's home, comes ahead of the release that
  freed the slot;
- no request waits past its timeout, and a long wait is never dropped
  except by a keeper crash or the listener stopping;
- a dropped route's keeper grants nothing once it has found the route
  drained, and its tables go only after that, never under a request still
  running;
- a request to a route without a ceiling is answered whatever the capped
  route is doing.

A run ends by releasing every request, after which nothing is running or
waiting, or by stopping the listener, after which every waiting request
is refused and every holder's release returns.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

-define(LISTENER, roadrunner_route_keeper_props_listener).
-define(SHORT_MS, 25).
-define(LONG_MS, 600000).
%% How late a timeout may answer on a loaded machine.
-define(SLACK_MS, 2000).

%% Where the keeper keeps what the model reads of it: its `#state{}` fields
%% `counts`, `waiters` and `watched`, and a `#waiter{}`'s pid.
-define(STATE_COUNTS, 5).
-define(STATE_WAITERS, 9).
-define(STATE_WATCHED, 11).
-define(WAITER_PID, 2).

-record(client, {
    mode :: shed | long | short | reset,
    kind :: h1 | worker,
    status :: asking | parked | running | idle | gone,
    %% Arrival order among the requests.
    seq :: non_neg_integer(),
    t0 :: integer(),
    %% The tables and counts the request asked.
    table :: {{ets:tid(), ets:tid(), ets:tid()}, atomics:atomics_ref()},
    %% The fake connection a stream worker belongs to.
    conn :: pid() | undefined,
    %% Set by a keeper crash while it waits: its refusal is expected.
    orphaned = false :: boolean()
}).

-record(model, {
    max :: pos_integer(),
    max_queued :: pos_integer(),
    %% The route's methods: `undefined`, or `[GET]` once moved to a new key.
    methods = undefined :: undefined | [binary()],
    seq = 0 :: non_neg_integer(),
    clients = #{} :: #{pid() => #client{}},
    %% The live fake connections.
    conns = [] :: [pid()],
    %% The most rows each table may hold: its ceiling, or more after a
    %% reload lowered it below the requests already running.
    caps = #{} :: #{ets:tid() => pos_integer()}
}).

op() ->
    frequency([
        {6, {request, oneof([shed, long, long, short, reset])}},
        {5, {reuse, nat(), oneof([shed, long, short])}},
        {4, {stream, nat()}},
        {5, {release, nat()}},
        {3, {race, nat(), oneof([shed, long, short, reset])}},
        {3, {race_reuse, nat(), nat(), oneof([shed, long, short])}},
        {2, {kill, nat()}},
        {2, {reset, nat()}},
        {1, {race_reset, nat(), nat()}},
        {2, {conn_gone, nat()}},
        {1, {kill_conn_and_worker, nat()}},
        {2, {stream_then_kill_conn, nat()}},
        {1, crash_keeper},
        {1, {crash_window, nat(), oneof([shed, long])}},
        {1, half_grant},
        {1, {rehome_crash, nat(), boolean()}},
        {1, {reload, integer(1, 4), integer(1, 4)}},
        {1, rekey},
        {1, drop_and_bring_back},
        {1, {straggler_at_drain, nat()}},
        {1, drained_before_waiter},
        {1, failed_reload},
        {1, cheap}
    ]).

%% A thousand runs: a new request overtaking the release that freed its
%% slot is a race the model needs that many to meet. A run may end with
%% the listener stopping.
prop_model() ->
    proper:numtests(1000, prop_model_runs()).

prop_model_runs() ->
    ?FORALL(
        {Max, MaxQueued, Ops, Stop},
        {integer(1, 3), integer(1, 3), list(op()), frequency([{9, false}, {1, true}])},
        begin
            {ok, Listener} = roadrunner_listener:start_link(?LISTENER, #{
                port => 0, routes => routes(Max, MaxQueued, undefined)
            }),
            true = unlink(Listener),
            try
                Model = lists:foldl(fun step/2, #model{max = Max, max_queued = MaxQueued}, Ops),
                case Stop of
                    false -> ok = finish(Model);
                    true -> ok = stop_with_requests(settle(Model))
                end,
                true
            after
                ok = stop_if_running(),
                ok = flush_clients(),
                ok = stop_clients()
            end
        end
    ).

stop_if_running() ->
    case whereis(?LISTENER) of
        undefined -> ok;
        _ -> roadrunner_listener:stop(?LISTENER)
    end.

routes(Max, MaxQueued, Methods) ->
    [expensive(Max, MaxQueued, Methods), {~"/cheap", roadrunner_hello_handler}].

expensive(Max, MaxQueued, Methods) ->
    Route = #{
        path => ~"/expensive",
        handler => roadrunner_hello_handler,
        max_concurrent_requests => Max,
        overload_mode => {queue, #{max_queued => MaxQueued, timeout => ?LONG_MS}}
    },
    case Methods of
        undefined -> Route;
        _ -> Route#{methods => Methods}
    end.

reload(#model{max = Max, max_queued = MaxQueued, methods = Methods}) ->
    ok = roadrunner_listener:reload_routes(?LISTENER, routes(Max, MaxQueued, Methods)).

%% --- the steps ---

step({request, reset}, Model) ->
    {Conn, Model1} = new_conn(Model),
    {Pid, Model2} = stream(Conn, Model1),
    settle(await_asked(Pid, Model2));
step({request, Mode}, Model) ->
    {Pid, Model1} = h1_request(new_h1(), Mode, Model),
    settle(await_asked(Pid, Model1));
step({reuse, N, Mode}, Model) ->
    %% A kept-alive connection's next request: its home slot, when it has
    %% one on the route's table and the gate is open.
    case pick(idle, Model) of
        [] ->
            Model;
        Idle ->
            Pid = lists:nth(N rem length(Idle) + 1, Idle),
            {Pid, Model1} = h1_request(Pid, Mode, Model),
            settle(await_asked(Pid, Model1))
    end;
step({stream, N}, #model{conns = Conns} = Model) ->
    case Conns of
        [] ->
            step({request, reset}, Model);
        _ ->
            Conn = lists:nth(N rem length(Conns) + 1, Conns),
            {Pid, Model1} = stream(Conn, Model),
            settle(await_asked(Pid, Model1))
    end;
step({release, N}, Model) ->
    case pick(running, Model) of
        [] ->
            Model;
        Running ->
            Pid = lists:nth(N rem length(Running) + 1, Running),
            settle(release(Pid, Model))
    end;
step({race, N, Mode}, Model) ->
    case pick(running, Model) of
        [] ->
            Model;
        Running ->
            Pid = lists:nth(N rem length(Running) + 1, Running),
            step({request, Mode}, release(Pid, Model))
    end;
step({race_reuse, N, M, Mode}, Model) ->
    %% A release and a kept-alive connection's next request at once: the
    %% home slot racing the slot the release frees, and any waiter's claim
    %% on it.
    case {pick(running, Model), pick(idle, Model)} of
        {[_ | _] = Running, [_ | _] = Idle} ->
            Holder = lists:nth(N rem length(Running) + 1, Running),
            Client = lists:nth(M rem length(Idle) + 1, Idle),
            Model1 = release(Holder, Model),
            {Client, Model2} = h1_request(Client, Mode, Model1),
            settle(await_asked(Client, Model2));
        _ ->
            Model
    end;
step({kill, N}, Model) ->
    case pick(running, Model) ++ pick(parked, Model) of
        [] ->
            Model;
        Live ->
            Pid = lists:nth(N rem length(Live) + 1, Live),
            Model1 = set_status(Pid, gone, Model),
            exit(Pid, kill),
            settle(Model1)
    end;
step({reset, N}, Model) ->
    case [P || P <- pick(parked, Model), mode(P, Model) =:= reset] of
        [] ->
            Model;
        Waiting ->
            Pid = lists:nth(N rem length(Waiting) + 1, Waiting),
            Pid ! {reset, Pid, peer},
            settle(apply_result(receive_result(Pid), Model))
    end;
step({race_reset, N, M}, Model) ->
    case {[P || P <- pick(parked, Model), mode(P, Model) =:= reset], pick(running, Model)} of
        {[_ | _] = Waiting, [_ | _] = Running} ->
            Waiter = lists:nth(N rem length(Waiting) + 1, Waiting),
            Holder = lists:nth(M rem length(Running) + 1, Running),
            Model1 = release(Holder, Model),
            Waiter ! {reset, Waiter, peer},
            settle(apply_result(receive_result(Waiter), Model1));
        _ ->
            Model
    end;
step({conn_gone, N}, #model{conns = Conns} = Model) ->
    %% A connection goes: its waiting workers stop waiting (or were granted
    %% just before), its running ones run on and stay counted.
    case Conns of
        [] ->
            Model;
        _ ->
            Conn = lists:nth(N rem length(Conns) + 1, Conns),
            settle(kill_conn(Conn, Model))
    end;
step({kill_conn_and_worker, N}, Model) ->
    case [P || P <- pick(running, Model), kind(P, Model) =:= worker] of
        [] ->
            Model;
        Running ->
            Worker = lists:nth(N rem length(Running) + 1, Running),
            Conn = (client(Worker, Model))#client.conn,
            Model1 = set_status(Worker, gone, Model),
            exit(Worker, kill),
            settle(kill_conn(Conn, Model1))
    end;
step({stream_then_kill_conn, N}, Model) ->
    %% A worker starts and its connection dies at once: whatever point of
    %% its admission the worker is at, its slot is counted while it runs and
    %% freed once.
    {Conn, Model1} =
        case Model#model.conns of
            [] -> new_conn(Model);
            Conns -> {lists:nth(N rem length(Conns) + 1, Conns), Model}
        end,
    {Pid, Model2} = stream(Conn, Model1),
    exit(Conn, kill),
    Model3 = Model2#model{conns = lists:delete(Conn, Model2#model.conns)},
    settle(apply_result(receive_result(Pid), Model3));
step(crash_keeper, Model) ->
    Keeper = keeper(),
    Model1 = orphan_waiters(Model),
    exit(Keeper, kill),
    ok = await_new_keeper(Keeper),
    settle(Model1);
step({crash_window, N, Mode}, Model) ->
    %% While no keeper runs: a holder releases, and a connection without a
    %% home asks, and is refused.
    Keeper = keeper(),
    Model1 = orphan_waiters(Model),
    ok = sys:suspend(?LISTENER),
    Mon = monitor(process, Keeper),
    exit(Keeper, kill),
    receive
        {'DOWN', Mon, process, Keeper, _} -> ok
    end,
    Model2 =
        case pick(running, Model1) of
            [] ->
                Model1;
            Running ->
                Holder = lists:nth(N rem length(Running) + 1, Running),
                release(Holder, Model1)
        end,
    {Pid, Model3} = h1_request(new_h1(), Mode, Model2),
    {Pid, {refused, _}} = receive_result(Pid),
    Model4 = set_status(Pid, idle, Model3),
    ok = sys:resume(?LISTENER),
    ok = await_new_keeper(Keeper),
    settle(Model4);
step(half_grant, Model) ->
    %% The keeper adds a row for a waiting request and dies before
    %% answering: the asker removes it, the next keeper hands the slot on.
    #{in_flight := InFlight} = route_stats(),
    case InFlight < Model#model.max of
        false ->
            Model;
        true ->
            Keeper = keeper(),
            Model1 = orphan_waiters(Model),
            ok = sys:suspend(Keeper),
            {Asker, Model2} = h1_request(new_h1(), long, Model1),
            ok = await_mailbox(Keeper, Asker),
            {{Slots, _Regs, _Intents}, _Counts} = route_counts(),
            true = ets:insert_new(Slots, {free_key(Slots, 1), Asker, Asker}),
            true = erlang:suspend_process(Asker),
            exit(Keeper, kill),
            ok = await_new_keeper(Keeper),
            Model3 = set_orphaned(Asker, Model2),
            {Next, Model4} = h1_request(new_h1(), long, Model3),
            Model5 = await_asked(Next, Model4),
            true = erlang:resume_process(Asker),
            settle(apply_result(receive_result(Asker), Model5))
    end;
step({rehome_crash, N, Registered}, Model) ->
    %% An idle connection with a home asks the keeper (its fast path closed
    %% here), which adds another key's row for it and, when `Registered`,
    %% makes that key its home, then dies before answering. The connection
    %% is refused; whatever it takes next must be freed when it dies, so it
    %% and the keeper taking over must agree on its home.
    {{Slots, Regs, _Intents}, Counts} = route_counts(),
    Max = atomics:get(Counts, 1),
    Homes = [{P, H} || P <- pick(idle, Model), H <- [home(P, Slots)], is_integer(H), H =< Max],
    case Homes of
        [] ->
            Model;
        _ ->
            {Conn, Home} = lists:nth(N rem length(Homes) + 1, Homes),
            case free_key_but(Slots, Home, Max) of
                none ->
                    Model;
                K ->
                    Keeper = keeper(),
                    Model1 = orphan_waiters(Model),
                    ok = sys:suspend(Keeper),
                    Gate = ets:lookup_element(Regs, '$keeper', 3),
                    true = ets:update_element(Regs, '$keeper', {3, Gate bor 1}),
                    {Conn, Model2} = h1_request(Conn, long, Model1),
                    ok = await_mailbox(Keeper, Conn),
                    true = ets:insert_new(Slots, {K, Conn, Conn}),
                    _ = Registered andalso ets:insert(Regs, {Conn, K}),
                    %% The keeper taking over sees the row before the
                    %% connection, seeing the old one gone, removes it.
                    true = erlang:suspend_process(Conn),
                    exit(Keeper, kill),
                    ok = await_new_keeper(Keeper),
                    _ = sys:get_state(keeper()),
                    true = erlang:resume_process(Conn),
                    Model3 = apply_result(receive_result(Conn), set_orphaned(Conn, Model2)),
                    {Conn, Model4} = h1_request(Conn, shed, Model3),
                    Model5 = settle(await_asked(Conn, Model4)),
                    case (client(Conn, Model5))#client.status of
                        running ->
                            exit(Conn, kill),
                            settle(set_status(Conn, gone, Model5));
                        idle ->
                            Model5
                    end
            end
    end;
step({reload, Max, MaxQueued}, Model) ->
    Model1 = Model#model{max = Max, max_queued = MaxQueued},
    ok = reload(Model1),
    settle(recap(Model1));
step(rekey, #model{methods = Methods} = Model) ->
    Model1 =
        case Methods of
            undefined -> Model#model{methods = [~"GET"]};
            _ -> Model#model{methods = undefined}
        end,
    ok = reload(Model1),
    settle(recap(Model1));
step(drop_and_bring_back, Model) ->
    %% The route is dropped and brought back while its keeper is behind and
    %% has nothing running: the keeper finds the route drained and stops, a
    %% request asking meanwhile is refused, and the listener, which has the
    %% route back, starts a new keeper on the same count.
    case pick(running, Model) ++ pick(parked, Model) of
        [_ | _] ->
            Model;
        [] ->
            Keeper = keeper(),
            ok = sys:suspend(Keeper),
            ok = roadrunner_listener:reload_routes(?LISTENER, plain()),
            ok = reload(Model),
            {Asker, Model1} = h1_request(new_h1(), shed, Model),
            ok = await_mailbox(Keeper, Asker),
            ok = sys:resume(Keeper),
            Model2 = apply_result(receive_result(Asker), Model1),
            ok = await_new_keeper(Keeper),
            settle(Model2)
    end;
step({straggler_at_drain, N}, Model) ->
    %% A request still routed by the old table asks for a slot just as the
    %% route, dropped by a reload, drains. A connection without a home there
    %% asks the keeper, which finds the route drained and stops in that
    %% step: the request is refused, rather than let in to run on tables the
    %% listener then deletes. One with a home takes it before the keeper
    %% hears of the drop, and runs counted on tables kept until it ends.
    case pick(running, Model) ++ pick(parked, Model) of
        [_ | _] ->
            Model;
        [] ->
            Keeper = keeper(),
            {{Slots, _Regs, _Intents}, _Counts} = Old = route_counts(),
            {Straggler, Fresh} =
                case pick(idle, Model) of
                    [] -> {new_h1(), true};
                    Idle -> {lists:nth(N rem length(Idle) + 1, Idle), false}
                end,
            ok = sys:suspend(Keeper),
            ok = roadrunner_listener:reload_routes(?LISTENER, plain()),
            {Straggler, Model1} = h1_request_on(Straggler, Old, shed, Model),
            ok = await_asked_or_mailbox(Keeper, Straggler),
            ok = sys:resume(Keeper),
            {Straggler, Result} = receive_result(Straggler),
            case {Fresh, Result} of
                {true, {ok, _}} -> error({granted_after_drain, Straggler});
                _ -> ok
            end,
            Model2 = apply_result({Straggler, Result}, Model1),
            Model3 =
                case Result of
                    {ok, _} -> release(Straggler, Model2);
                    {refused, _} -> Model2
                end,
            ok = await_deleted(Slots),
            ok = reload(Model3),
            settle(Model3)
    end;
step(drained_before_waiter, Model) ->
    %% The route is dropped while one request runs and one waits. The
    %% runner releases while the keeper is behind, so the table empties with
    %% a request still waiting: the keeper hands it the slot rather than
    %% stopping. The holder frees its own row with the keeper suspended, so
    %% it is an HTTP/1.1 connection (a worker's row is freed by the keeper).
    Long = [P || P <- pick(parked, Model), mode(P, Model) =/= short],
    case {pick(running, Model), Long, length(tables(Model))} of
        {[Holder], [_ | _], 1} when (map_get(Holder, Model#model.clients))#client.kind =:= h1 ->
            Keeper = keeper(),
            ok = roadrunner_listener:reload_routes(?LISTENER, plain()),
            ok = sys:suspend(Keeper),
            Table = table(Holder, Model),
            Model1 = release(Holder, Model),
            ok = await_rows(Table, 0, 100000),
            ok = sys:resume(Keeper),
            _ = sys:get_state(Keeper),
            is_process_alive(Keeper) orelse error({keeper_stopped_with_waiters, Long}),
            ok = reload(Model1),
            settle(Model1);
        _ ->
            Model
    end;
step(failed_reload, Model) ->
    Bad = #{
        path => ~"/bad",
        handler => roadrunner_init_route_handler,
        state => #{raise => bad_option}
    },
    Extra = #{path => ~"/extra", handler => roadrunner_hello_handler, max_concurrent_requests => 1},
    #model{max = Max, max_queued = MaxQueued, methods = Methods} = Model,
    {error, {init_failed, _}} = roadrunner_listener:reload_routes(
        ?LISTENER, [Extra, expensive(Max + 1, MaxQueued, Methods), Bad]
    ),
    settle(Model);
step(cheap, Model) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, roadrunner_listener:port(?LISTENER), [binary, {active, false}], 5000
    ),
    ok = gen_tcp:send(Sock, ~"GET /cheap HTTP/1.1\r\nHost: x\r\n\r\n"),
    <<"HTTP/1.1 200 ", _/binary>> = recv_until_closed(Sock, <<>>),
    Model.

plain() ->
    [{~"/cheap", roadrunner_hello_handler}].

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

%% A request ends: an HTTP/1.1 connection releases and stays idle, a
%% stream worker ends (the keeper frees its slot).
release(Pid, Model) ->
    Pid ! release,
    case kind(Pid, Model) of
        h1 -> set_status(Pid, idle, Model);
        worker -> set_status(Pid, gone, Model)
    end.

kill_conn(Conn, #model{conns = Conns} = Model) ->
    Parked = [P || P <- pick(parked, Model), (client(P, Model))#client.conn =:= Conn],
    exit(Conn, kill),
    Model1 = Model#model{conns = lists:delete(Conn, Conns)},
    lists:foldl(fun(P, Acc) -> apply_result(receive_result(P), Acc) end, Model1, Parked).

orphan_waiters(#model{clients = Clients} = Model) ->
    Model#model{
        clients = maps:map(
            fun
                (_Pid, #client{status = parked} = C) -> C#client{orphaned = true};
                (_Pid, C) -> C
            end,
            Clients
        )
    }.

set_orphaned(Pid, #model{clients = Clients} = Model) ->
    #{Pid := C} = Clients,
    Model#model{clients = Clients#{Pid := C#client{orphaned = true}}}.

recap(#model{caps = Caps} = Model) ->
    {{Slots, _Regs, _Intents}, Counts} = route_counts(),
    Max = atomics:get(Counts, 1),
    Rows = ets:info(Slots, size),
    Model#model{caps = Caps#{Slots => max(Max, max(Rows, maps:get(Slots, Caps, Max)))}}.

free_key(Slots, K) ->
    case ets:member(Slots, K) of
        true -> free_key(Slots, K + 1);
        false -> K
    end.

%% A free key within `Max` other than `Not`, if any.
free_key_but(Slots, Not, Max) ->
    case [K || K <- lists:seq(1, Max), K =/= Not, not ets:member(Slots, K)] of
        [K | _] -> K;
        [] -> none
    end.

%% The home a connection keeps for the route of `Slots`.
home(Conn, Slots) ->
    {dictionary, Dictionary} = erlang:process_info(Conn, dictionary),
    proplists:get_value({roadrunner_route_keeper, Slots}, Dictionary).

%% --- requesters ---

%% An HTTP/1.1 connection: asks for a slot when told, releases when told,
%% and otherwise waits for its next request.
new_h1() ->
    Driver = self(),
    Pid = spawn(fun() -> h1_idle(Driver) end),
    ok = remember_client(Pid),
    Pid.

h1_idle(Driver) ->
    receive
        {acquire, Ceiling} ->
            Result = roadrunner_route_keeper:acquire(Ceiling),
            Driver ! {client, self(), Result},
            case Result of
                {ok, Token} ->
                    receive
                        release -> ok = roadrunner_route_keeper:release(Ceiling, Token)
                    end;
                {refused, _} ->
                    ok
            end,
            h1_idle(Driver)
    end.

h1_request(Pid, Mode, Model) ->
    h1_request_on(Pid, route_counts(), Mode, Model).

%% The same on `Table`, one the route may no longer have.
h1_request_on(Pid, Table, Mode, Model) ->
    Pid ! {acquire, ceiling(Table, Mode)},
    Client = #client{
        mode = Mode,
        kind = h1,
        status = asking,
        seq = Model#model.seq,
        t0 = erlang:monotonic_time(millisecond),
        table = Table
    },
    {Pid, Model#model{seq = Model#model.seq + 1, clients = (Model#model.clients)#{Pid => Client}}}.

ceiling({Table, Counts}, Mode) ->
    roadrunner_route_keeper:ceiling(Table, Counts, wait(Mode), ?LISTENER).

%% A fake multiplexed connection: starts stream workers and monitors them,
%% keeps the key each takes on its own, and frees it on the worker's
%% `'DOWN'`, in the one receive.
new_conn(#model{conns = Conns} = Model) ->
    Conn = spawn(fun conn_loop/0),
    ok = remember_client(Conn),
    {Conn, Model#model{conns = [Conn | Conns]}}.

conn_loop() ->
    receive
        {open, Ceiling, Driver, Ref} ->
            Conn = self(),
            {Pid, _Mon} = spawn_monitor(fun() -> worker(Ceiling, Conn, Driver) end),
            Driver ! {Ref, Pid},
            conn_loop();
        {roadrunner_route_slot, _Worker, _Ceiling, _K} = Note ->
            ok = roadrunner_route_keeper:noted(Note),
            conn_loop();
        {'DOWN', _Mon, process, Worker, _Reason} ->
            ok = roadrunner_route_keeper:worker_down(Worker),
            conn_loop()
    end.

worker(Ceiling, Conn, Driver) ->
    Result = roadrunner_route_keeper:acquire(Ceiling, {reset, self()}, Conn, Conn),
    Driver ! {client, self(), Result},
    case Result of
        {ok, _Token} ->
            receive
                release -> ok
            end;
        _ ->
            ok
    end.

stream(Conn, Model) ->
    Table = route_counts(),
    Ref = make_ref(),
    Conn ! {open, ceiling(Table, reset), self(), Ref},
    Pid =
        receive
            {Ref, P} -> P
        after 5000 -> error({conn_never_opened, Conn})
        end,
    ok = remember_client(Pid),
    Client = #client{
        mode = reset,
        kind = worker,
        status = asking,
        seq = Model#model.seq,
        t0 = erlang:monotonic_time(millisecond),
        table = Table,
        conn = Conn
    },
    {Pid, Model#model{seq = Model#model.seq + 1, clients = (Model#model.clients)#{Pid => Client}}}.

wait(shed) -> {shed, #{retry_after => 1}};
wait(short) -> {queue, #{timeout => ?SHORT_MS}};
wait(_Long) -> {queue, #{timeout => ?LONG_MS}}.

%% Until the new request has its answer or waits in the keeper.
await_asked(Pid, Model) ->
    await_asked(Pid, Model, 100000).

await_asked(Pid, _Model, 0) ->
    error({never_asked, Pid});
await_asked(Pid, Model, Tries) ->
    receive
        {client, Pid, Result} -> apply_result({Pid, Result}, Model)
    after 0 ->
        #client{table = {{_Slots, Regs, _Intents}, _}} = client(Pid, Model),
        case lists:member(Pid, waiting(Regs)) of
            true ->
                set_status(Pid, parked, Model);
            false ->
                erlang:yield(),
                await_asked(Pid, Model, Tries - 1)
        end
    end.

apply_result({Pid, Result}, #model{clients = Clients} = Model) ->
    #{Pid := #client{table = {_Table, Counts} = Table, kind = Kind} = Client} = Clients,
    case Result of
        {ok, _Token} ->
            Running = length([P || P <- pick(running, Model), table(P, Model) =:= Table]),
            Max = atomics:get(Counts, 1),
            Running < Max orelse error({over_ceiling, Running + 1, Max}),
            set_status(Pid, running, Model);
        {refused, _} ->
            ok = check_refusal(Client),
            set_status(Pid, after_answer(Kind), Model);
        reset ->
            set_status(Pid, gone, Model)
    end.

after_answer(h1) -> idle;
after_answer(worker) -> gone.

%% A refusal is fine for a request still asking (the route was full), one
%% orphaned by a keeper crash, or a short wait that timed out; a long wait
%% must never be dropped.
check_refusal(#client{status = asking}) ->
    ok;
check_refusal(#client{orphaned = true}) ->
    ok;
check_refusal(#client{mode = short, t0 = T0}) ->
    Waited = erlang:monotonic_time(millisecond) - T0,
    Waited =< ?SHORT_MS + ?SLACK_MS orelse error({waited_past_timeout, Waited}),
    ok;
check_refusal(#client{} = Client) ->
    error({wait_dropped, Client}).

receive_result(Pid) ->
    receive
        {client, Pid, Result} -> {Pid, Result}
    after 10000 -> error({no_answer, Pid})
    end.

%% --- settling ---

%% Answer every request the keeper has answered, then check a settled
%% state: every process at rest, and the state read twice alike (a keeper
%% handling a message between the reads of its state and of the tables
%% gives a torn view).
settle(Model) ->
    settle(Model, 100000).

settle(Model, 0) ->
    error({never_settled, diagnose(Model)});
settle(Model, Tries) ->
    Views = [view(Table, Model) || Table <- tables(Model)],
    case [P || {_Table, #{answering := A}} <- Views, P <- A] of
        [_ | _] = Answering ->
            receive
                {client, Pid, Result} -> settle(apply_result({Pid, Result}, Model), Tries)
            after 10000 -> error({no_answer, Answering})
            end;
        [] ->
            case
                lists:all(fun({_Table, V}) -> quiet(V) end, Views) andalso at_rest(Model) andalso
                    [view(Table, Model) || Table <- tables(Model)] =:= Views andalso
                    at_rest(Model)
            of
                true ->
                    ok = check_fifo(Model),
                    lists:foldl(fun check_table/2, Model, Views);
                false ->
                    erlang:yield(),
                    settle(Model, Tries - 1)
            end
    end.

%% Every process of the run and every keeper waits in a receive with an
%% empty mailbox: whatever a release or a death sent has been handled.
at_rest(#model{clients = Clients, conns = Conns} = Model) ->
    Keepers = [
        ets:lookup_element(Regs, '$keeper', 2)
     || {{_Slots, Regs, _Intents}, _Counts} <- tables(Model),
        ets:info(Regs, size) =/= undefined
    ],
    lists:all(fun resting/1, maps:keys(Clients) ++ Conns ++ Keepers).

resting(Pid) ->
    case erlang:process_info(Pid, [status, message_queue_len]) of
        undefined -> true;
        [{status, waiting}, {message_queue_len, 0}] -> true;
        _ -> false
    end.

tables(Model) ->
    lists:usort([
        route_counts()
        | [table(P, Model) || P <- pick(running, Model) ++ pick(parked, Model)]
    ]).

view({{Slots, Regs, _Intents}, _Counts} = Table, Model) ->
    Live = [P || P <- pick(running, Model) ++ pick(parked, Model), table(P, Model) =:= Table],
    case ets:info(Slots, size) of
        undefined when Live =/= [] ->
            error({slot_table_gone_with_live_requests, Live});
        undefined ->
            {Table, gone};
        _ ->
            {Table, view(Table, Model, keeper_view(Regs))}
    end.

%% A table whose keeper has gone is changing hands: about to be deleted
%% (its route drained) or served by a new keeper.
view(_Table, _Model, changing) ->
    changing;
view({{Slots, Regs, Intents}, Counts} = Table, Model, {Waiting, Watched, Queued}) ->
    Running = [P || P <- pick(running, Model), table(P, Model) =:= Table],
    Parked = [P || P <- pick(parked, Model), table(P, Model) =:= Table],
    Rows = ets:tab2list(Slots),
    Registered = [C || {C, _Home} <- ets:tab2list(Regs)],
    #{
        answering => [P || P <- Parked, not lists:member(P, Waiting)],
        waiting => Waiting,
        %% Every row is covered: its holder is watched, or its owner is (a
        %% connection the keeper registered); so is every registration;
        %% every intent belongs to a worker holding its row.
        unwatched_rows => [
            R
         || {_K, O, H} = R <- Rows,
            not lists:member(H, Watched),
            not lists:member(O, Watched)
        ],
        unwatched_regs => [C || C <- Registered, not lists:member(C, Watched)],
        stray_intents => [
            I
         || {O, W, K} = I <- ets:tab2list(Intents),
            not lists:member({K, O, W}, Rows)
        ],
        queued => Queued,
        holding => lists:sort([H || {_K, _O, H} <- Rows]),
        running => lists:sort(Running),
        max => atomics:get(Counts, 1)
    }.

quiet(gone) ->
    true;
quiet(changing) ->
    false;
quiet(#{
    unwatched_rows := [],
    unwatched_regs := [],
    stray_intents := [],
    holding := Holding,
    running := Running
}) ->
    Holding =:= Running;
quiet(#{}) ->
    false.

check_table({_Table, gone}, Model) ->
    Model;
check_table({{{Slots, _Regs, _Intents}, _}, V}, #model{caps = Caps} = Model) ->
    #{waiting := Waiting, queued := Queued, holding := Holding, max := Max} = V,
    Rows = length(Holding),
    Cap = maps:get(Slots, Caps, Max),
    Rows =< Cap orelse error({table_over_ceiling, Rows, Cap}),
    Queued =:= length(Waiting) orelse error({queued_count_wrong, Queued, Waiting}),
    Waiting =:= [] orelse Rows >= Max orelse
        error({waiter_parked_with_free_slot, Waiting, Rows, Max}),
    case Rows =< Max of
        true -> Model#model{caps = Caps#{Slots => Max}};
        false -> Model
    end.

diagnose(Model) ->
    #{
        views => [{Table, V} || {Table, V} <- [view(T, Model) || T <- tables(Model)], V =/= gone],
        restless => [
            {P, erlang:process_info(P, [status, messages, current_function])}
         || P <- maps:keys(Model#model.clients) ++ Model#model.conns,
            not resting(P)
        ]
    }.

%% No waiting request is older than one already granted, but a short wait
%% (it may have been granted after its timeout raced the grant).
check_fifo(Model) ->
    lists:foreach(
        fun(Table) ->
            Granted = [
                S
             || P <- pick(running, Model),
                #client{seq = S, table = T} <- [client(P, Model)],
                T =:= Table
            ],
            Oldest = lists:max([-1 | Granted]),
            Stuck = [
                C
             || P <- pick(parked, Model),
                #client{mode = M, seq = S, table = T} = C <- [client(P, Model)],
                T =:= Table,
                M =/= short,
                S < Oldest
            ],
            Stuck =:= [] orelse error({not_fifo, Stuck})
        end,
        tables(Model)
    ).

finish(Model0) ->
    Model = expire_short_waits(settle(Model0)),
    case {pick(running, Model), pick(parked, Model)} of
        {[], []} ->
            #{in_flight := 0, queued := 0} = route_stats(),
            ok;
        {[Pid | _], _} ->
            finish(settle(release(Pid, Model)));
        {[], Parked} ->
            error({parked_with_free_slots, Parked})
    end.

expire_short_waits(Model) ->
    lists:foldl(
        fun(Pid, Acc) ->
            receive
                {client, Pid, Result} -> apply_result({Pid, Result}, Acc)
            after ?SHORT_MS + ?SLACK_MS -> error({wait_past_timeout, Pid})
            end
        end,
        Model,
        [P || P <- pick(parked, Model), mode(P, Model) =:= short]
    ).

stop_with_requests(Model) ->
    Parked = pick(parked, Model),
    Running = pick(running, Model),
    ok = roadrunner_listener:stop(?LISTENER),
    _ = [{P, {refused, _}} = receive_result(P) || P <- Parked, kind(P, Model) =:= h1],
    _ = [
        case receive_result(P) of
            {P, {refused, _}} -> ok;
            {P, reset} -> ok
        end
     || P <- Parked, kind(P, Model) =:= worker
    ],
    %% Every holder's release returns: HTTP/1.1 connections stay alive,
    %% workers end normally.
    Mons = [{P, monitor(process, P)} || P <- Running],
    _ = [P ! release || P <- Running],
    _ = [
        case kind(P, Model) of
            h1 ->
                ok = await_idle(P),
                true = demonitor(Mon, [flush]);
            worker ->
                receive
                    {'DOWN', Mon, process, P, normal} -> ok;
                    {'DOWN', Mon, process, P, Reason} -> error({release_failed, P, Reason})
                after 10000 -> error({release_hung, P})
                end
        end
     || {P, Mon} <- Mons
    ],
    ok.

%% Until an HTTP/1.1 connection is back waiting for its next request.
await_idle(Pid) ->
    await_idle(Pid, 100000).

await_idle(Pid, 0) ->
    error({never_idle, Pid});
await_idle(Pid, Tries) ->
    case erlang:process_info(Pid, [current_function, message_queue_len]) of
        [{current_function, {?MODULE, h1_idle, 1}}, {message_queue_len, 0}] ->
            ok;
        undefined ->
            error({h1_client_died, Pid});
        _ ->
            erlang:yield(),
            await_idle(Pid, Tries - 1)
    end.

%% --- the system under test ---

route_counts() ->
    {ok, _, _, _, _, {_Body, Ceiling}} = roadrunner_router:resolve(
        ~"GET", ~"/expensive", persistent_term:get({roadrunner_routes, ?LISTENER})
    ),
    {{element(2, Ceiling), element(3, Ceiling), element(4, Ceiling)}, element(5, Ceiling)}.

route_stats() ->
    roadrunner_route_keeper:stats(route_counts()).

keeper() ->
    {{_Slots, Regs, _Intents}, _Counts} = route_counts(),
    ets:lookup_element(Regs, '$keeper', 2).

%% The pids the keeper has waiting, the pids it watches and its waiting
%% count, read in the keeper after everything sent to it before; or
%% `changing` when it has gone.
keeper_view(Regs) ->
    Keeper = ets:lookup_element(Regs, '$keeper', 2),
    Self = self(),
    Ref = make_ref(),
    try
        sys:replace_state(Keeper, fun(State) ->
            Self !
                {Ref,
                    [
                        element(?WAITER_PID, W)
                     || W <- maps:values(element(?STATE_WAITERS, State))
                    ],
                    maps:keys(element(?STATE_WATCHED, State)),
                    atomics:get(element(?STATE_COUNTS, State), 3)},
            State
        end)
    of
        _ ->
            receive
                {Ref, Waiting, Watched, Queued} -> {Waiting, Watched, Queued}
            end
    catch
        exit:{_Reason, {sys, _Request, _Args}} -> changing
    end.

%% The requests `Regs`' keeper has waiting (none while it changes hands).
waiting(Regs) ->
    case keeper_view(Regs) of
        changing -> [];
        {Waiting, _Watched, _Queued} -> Waiting
    end.

await_rows(Table, N, 0) ->
    error({rows_never, Table, N});
await_rows({{Slots, _Regs, _Intents}, _} = Table, N, Tries) ->
    case ets:info(Slots, size) of
        N ->
            ok;
        _ ->
            erlang:yield(),
            await_rows(Table, N, Tries - 1)
    end.

%% Until the listener has deleted a slot table.
await_deleted(Slots) ->
    await_deleted(Slots, 1000000).

await_deleted(Slots, 0) ->
    error({table_kept, Slots});
await_deleted(Slots, Tries) ->
    case ets:info(Slots, size) of
        undefined ->
            ok;
        _ ->
            erlang:yield(),
            await_deleted(Slots, Tries - 1)
    end.

await_new_keeper(Old) ->
    await_new_keeper(Old, 100000).

await_new_keeper(_Old, 0) ->
    error(no_new_keeper);
await_new_keeper(Old, Tries) ->
    case keeper() of
        Old ->
            erlang:yield(),
            await_new_keeper(Old, Tries - 1);
        _New ->
            ok
    end.

%% Until `Pid`'s acquire is in the (suspended) keeper's mailbox.
await_mailbox(Keeper, Pid) ->
    {messages, Messages} = erlang:process_info(Keeper, messages),
    case [P || {acquire, _Token, P, _Kind, _Wait} <- Messages, P =:= Pid] of
        [_] ->
            ok;
        [] ->
            erlang:yield(),
            await_mailbox(Keeper, Pid)
    end.

%% Until `Pid` has its answer (it took its home) or its acquire is in the
%% (suspended) keeper's mailbox.
await_asked_or_mailbox(Keeper, Pid) ->
    {messages, Messages} = erlang:process_info(self(), messages),
    {messages, Asks} = erlang:process_info(Keeper, messages),
    case
        lists:member({client, Pid}, [{client, P} || {client, P, _} <- Messages]) orelse
            [P || {acquire, _Token, P, _Kind, _Wait} <- Asks, P =:= Pid] =/= []
    of
        true ->
            ok;
        false ->
            erlang:yield(),
            await_asked_or_mailbox(Keeper, Pid)
    end.

%% --- model helpers ---

%% The requests with `Status`, oldest first.
pick(Status, #model{clients = Clients}) ->
    [
        P
     || {_Seq, P} <- lists:sort([
            {Seq, P}
         || P := #client{seq = Seq, status = S} <- Clients, S =:= Status
        ])
    ].

client(Pid, #model{clients = Clients}) ->
    maps:get(Pid, Clients).

mode(Pid, Model) ->
    (client(Pid, Model))#client.mode.

kind(Pid, Model) ->
    (client(Pid, Model))#client.kind.

table(Pid, Model) ->
    (client(Pid, Model))#client.table.

set_status(Pid, Status, #model{clients = Clients} = Model) ->
    #{Pid := Client} = Clients,
    Model#model{clients = Clients#{Pid := Client#client{status = Status}}}.

stop_clients() ->
    _ = [exit(P, kill) || P <- erase_clients()],
    ok.

erase_clients() ->
    case erase(?MODULE) of
        undefined -> [];
        Pids -> Pids
    end.

remember_client(Pid) ->
    _ = put(?MODULE, [Pid | erase_clients()]),
    ok.

flush_clients() ->
    receive
        {client, _, _} -> flush_clients()
    after 0 -> ok
    end.
