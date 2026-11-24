-module(roadrunner_route_keeper_props).
-moduledoc """
A model check of a route's `max_concurrent_requests` count
(`roadrunner_route_keeper`), run against a real listener and its real
keeper. Random sequences of requests asking for a slot (shedding, waiting
long, waiting briefly, or waiting until their stream resets), releases,
holder and waiter deaths, stream resets, keeper crashes and reloads
changing the ceiling and queue depth are driven one at a time; after each
the system is let settle and checked against the model:

- a slot is granted only while fewer than the ceiling hold one, so no more
  than the ceiling ever run;
- every slot is freed exactly once: once settled, the slots the keeper
  counts are exactly the requests the model has running, after releases,
  kills and keeper restarts alike;
- waiting requests are granted first in, first out: none is granted while
  an older one that cannot time out still waits, even when a new request
  reaches the keeper ahead of the release that freed the slot;
- no request waits past its timeout, and a long wait is never dropped
  except by a keeper crash;
- a request to a route without a ceiling is answered whatever the capped
  route is doing.

Each run ends by releasing every request, after which nothing is running
or waiting.
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
    %% Set by a keeper crash while it waits: its refusal is expected.
    orphaned = false :: boolean()
}).

-record(model, {
    max :: pos_integer(),
    max_queued :: pos_integer(),
    seq = 0 :: non_neg_integer(),
    clients = #{} :: #{pid() => #client{}}
}).

op() ->
    frequency([
        {8, {request, oneof([shed, long, long, short, reset])}},
        {5, {release, nat()}},
        {3, {race, nat(), oneof([shed, long, short])}},
        {2, {kill, nat()}},
        {2, {reset, nat()}},
        {1, crash_keeper},
        {1, {reload, integer(1, 4), integer(1, 4)}},
        {1, cheap}
    ]).

%% A thousand runs: a new request overtaking the release that freed its
%% slot is a race the model needs that many to meet.
prop_model() ->
    proper:numtests(1000, prop_model_runs()).

prop_model_runs() ->
    ?FORALL(
        {Max, MaxQueued, Ops},
        {integer(1, 3), integer(1, 3), list(op())},
        begin
            {ok, Listener} = roadrunner_listener:start_link(?LISTENER, #{
                port => 0, routes => routes(Max, MaxQueued)
            }),
            true = unlink(Listener),
            try
                Model = lists:foldl(fun step/2, #model{max = Max, max_queued = MaxQueued}, Ops),
                ok = finish(Model),
                true
            after
                ok = roadrunner_listener:stop(?LISTENER),
                ok = flush_clients()
            end
        end
    ).

routes(Max, MaxQueued) ->
    [
        #{
            path => ~"/expensive",
            handler => roadrunner_hello_handler,
            max_concurrent_requests => Max,
            overload_mode => {queue, #{max_queued => MaxQueued, timeout => ?LONG_MS}}
        },
        {~"/cheap", roadrunner_hello_handler}
    ].

%% --- the steps ---

step({request, Mode}, Model) ->
    Pid = request(Mode),
    Now = erlang:monotonic_time(millisecond),
    Client = #client{mode = Mode, status = asking, seq = Model#model.seq, t0 = Now},
    Model1 = Model#model{seq = Model#model.seq + 1, clients = (Model#model.clients)#{Pid => Client}},
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
step(crash_keeper, Model) ->
    Keeper = keeper(),
    Orphaned = maps:map(
        fun
            (_Pid, #client{status = parked} = C) -> C#client{orphaned = true};
            (_Pid, C) -> C
        end,
        Model#model.clients
    ),
    exit(Keeper, kill),
    ok = await_new_keeper(Keeper),
    settle(Model#model{clients = Orphaned});
step({reload, Max, MaxQueued}, Model) ->
    ok = roadrunner_listener:reload_routes(?LISTENER, routes(Max, MaxQueued)),
    settle(Model#model{max = Max, max_queued = MaxQueued});
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

%% --- requests ---

%% A process asking for a slot as a connection or a stream worker does.
request(Mode) ->
    Driver = self(),
    {Slots, Counts} = route_counts(),
    Ceiling = roadrunner_route_keeper:ceiling(Slots, Counts, wait(Mode), ?LISTENER),
    spawn(fun() ->
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
            _ ->
                ok
        end
    end).

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
        case lists:member(Pid, keeper_waiters()) of
            true ->
                set_status(Pid, parked, Model);
            false ->
                erlang:yield(),
                await_asked(Pid, Model, Tries - 1)
        end
    end.

%% A request's answer, checked against the model.
apply_result({Pid, Result}, #model{clients = Clients} = Model) ->
    #{Pid := #client{} = Client} = Clients,
    case Result of
        {ok, _Token} ->
            Running = length(pick(running, Model)),
            Running < Model#model.max orelse error({over_ceiling, Running + 1, Model#model.max}),
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

%% Let every message in flight land, then check the keeper against the
%% model: the requests that left the keeper's queue have their answers,
%% and the slots it counts are exactly the requests running.
settle(Model) ->
    settle(Model, 100000).

settle(_Model, 0) ->
    error(never_settled);
settle(Model, Tries) ->
    {Waiting, Watched} = keeper_view(),
    Answering = [P || P <- pick(parked, Model), not lists:member(P, Waiting)],
    Holding = lists:sort(slot_holders()),
    Running = lists:sort(pick(running, Model)),
    %% The keeper still watches a holder whose release or death it has not
    %% handled yet: it may yet hand that slot to a waiter.
    Quiet = Watched =:= length(Holding),
    case {Answering, Quiet andalso Holding} of
        {[_ | _], _} ->
            %% A waiter left the queue: its answer is on its way.
            receive
                {client, Pid, Result} -> settle(apply_result({Pid, Result}, Model), Tries)
            after 10000 -> error({no_answer, Answering})
            end;
        {[], Running} ->
            ok = check_fifo(Model),
            ok = check_counts(Waiting, Running),
            Model;
        {[], _} ->
            %% A released or killed holder's slot is not freed yet, or the
            %% keeper has yet to hear of it.
            erlang:yield(),
            settle(Model, Tries - 1)
    end.

%% No running request was granted ahead of an older one still waiting that
%% could not have timed out.
check_fifo(Model) ->
    Granted = [S || P <- pick(running, Model), #client{seq = S} <- [client(P, Model)]],
    Oldest = lists:max([-1 | Granted]),
    Stuck = [
        C
     || P <- pick(parked, Model),
        #client{mode = M, seq = S} = C <- [client(P, Model)],
        M =/= short,
        S < Oldest
    ],
    Stuck =:= [] orelse error({not_fifo, Stuck}),
    ok.

check_counts(Waiting, Running) ->
    #{in_flight := InFlight, queued := Queued} = route_stats(),
    InFlight =:= length(Running) orelse error({in_flight, InFlight, Running}),
    %% A brief wait may time out since the keeper was asked.
    Queued =< length(Waiting) orelse error({queued, Queued, Waiting}),
    ok.

%% Release everything, letting the queue run dry.
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

%% The pids the keeper has waiting, once it handled what was sent to it.
keeper_waiters() ->
    element(1, keeper_view()).

%% The pids the keeper has waiting and the number of holders it watches,
%% once it handled what was sent to it.
keeper_view() ->
    State = sys:get_state(keeper()),
    {[element(2, W) || W <- maps:values(element(7, State))], map_size(element(9, State))}.

slot_holders() ->
    {Slots, _Counts} = route_counts(),
    [Pid || {Token, Pid} <- ets:tab2list(Slots), is_reference(Token)].

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

%% --- model helpers ---

%% The requests with `Status`, oldest first.
pick(Status, #model{clients = Clients}) ->
    [P || {_Seq, P} <- lists:sort([{Seq, P} || P := #client{seq = Seq, status = S} <- Clients, S =:= Status])].

client(Pid, #model{clients = Clients}) ->
    maps:get(Pid, Clients).

mode(Pid, Model) ->
    (client(Pid, Model))#client.mode.

set_status(Pid, Status, #model{clients = Clients} = Model) ->
    #{Pid := Client} = Clients,
    Model#model{clients = Clients#{Pid := Client#client{status = Status}}}.

index_of(Pid, List) ->
    length(lists:takewhile(fun(P) -> P =/= Pid end, List)).

%% Answers of requests killed before they were read.
flush_clients() ->
    receive
        {client, _, _} -> flush_clients()
    after 0 -> ok
    end.
