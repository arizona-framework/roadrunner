-module(roadrunner_route_keeper_props).
-moduledoc """
A model check of a route's `max_concurrent_requests` count
(`roadrunner_route_keeper`), run against a real listener and its real
keepers. Random sequences of operations are driven one at a time:
requests asking for a slot (shedding, waiting long, waiting briefly, or
waiting until their stream resets), releases, releases racing new
requests and stream resets, holder and waiter deaths, keeper crashes
(plain, with a release and a request landing while no keeper runs, and
in the middle of a grant), reloads changing the ceiling and queue depth,
reloads that move the route to a new key, drop and re-add it while its
keeper is behind, or fail, and a listener stop with requests in flight.
After each the system is let settle and checked against the model, table
by table (a route moved to a new key keeps its old table until it drains):

- a slot is granted only while fewer than the ceiling hold one, and a
  table never holds more rows than its ceiling, but after a reload that
  lowered it;
- every slot is freed exactly once: once settled, each table's rows are
  exactly the requests the model has running on it, and its keeper
  watches exactly those;
- the keeper's waiting count is exactly the requests it has parked, and
  none is parked while a slot is free;
- waiting requests are granted first in, first out: none is granted while
  an older one that cannot time out still waits, even when a new request
  reaches the keeper ahead of the release that freed the slot;
- no request waits past its timeout, and a long wait is never dropped
  except by a keeper crash or the listener stopping;
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

-record(client, {
    mode :: shed | long | short | reset,
    status :: asking | parked | running | gone,
    %% Arrival order among the requests that waited.
    seq :: non_neg_integer(),
    t0 :: integer(),
    %% The slot table and counts the request asked.
    table :: {ets:tid(), atomics:atomics_ref()},
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
    %% The most rows each table may hold: its ceiling, or more after a
    %% reload lowered it below the requests already running.
    caps = #{} :: #{ets:tid() => pos_integer()}
}).

op() ->
    frequency([
        {8, {request, oneof([shed, long, long, short, reset])}},
        {5, {release, nat()}},
        {3, {race, nat(), oneof([shed, long, short])}},
        {2, {kill, nat()}},
        {2, {reset, nat()}},
        {1, {race_reset, nat(), nat()}},
        {1, crash_keeper},
        {1, {crash_window, nat(), oneof([shed, long])}},
        {1, half_grant},
        {1, {reload, integer(1, 4), integer(1, 4)}},
        {1, rekey},
        {1, stale_drain},
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

step({request, Mode}, Model) ->
    {Pid, Model1} = request(Mode, Model),
    settle(await_asked(Pid, Model1));
step({release, N}, Model) ->
    case pick(running, Model) of
        [] ->
            Model;
        Running ->
            Pid = lists:nth(N rem length(Running) + 1, Running),
            %% Out of the model before its slot is, so the model never
            %% counts more than run.
            Model1 = set_status(Pid, gone, Model),
            Pid ! release,
            settle(Model1)
    end;
step({race, N, Mode}, Model) ->
    %% A release and a new request at once: the slot it frees goes to the
    %% oldest waiter, whichever reaches the keeper first.
    case pick(running, Model) of
        [] ->
            Model;
        Running ->
            Pid = lists:nth(N rem length(Running) + 1, Running),
            Model1 = set_status(Pid, gone, Model),
            Pid ! release,
            step({request, Mode}, Model1)
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
            Pid ! {reset, Pid},
            %% Reset, or granted just before: either way it answers.
            settle(apply_result(receive_result(Pid), Model))
    end;
step({race_reset, N, M}, Model) ->
    %% A stream reset while the slot it waits for is being handed to it.
    case {[P || P <- pick(parked, Model), mode(P, Model) =:= reset], pick(running, Model)} of
        {[_ | _] = Waiting, [_ | _] = Running} ->
            Waiter = lists:nth(N rem length(Waiting) + 1, Waiting),
            Holder = lists:nth(M rem length(Running) + 1, Running),
            Model1 = set_status(Holder, gone, Model),
            Holder ! release,
            Waiter ! {reset, Waiter},
            settle(apply_result(receive_result(Waiter), Model1));
        _ ->
            Model
    end;
step(crash_keeper, Model) ->
    Keeper = keeper(),
    Model1 = orphan_waiters(Model),
    exit(Keeper, kill),
    ok = await_new_keeper(Keeper),
    settle(Model1);
step({crash_window, N, Mode}, Model) ->
    %% The keeper dies and, before the listener starts the next one, a
    %% holder releases and a new request asks: it finds no keeper and is
    %% refused, and the release is in the table for the next keeper.
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
                Holder ! release,
                set_status(Holder, gone, Model1)
        end,
    {Pid, Model3} = request(Mode, Model2),
    {Pid, {refused, _}} = receive_result(Pid),
    Model4 = set_status(Pid, gone, Model3),
    ok = sys:resume(?LISTENER),
    ok = await_new_keeper(Keeper),
    settle(Model4);
step(half_grant, Model) ->
    %% The keeper adds a request's row and dies before answering it. The
    %% next keeper takes the row over, and a request may park behind it;
    %% the asker then sees the old keeper gone, removes the row, and the
    %% next keeper must hand the slot on.
    #{in_flight := InFlight} = route_stats(),
    case InFlight < Model#model.max of
        false ->
            Model;
        true ->
            Keeper = keeper(),
            Model1 = orphan_waiters(Model),
            ok = sys:suspend(Keeper),
            {Asker, Model2} = request(long, Model1),
            Token = await_mailbox(Keeper, Asker),
            {Slots, _Counts} = route_counts(),
            true = ets:insert(Slots, {Token, Asker}),
            true = erlang:suspend_process(Asker),
            exit(Keeper, kill),
            ok = await_new_keeper(Keeper),
            Model3 = set_orphaned(Asker, Model2),
            {Next, Model4} = request(long, Model3),
            Model5 = await_asked(Next, Model4),
            true = erlang:resume_process(Asker),
            settle(apply_result(receive_result(Asker), Model5))
    end;
step({reload, Max, MaxQueued}, Model) ->
    Model1 = Model#model{max = Max, max_queued = MaxQueued},
    ok = reload(Model1),
    settle(recap(Model1));
step(rekey, #model{methods = Methods} = Model) ->
    %% The route moves to a new key and gets a count of its own; the old
    %% count drains with the requests it still runs.
    Model1 =
        case Methods of
            undefined -> Model#model{methods = [~"GET"]};
            _ -> Model#model{methods = undefined}
        end,
    ok = reload(Model1),
    settle(recap(Model1));
step(stale_drain, Model) ->
    %% The route is dropped while its keeper is behind and empty, brought
    %% back, a request takes a slot, and it is dropped again before the
    %% listener reads the keeper's drained notice: the notice is stale.
    case pick(running, Model) ++ pick(parked, Model) of
        [_ | _] ->
            Model;
        [] ->
            Keeper = keeper(),
            Plain = [{~"/cheap", roadrunner_hello_handler}],
            ok = sys:suspend(Keeper),
            ok = roadrunner_listener:reload_routes(?LISTENER, Plain),
            ok = reload(Model),
            {Holder, Model1} = request(shed, Model),
            ok = sys:suspend(?LISTENER),
            Self = self(),
            _ = spawn(fun() ->
                Self ! {dropped, roadrunner_listener:reload_routes(?LISTENER, Plain)}
            end),
            ok = await_queue(whereis(?LISTENER), 1),
            ok = sys:resume(Keeper),
            Model2 = apply_result(receive_result(Holder), Model1),
            %% The drained notice is behind the drop now.
            ok = await_queue(whereis(?LISTENER), 2),
            ok = sys:resume(?LISTENER),
            receive
                {dropped, ok} -> ok
            end,
            ok = reload(Model2),
            settle(Model2)
    end;
step(failed_reload, Model) ->
    %% A table whose hook fails is refused whole, the keepers it started
    %% with it.
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
    %% A route without a ceiling answers whatever the capped one is doing.
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, roadrunner_listener:port(?LISTENER), [binary, {active, false}], 5000
    ),
    ok = gen_tcp:send(Sock, ~"GET /cheap HTTP/1.1\r\nHost: x\r\n\r\n"),
    <<"HTTP/1.1 200 ", _/binary>> = recv_until_closed(Sock, <<>>),
    Model.

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

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

%% After a reload: a table may hold more rows than its new ceiling only as
%% many as already run.
recap(#model{caps = Caps} = Model) ->
    {Slots, Counts} = route_counts(),
    Max = atomics:get(Counts, 1),
    Rows = rows(Slots),
    Model#model{caps = Caps#{Slots => max(Max, max(Rows, maps:get(Slots, Caps, Max)))}}.

%% --- requests ---

%% A process asking for a slot as a connection or a stream worker does, on
%% the route's table now.
request(Mode, Model) ->
    Driver = self(),
    {Slots, Counts} = Table = route_counts(),
    Ceiling = roadrunner_route_keeper:ceiling(Slots, Counts, wait(Mode), ?LISTENER),
    Pid = spawn(fun() ->
        Result =
            case Mode of
                reset -> roadrunner_route_keeper:acquire(Ceiling, {reset, self()}, Driver);
                _ -> roadrunner_route_keeper:acquire(Ceiling)
            end,
        Driver ! {client, self(), Result},
        case Result of
            {ok, Token} ->
                receive
                    release -> ok = roadrunner_route_keeper:release(Ceiling, Token)
                end;
            {refused, _} ->
                %% Refused, it lives on, as an HTTP/1.1 connection does
                %% after its 503: its end must not be what frees anything.
                receive
                    stop -> ok
                end;
            reset ->
                ok
        end
    end),
    ok = remember_client(Pid),
    Client = #client{
        mode = Mode,
        status = asking,
        seq = Model#model.seq,
        t0 = erlang:monotonic_time(millisecond),
        table = Table
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
        #client{table = {Slots, _}} = client(Pid, Model),
        case lists:member(Pid, element(1, keeper_view(Slots))) of
            true ->
                set_status(Pid, parked, Model);
            false ->
                erlang:yield(),
                await_asked(Pid, Model, Tries - 1)
        end
    end.

%% A request's answer, checked against the model: a grant only while its
%% table runs fewer than its ceiling.
apply_result({Pid, Result}, #model{clients = Clients} = Model) ->
    #{Pid := #client{table = {_Slots, Counts} = Table} = Client} = Clients,
    case Result of
        {ok, _Token} ->
            Running = length([P || P <- pick(running, Model), table(P, Model) =:= Table]),
            Max = atomics:get(Counts, 1),
            Running < Max orelse error({over_ceiling, Running + 1, Max}),
            set_status(Pid, running, Model);
        {refused, _} ->
            ok = check_refusal(Client),
            set_status(Pid, gone, Model);
        reset ->
            set_status(Pid, gone, Model)
    end.

%% Refused while waiting: by its timeout, never late, or by a keeper crash.
%% A long wait has no timeout to reach.
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

%% Let every message in flight land, then check each table against the
%% model: the requests that left a keeper's queue have their answers, the
%% rows are exactly the requests running, and the keeper watches those.
settle(Model) ->
    settle(Model, 100000).

settle(Model, 0) ->
    error({never_settled, diagnose(Model)});
settle(Model, Tries) ->
    Views = [view(Table, Model) || Table <- tables(Model)],
    case [P || {_Table, #{answering := A}} <- Views, P <- A] of
        [_ | _] = Answering ->
            %% A waiter left a queue: its answer is on its way.
            receive
                {client, Pid, Result} -> settle(apply_result({Pid, Result}, Model), Tries)
            after 10000 -> error({no_answer, Answering})
            end;
        [] ->
            case lists:all(fun({_Table, V}) -> quiet(V) end, Views) of
                true ->
                    ok = check_fifo(Model),
                    lists:foldl(fun check_table/2, Model, Views);
                false ->
                    %% A released or killed holder's slot is not freed yet,
                    %% or its keeper has yet to hear of it.
                    erlang:yield(),
                    settle(Model, Tries - 1)
            end
    end.

%% The tables the model's live requests are on, and the route's own.
tables(Model) ->
    lists:usort([
        route_counts()
        | [table(P, Model) || P <- pick(running, Model) ++ pick(parked, Model)]
    ]).

%% One table as its keeper and rows have it now.
view({Slots, Counts} = Table, Model) ->
    Live = [P || P <- pick(running, Model) ++ pick(parked, Model), table(P, Model) =:= Table],
    case ets:info(Slots, size) of
        undefined when Live =/= [] ->
            error({slot_table_gone_with_live_requests, Live});
        undefined ->
            {Table, gone};
        _ ->
            {Waiting, Watched, Queued} = keeper_view(Slots),
            Running = [P || P <- pick(running, Model), table(P, Model) =:= Table],
            Parked = [P || P <- pick(parked, Model), table(P, Model) =:= Table],
            {Table, #{
                answering => [P || P <- Parked, not lists:member(P, Waiting)],
                waiting => Waiting,
                watched => Watched,
                queued => Queued,
                holding => lists:sort(holders(Slots)),
                running => lists:sort(Running),
                max => atomics:get(Counts, 1)
            }}
    end.

quiet(gone) ->
    true;
quiet(#{watched := Watched, holding := Holding, running := Running}) ->
    Watched =:= length(Holding) andalso Holding =:= Running.

check_table({_Table, gone}, Model) ->
    Model;
check_table({{Slots, _}, V}, #model{caps = Caps} = Model) ->
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

%% What keeps the system from settling, named.
diagnose(Model) ->
    [
        {Table, diagnose_view(V)}
     || {Table, V} <- [view(T, Model) || T <- tables(Model)], V =/= gone
    ].

diagnose_view(#{watched := Watched, holding := Holding, running := Running}) when
    Watched > length(Holding)
->
    {keeper_watches_freed_slots, Watched, Holding, Running};
diagnose_view(#{holding := Holding, running := Running}) when Holding =/= Running ->
    {slots_not_matching_requests, #{rows => Holding, running => Running}};
diagnose_view(V) ->
    {unexplained, V}.

%% No running request was granted ahead of an older one still waiting on
%% its table that could not have timed out.
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

%% Release everything, letting the queues run dry.
finish(Model0) ->
    Model = expire_short_waits(settle(Model0)),
    case {pick(running, Model), pick(parked, Model)} of
        {[], []} ->
            #{in_flight := 0, queued := 0} = route_stats(),
            ok;
        {[Pid | _], _} ->
            finish(step({release, index_of(Pid, pick(running, Model))}, Model));
        {[], Parked} ->
            %% Only short waits left with nothing running cannot happen:
            %% with a free slot the keeper would have served them.
            error({parked_with_free_slots, Parked})
    end.

%% With nothing released, every brief wait still waiting must time out,
%% and in time.
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

%% The listener stops with requests running and waiting: every waiting one
%% is refused, and every holder's release returns.
stop_with_requests(Model) ->
    Parked = pick(parked, Model),
    Running = pick(running, Model),
    Mons = [{P, monitor(process, P)} || P <- Running],
    ok = roadrunner_listener:stop(?LISTENER),
    _ = [{P, {refused, _}} = receive_result(P) || P <- Parked],
    _ = [P ! release || P <- Running],
    _ = [
        receive
            {'DOWN', Mon, process, P, normal} -> ok;
            {'DOWN', Mon, process, P, Reason} -> error({release_failed, P, Reason})
        after 10000 -> error({release_hung, P})
        end
     || {P, Mon} <- Mons
    ],
    ok.

%% --- the system under test ---

route_counts() ->
    {ok, _, _, _, _, {_Body, Ceiling}} = roadrunner_router:resolve(
        ~"GET", ~"/expensive", persistent_term:get({roadrunner_routes, ?LISTENER})
    ),
    {element(2, Ceiling), element(3, Ceiling)}.

route_stats() ->
    roadrunner_route_keeper:stats(route_counts()).

keeper() ->
    {Slots, _Counts} = route_counts(),
    ets:lookup_element(Slots, keeper, 2).

%% The pids a table's keeper has waiting, the holders it watches and its
%% waiting count, read in the keeper itself, after everything sent to it.
keeper_view(Slots) ->
    Keeper = ets:lookup_element(Slots, keeper, 2),
    Self = self(),
    Ref = make_ref(),
    _ = sys:replace_state(Keeper, fun(State) ->
        Self !
            {Ref, [element(2, W) || W <- maps:values(element(7, State))],
                map_size(element(9, State)), atomics:get(element(4, State), 3)},
        State
    end),
    receive
        {Ref, Waiting, Watched, Queued} -> {Waiting, Watched, Queued}
    end.

holders(Slots) ->
    [Pid || {Token, Pid} <- ets:tab2list(Slots), is_reference(Token)].

rows(Slots) ->
    ets:info(Slots, size) - 1.

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

%% The token of `Pid`'s acquire, once it is in the (suspended) keeper's
%% mailbox.
await_mailbox(Keeper, Pid) ->
    {messages, Messages} = erlang:process_info(Keeper, messages),
    case [T || {acquire, T, P, _Wait} <- Messages, P =:= Pid] of
        [Token] ->
            Token;
        [] ->
            erlang:yield(),
            await_mailbox(Keeper, Pid)
    end.

%% Until `Pid` has `N` messages waiting.
await_queue(Pid, N) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Len} when Len >= N ->
            ok;
        _ ->
            erlang:yield(),
            await_queue(Pid, N)
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

table(Pid, Model) ->
    (client(Pid, Model))#client.table.

set_status(Pid, Status, #model{clients = Clients} = Model) ->
    #{Pid := Client} = Clients,
    Model#model{clients = Clients#{Pid := Client#client{status = Status}}}.

index_of(Pid, List) ->
    length(lists:takewhile(fun(P) -> P =/= Pid end, List)).

%% Every request process of the run, ended once it is checked: refused
%% ones are still waiting to be told to go.
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

%% Answers of requests killed before they were read.
flush_clients() ->
    receive
        {client, _, _} -> flush_clients()
    after 0 -> ok
    end.
