-module(roadrunner_route_keeper).
-moduledoc false.

-behaviour(gen_server).

%% The count of one route's `max_concurrent_requests` (`roadrunner_router`),
%% and the process that hands its slots out. A listener starts one keeper
%% per route that sets a ceiling, linked to it, so admission to one route
%% never waits behind another route's traffic, and a fault in one keeper
%% leaves the other routes' counts alone.
%%
%% A slot is a row in the route's `slots` table, `{Token, Holder}`, and the
%% table's size less the `keeper` row (which names the keeper serving it)
%% is the number of requests running. Only the keeper adds rows, and only
%% while fewer than the ceiling are there, so the route can never run more
%% than its ceiling, whatever else happens at the same time. A row is
%% removed once, by whoever gets there first: the holder as its request
%% ends (`release/2`), or the keeper on the holder's `'DOWN'`. A holder
%% that dies in any way (killed, over `max_heap_size`, its connection
%% gone) frees its slot as soon as the keeper sees it go.
%%
%% Taking a slot is a call: the caller sends `acquire` to the keeper
%% named in the table and waits. The keeper monitors the caller, adds its
%% row and answers `granted`; when the route is full it answers `refused`,
%% or in queue mode parks the caller and answers when a slot frees (first
%% in, first out) or its `timeout` passes. A shed route full of requests
%% does not reach the keeper at all: the caller reads the table's size and
%% the ceiling in `counts` first, so a flood at a full route costs the
%% keeper nothing. A queue route does the same once its queue is full too.
%%
%% The table and `counts` belong to the listener, not to the keeper, so
%% a keeper that crashes loses no count: the listener starts a new one on
%% the same table, which monitors every holder still in it (`init/1`).
%% Requests that were waiting for the dead keeper see it go and are refused,
%% each removing the row the keeper may have added for it before dying,
%% so a slot whose `granted` never arrived is not left taken. Rows are
%% never added by anyone but the keeper serving the table, so a restart
%% cannot let in more than the ceiling while the old holders still run.
%%
%% `counts` holds the ceiling and the queue depth the listener configured
%% (both updated in place by `reload_routes/2`, so a new ceiling applies
%% to the requests already counted), the number of requests waiting, and
%% the cumulative number refused.

-export([
    new/4,
    start_link/3,
    configure/3,
    set_draining/2,
    ceiling/4,
    stats/1,
    acquire/1,
    acquire/2,
    release/2
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export_type([ceiling/0, table/0, token/0, wait/0]).

%% The `counts` cells.
-define(MAX, 1).
-define(MAX_QUEUED, 2).
-define(QUEUED, 3).
-define(THROTTLED, 4).

%% A route's ceiling as a request meets it, carried in the route's compiled
%% entry: the slot table and counts the listener keeps for the route across
%% reloads, how a request over the ceiling waits (`shed`, or a queue
%% timeout in milliseconds), the `Retry-After` its refusal carries, and the
%% listener that reports it.
-record(ceiling, {
    slots :: table(),
    counts :: atomics:atomics_ref(),
    wait :: wait(),
    retry_after :: pos_integer(),
    listener :: atom()
}).

-opaque ceiling() :: #ceiling{}.
-type table() :: ets:tid().
-type token() :: reference().
-type wait() :: shed | pos_integer().

%% A request waiting for a slot.
-record(waiter, {
    pid :: pid(),
    monitor :: reference(),
    timer :: reference()
}).

-record(state, {
    listener :: pid(),
    slots :: table(),
    counts :: atomics:atomics_ref(),
    %% Set once the route left the table: the keeper tells the listener
    %% when nothing is running or waiting any more.
    draining :: boolean(),
    %% Waiting tokens in arrival order. One that stopped waiting (served,
    %% expired, gone) leaves `waiters` but stays here until a pop reaches
    %% it, so a removal does not search the queue.
    order = queue:new() :: queue:queue(token()),
    waiters = #{} :: #{token() => #waiter{}},
    %% Every monitor this keeper holds, waiting or holding a slot.
    monitors = #{} :: #{reference() => {holder | waiter, token()}},
    %% The monitor of each slot's holder, by its token.
    holders = #{} :: #{token() => reference()}
}).

%% --- listener side ---

%% A route's slot table and counts, made in (and owned by) the listener so
%% they outlive any one keeper.
-spec new(pos_integer(), pos_integer(), boolean(), pid()) ->
    {pid(), table(), atomics:atomics_ref()}.
new(Max, MaxQueued, Draining, Listener) ->
    Slots = ets:new(roadrunner_route_slots, [set, public, {read_concurrency, true}]),
    Counts = atomics:new(4, [{signed, false}]),
    ok = atomics:put(Counts, ?MAX, Max),
    ok = atomics:put(Counts, ?MAX_QUEUED, MaxQueued),
    {ok, Pid} = start_link(Slots, Counts, {Draining, Listener}),
    {Pid, Slots, Counts}.

%% Start a keeper on a route's table, the first or one taking over from a
%% keeper that died.
-spec start_link(table(), atomics:atomics_ref(), {boolean(), pid()}) -> {ok, pid()}.
start_link(Slots, Counts, {Draining, Listener}) ->
    gen_server:start_link(?MODULE, {Slots, Counts, Draining, Listener}, []).

%% A new ceiling and queue depth, from a reload. They apply at once, to the
%% requests already counted too; a raised ceiling hands its slots to the
%% requests waiting. Asynchronous, so the listener never waits on a keeper.
-spec configure(pid(), atomics:atomics_ref(), {pos_integer(), pos_integer()}) -> ok.
configure(Pid, Counts, {Max, MaxQueued}) ->
    ok = atomics:put(Counts, ?MAX, Max),
    ok = atomics:put(Counts, ?MAX_QUEUED, MaxQueued),
    _ = erlang:send(Pid, serve),
    ok.

%% The route left the table (`true`) or came back to it (`false`).
-spec set_draining(pid(), boolean()) -> ok.
set_draining(Pid, Draining) ->
    _ = erlang:send(Pid, {draining, Draining}),
    ok.

%% The ceiling a compiled route carries.
-spec ceiling(
    table(),
    atomics:atomics_ref(),
    {shed, #{retry_after := pos_integer()}} | {queue, #{timeout := pos_integer()}},
    atom()
) -> ceiling().
ceiling(Slots, Counts, {shed, #{retry_after := RetryAfter}}, Listener) ->
    #ceiling{
        slots = Slots, counts = Counts, wait = shed, retry_after = RetryAfter, listener = Listener
    };
ceiling(Slots, Counts, {queue, #{timeout := Timeout}}, Listener) ->
    #ceiling{
        slots = Slots, counts = Counts, wait = Timeout, retry_after = 1, listener = Listener
    }.

%% What `roadrunner_listener:info/1` reports of a route.
-spec stats({table(), atomics:atomics_ref()}) ->
    #{
        max_concurrent_requests := pos_integer(),
        in_flight := non_neg_integer(),
        queued := non_neg_integer(),
        throttled := non_neg_integer()
    }.
stats({Slots, Counts}) ->
    #{
        max_concurrent_requests => atomics:get(Counts, ?MAX),
        in_flight => ets:info(Slots, size) - 1,
        queued => atomics:get(Counts, ?QUEUED),
        throttled => atomics:get(Counts, ?THROTTLED)
    }.

%% --- request side ---

%% Take a slot for the calling process, waiting in queue mode. `{refused,
%% RetryAfter}` is counted and reported as a throttled request.
-spec acquire(ceiling()) -> {ok, token()} | {refused, pos_integer()}.
acquire(#ceiling{} = Ceiling) ->
    case ask(Ceiling) of
        {asked, Token} ->
            receive
                {Token, granted} -> {ok, Token};
                {Token, refused} -> refuse(Ceiling);
                {'DOWN', Token, process, _Keeper, _Reason} -> keeper_gone(Token, Ceiling)
            end;
        refused ->
            refuse(Ceiling)
    end.

%% `acquire/1` for a stream worker, which also stops waiting on `Reset`,
%% the message that says its stream was reset: it returns `reset` and the
%% worker ends, which frees a slot granted in the meantime (the keeper
%% monitors it).
-spec acquire(ceiling(), term()) -> {ok, token()} | {refused, pos_integer()} | reset.
acquire(#ceiling{} = Ceiling, Reset) ->
    case ask(Ceiling) of
        {asked, Token} ->
            receive
                {Token, granted} ->
                    {ok, Token};
                {Token, refused} ->
                    refuse(Ceiling);
                {'DOWN', Token, process, _Keeper, _Reason} ->
                    keeper_gone(Token, Ceiling);
                Reset ->
                    true = erlang:demonitor(Token, [flush]),
                    reset
            end;
        refused ->
            refuse(Ceiling)
    end.

%% Hand a slot back as its request ends. A table already gone went with its
%% listener, which counts nothing any more.
-spec release(ceiling(), token()) -> ok.
release(#ceiling{slots = Slots}, Token) ->
    try
        true = ets:delete(Slots, Token),
        _ = erlang:send(ets:lookup_element(Slots, keeper, 2), {done, Token}),
        ok
    catch
        error:badarg -> ok
    end.

%% Ask the keeper for a slot, unless the route is full and the request
%% would not wait for one. The ask carries the token the slot will be known
%% by: a monitor of the keeper that is also the alias its answer comes on.
-spec ask(ceiling()) -> {asked, token()} | refused.
ask(#ceiling{slots = Slots, counts = Counts, wait = Wait}) ->
    case full(ets:info(Slots, size), Counts, Wait) of
        true ->
            refused;
        false ->
            try ets:lookup_element(Slots, keeper, 2) of
                Keeper ->
                    Token = erlang:monitor(process, Keeper, [{alias, reply_demonitor}]),
                    _ = erlang:send(Keeper, {acquire, Token, self(), Wait}),
                    {asked, Token}
            catch
                error:badarg -> refused
            end
    end.

%% Whether a request would be turned away without asking: the route runs
%% its ceiling and, for a queue, its queue is full too. A table already gone
%% (`undefined`) went with its listener.
-spec full(non_neg_integer() | undefined, atomics:atomics_ref(), wait()) -> boolean().
full(undefined, _Counts, _Wait) ->
    true;
full(Rows, Counts, shed) ->
    Rows - 1 >= atomics:get(Counts, ?MAX);
full(Rows, Counts, _Timeout) ->
    Rows - 1 >= atomics:get(Counts, ?MAX) andalso
        atomics:get(Counts, ?QUEUED) >= atomics:get(Counts, ?MAX_QUEUED).

%% The keeper died before it answered. It may have added the caller's row
%% first, so the row goes, or the slot would stay taken by a request that
%% never ran, and the keeper serving the table now hears of it: it may watch
%% that row already and have requests waiting for the slot.
-spec keeper_gone(token(), ceiling()) -> {refused, pos_integer()}.
keeper_gone(Token, Ceiling) ->
    ok = release(Ceiling, Token),
    refuse(Ceiling).

-spec refuse(ceiling()) -> {refused, pos_integer()}.
refuse(#ceiling{counts = Counts, retry_after = RetryAfter, listener = Listener}) ->
    ok = atomics:add(Counts, ?THROTTLED, 1),
    ok = roadrunner_event:request_throttled(Listener, route_max_concurrent_requests),
    {refused, RetryAfter}.

%% --- keeper ---

-spec init({table(), atomics:atomics_ref(), boolean(), pid()}) -> {ok, #state{}}.
init({Slots, Counts, Draining, Listener}) ->
    %% Whatever waited for a keeper before this one was refused when it went.
    ok = atomics:put(Counts, ?QUEUED, 0),
    %% A keeper taking over watches every holder the table still has.
    Holders = ets:select(Slots, [{{'$1', '$2'}, [{is_reference, '$1'}], [{{'$1', '$2'}}]}]),
    State = lists:foldl(
        fun({Token, Pid}, Acc) -> watch_holder(Token, erlang:monitor(process, Pid), Acc) end,
        #state{listener = Listener, slots = Slots, counts = Counts, draining = Draining},
        Holders
    ),
    true = ets:insert(Slots, {keeper, self()}),
    {ok, drained(State)}.

-spec handle_call(term(), gen_server:from(), #state{}) -> {reply, {error, unknown_call}, #state{}}.
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info({acquire, Token, Pid, Wait}, State0) ->
    %% The requests already waiting go first.
    State = serve(State0),
    case room(State) of
        true -> {noreply, grant(Token, Pid, erlang:monitor(process, Pid), State)};
        false -> {noreply, wait(Token, Pid, Wait, State)}
    end;
handle_info({done, Token}, #state{holders = Holders, monitors = Monitors} = State) ->
    case Holders of
        #{Token := Mon} ->
            true = erlang:demonitor(Mon, [flush]),
            State1 = State#state{
                holders = maps:remove(Token, Holders), monitors = maps:remove(Mon, Monitors)
            },
            {noreply, drained(serve(State1))};
        #{} ->
            %% A row this keeper does not watch went (a request that saw the
            %% keeper before this one go): its slot may be free.
            {noreply, drained(serve(State))}
    end;
handle_info({expire, Token}, #state{waiters = Waiters} = State) ->
    case Waiters of
        #{Token := #waiter{monitor = Mon}} ->
            _ = erlang:send(Token, {Token, refused}),
            true = erlang:demonitor(Mon, [flush]),
            {noreply, drained(forget_waiter(Token, Mon, State))};
        #{} ->
            {noreply, State}
    end;
handle_info({'DOWN', Mon, process, _Pid, _Reason}, #state{monitors = Monitors} = State) ->
    case Monitors of
        #{Mon := {holder, Token}} ->
            %% Whichever of this and the holder's own `release/2` removes the
            %% row frees the slot; the other finds nothing to remove.
            true = ets:delete(State#state.slots, Token),
            State1 = State#state{
                holders = maps:remove(Token, State#state.holders),
                monitors = maps:remove(Mon, Monitors)
            },
            {noreply, drained(serve(State1))};
        #{Mon := {waiter, Token}} ->
            #{Token := #waiter{timer = Timer}} = State#state.waiters,
            _ = erlang:cancel_timer(Timer),
            {noreply, drained(forget_waiter(Token, Mon, State))};
        #{} ->
            {noreply, State}
    end;
handle_info(serve, State) ->
    {noreply, serve(State)};
handle_info({draining, Draining}, State) ->
    {noreply, drained(State#state{draining = Draining})};
handle_info(_Msg, State) ->
    {noreply, State}.

%% Whether one more request may run.
-spec room(#state{}) -> boolean().
room(#state{slots = Slots, counts = Counts}) ->
    ets:info(Slots, size) - 1 < atomics:get(Counts, ?MAX).

%% Give `Pid` the slot `Token`, watched by `Mon`. The row goes in before the
%% answer goes out: a keeper killed between the two leaves a row the
%% caller removes when it sees the keeper gone, never a running request
%% without one.
-spec grant(token(), pid(), reference(), #state{}) -> #state{}.
grant(Token, Pid, Mon, #state{slots = Slots} = State) ->
    true = ets:insert(Slots, {Token, Pid}),
    _ = erlang:send(Token, {Token, granted}),
    watch_holder(Token, Mon, State).

-spec watch_holder(token(), reference(), #state{}) -> #state{}.
watch_holder(Token, Mon, #state{holders = Holders, monitors = Monitors} = State) ->
    State#state{holders = Holders#{Token => Mon}, monitors = Monitors#{Mon => {holder, Token}}}.

%% The route is full: refuse, or park the request while the queue has room.
-spec wait(token(), pid(), wait(), #state{}) -> #state{}.
wait(Token, _Pid, shed, State) ->
    _ = erlang:send(Token, {Token, refused}),
    State;
wait(Token, Pid, Timeout, #state{counts = Counts} = State) ->
    case atomics:get(Counts, ?QUEUED) < atomics:get(Counts, ?MAX_QUEUED) of
        true ->
            #state{order = Order, waiters = Waiters, monitors = Monitors} = State,
            Mon = erlang:monitor(process, Pid),
            Waiter = #waiter{
                pid = Pid,
                monitor = Mon,
                timer = erlang:send_after(Timeout, self(), {expire, Token})
            },
            ok = atomics:add(Counts, ?QUEUED, 1),
            State#state{
                order = queue:in(Token, Order),
                waiters = Waiters#{Token => Waiter},
                monitors = Monitors#{Mon => {waiter, Token}}
            };
        false ->
            _ = erlang:send(Token, {Token, refused}),
            State
    end.

%% Hand free slots to the waiting requests, oldest first.
-spec serve(#state{}) -> #state{}.
serve(#state{order = Order, waiters = Waiters} = State) ->
    case queue:out(Order) of
        {empty, _} ->
            State;
        {{value, Token}, Rest} ->
            case Waiters of
                #{Token := #waiter{pid = Pid, monitor = Mon, timer = Timer}} ->
                    case room(State) of
                        true ->
                            _ = erlang:cancel_timer(Timer),
                            State1 = forget_waiter(Token, Mon, State#state{order = Rest}),
                            serve(grant(Token, Pid, Mon, State1));
                        false ->
                            State
                    end;
                #{} ->
                    serve(State#state{order = Rest})
            end
    end.

%% A request stops waiting: served, expired or gone. Its token stays in
%% `order` until a pop reaches it.
-spec forget_waiter(token(), reference(), #state{}) -> #state{}.
forget_waiter(Token, Mon, #state{waiters = Waiters, monitors = Monitors, counts = Counts} = State) ->
    ok = atomics:sub(Counts, ?QUEUED, 1),
    State#state{waiters = maps:remove(Token, Waiters), monitors = maps:remove(Mon, Monitors)}.

%% A draining keeper with nothing running or waiting tells its listener,
%% which stops it.
-spec drained(#state{}) -> #state{}.
drained(#state{draining = true, slots = Slots, waiters = Waiters, listener = Listener} = State) when
    map_size(Waiters) =:= 0
->
    case ets:info(Slots, size) of
        1 -> _ = erlang:send(Listener, {route_keeper_drained, self()});
        _Busy -> ok
    end,
    State;
drained(State) ->
    State.
