-module(roadrunner_overload_queue).
-moduledoc false.

-behaviour(gen_server).

%% One per listener, started and linked by `roadrunner_listener` when
%% `max_concurrent_requests` is finite. It has two jobs.
%%
%% In queue mode (`overload_mode` is a queue) it parks requests that
%% arrive over the listener-wide ceiling until a slot frees, instead of
%% refusing them.
%%
%% In every mode it keeps counting the handlers a connection leaves
%% behind. A slot is held from dispatch until the handler's process ends,
%% and the connection releases it on the worker's `DOWN`. Workers are
%% monitored, not linked, so they can outlive their connection (the client
%% went away, or a drain ended it). A closing connection hands the workers
%% still running to this process (`adopt/4`), which monitors them and
%% releases each slot as its worker ends. Without that, a client could fill
%% the ceiling with slow handlers, drop the connection, reconnect and
%% repeat, running any number of handlers past it.
%%
%% Admission is asynchronous, and that is the whole point. A
%% multiplexed connection releases in-flight slots by processing its own
%% workers' `DOWN` messages, so a loop that blocked waiting for a slot
%% would stop reading the very messages that free one and park forever.
%% Callers therefore `enqueue/5` and go back to their frame loop; the
%% grant arrives later as a message.
%%
%% Each connection keeps its own count of the slots it holds, an
%% `atomics` cell (`roadrunner_conn:with_slot_cell/1`). A grant adds to it
%% before it is sent. A connection that dies without its exit path has
%% the cell emptied here, when it ever parked, or by the listener's reaper
%% otherwise; `atomics:exchange/3` makes every slot released exactly once.
%%
%% The queue sits on the slow path only. Taking a slot is a plain
%% `counters` operation in the caller, and this process is consulted
%% solely when that fails or a request is parked; releases read one atomic
%% (`waiting/1`) and message us only when someone is actually parked.
%%
%% The queue is first in, first out. The parked count that `waiting/1`
%% reads goes up in the request that parks, before its park is sent here,
%% and comes down here as each request leaves, so it also counts the parks
%% still on their way. While it is above zero a new request parks behind
%% them (`roadrunner_conn:acquire_request_slot/5`) instead of taking a slot
%% that frees before this process hands it to the oldest, however far
%% behind its mailbox this process runs. A request that finds `max_queued`
%% parked and no slot free is refused by its connection from the same
%% count, without a message here, unless it found the queue empty a
%% moment before and so raced the park that filled it: that one sends a
%% wake-up. With a slot free it parks anyway, so this process hears of the
%% slot: it serves the queue before it decides whether the new one fits.
%%
%% In queue mode this process runs at high priority (`roadrunner_listener`
%% starts it so), since it hands slots out only as fast as it gets to run:
%% at normal priority, on a server busy with the very requests it counts,
%% it would wait its turn behind them while the slots sat free. So it never
%% waits on another process, and its work stays small: a few map and timer
%% operations for each request, and for a connection's exit or death only
%% that connection's own requests, which are kept per connection.
%%
%% A connection is monitored from its first park until it exits, not each
%% request it parks. A grant can reach a connection that has died, and only
%% that `DOWN` says so: checking whether it is alive as the grant goes out
%% would wait on it, since it then has the grant queued. The `DOWN` takes
%% back what its cell holds, the grant included.

-export([
    start_link/4,
    enqueue/5,
    cancel/2,
    note_release/1,
    waiting/1,
    waiters_ref/1,
    adopt/4
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% A connection that parked a request here. It stays until its exit
%% hand-off (`adopt/4`) or its `DOWN`, so a grant that reaches it after it
%% died is always taken back.
-record(conn, {
    monitor :: reference(),
    %% The conn's in-flight cell: a grant adds its slot to it before it is
    %% sent, so a slot on its way to the conn is already the conn's.
    cell :: atomics:atomics_ref(),
    %% Its parked requests, each with its expiry timer, by token. A token is
    %% chosen by the caller (the stream id), and the caller never uses one
    %% twice.
    parked = #{} :: #{term() => reference()}
}).

-record(state, {
    max :: pos_integer(),
    counter :: counters:counters_ref(),
    max_queued :: pos_integer(),
    waiters :: atomics:atomics_ref(),
    %% Parked requests in arrival order, so grants are FIFO and the
    %% worst-case wait is bounded. A request that leaves without a grant
    %% (cancelled, expired, or its connection went away) leaves its key
    %% behind, counted in `stale`. Stale keys are dropped as they reach the
    %% head, and all at once when they outnumber the parked requests.
    order = queue:new() :: queue:queue(key()),
    stale = 0 :: non_neg_integer(),
    parked = 0 :: non_neg_integer(),
    conns = #{} :: #{pid() => #conn{}},
    %% The monitors of workers whose connection closed while they ran
    %% (`adopt/4`). Each holds one slot, released on its `DOWN`.
    adopted = #{} :: #{reference() => []}
}).

-type key() :: {pid(), term()}.

%% The fewest stale keys worth a pass over `order` to drop them.
-define(MIN_COMPACT, 64).

-spec start_link(pos_integer(), counters:counters_ref(), pos_integer(), high | normal) ->
    {ok, pid()} | {error, term()}.
start_link(Max, Counter, MaxQueued, Priority) ->
    gen_server:start_link(
        ?MODULE, {Max, Counter, MaxQueued}, [{spawn_opt, [{priority, Priority}]}]
    ).

-doc false.
%% Park the caller's request: count it in `Waiters`, then send it here.
%% Returns at once; the outcome arrives as
%% `{roadrunner_slot, Token, granted | timeout | full}`. A `granted`
%% message means the slot has ALREADY been taken on the caller's behalf,
%% so a caller that no longer wants it must release it rather than drop
%% it.
%%
%% The message is built before the count goes up, so no garbage
%% collection (and no `max_heap_size` kill) falls between the count and
%% the send. An exit signal from another process still can: one that
%% arrives while the caller runs takes effect where the caller is next
%% scheduled out, and that can be right before the send. It leaves the
%% count one over for good, which sends every later request through this
%% process and keeps the queue one place shorter for each such exit, but
%% never strands a request. No order of the two steps avoids that:
%% counting after the send would instead leave the count one short, and a
%% request parked alone could then wait out its timeout with a slot free.
-spec enqueue(pid(), atomics:atomics_ref(), term(), atomics:atomics_ref(), pos_integer()) -> ok.
enqueue(Pid, Waiters, Token, Cell, Timeout) ->
    Park = {park, self(), Token, Cell, Timeout},
    ok = atomics:add(Waiters, 1, 1),
    _ = erlang:send(Pid, Park),
    ok.

%% Withdraw a parked request (the stream was reset, or its connection is
%% going away). Racing a grant is expected and safe: the caller may still
%% receive `granted` after cancelling, and must release that slot.
-spec cancel(pid(), term()) -> ok.
cancel(Pid, Token) ->
    gen_server:cast(Pid, {cancel, self(), Token}).

-spec note_release(pid()) -> ok.
note_release(Pid) ->
    _ = erlang:send(Pid, slot_freed),
    ok.

-spec waiting(atomics:atomics_ref()) -> boolean().
waiting(Ref) ->
    atomics:get(Ref, 1) > 0.

-spec waiters_ref(pid()) -> atomics:atomics_ref().
waiters_ref(Pid) ->
    gen_server:call(Pid, waiters_ref, infinity).

%% Hand the in-flight slots of `Workers`, the handlers still running as the
%% calling connection closes, to the keeper at `Pid`, which releases each
%% one when its worker ends (at once for one already gone), and withdraw
%% every request the caller has parked. The caller has emptied its `Cell`
%% already: `Raced` are the grants it held beyond its workers, released at
%% once, and the keeper empties the cell again once the caller's parked
%% requests are withdrawn, for a grant sent in between. Asynchronous: the
%% caller is exiting. The caller checks that the keeper is there first
%% (`roadrunner_conn:hand_off_request_slots/7`): one that stopped with its
%% listener gave back what it counted, and the caller then gives back its
%% own slots.
-spec adopt(pid(), atomics:atomics_ref(), [pid()], non_neg_integer()) -> ok.
adopt(Pid, Cell, Workers, Raced) ->
    _ = erlang:send(Pid, {adopt, self(), Cell, Workers, Raced}),
    ok.

-spec init({pos_integer(), counters:counters_ref(), pos_integer()}) -> {ok, #state{}}.
init({Max, Counter, MaxQueued}) ->
    {ok, #state{
        max = Max,
        counter = Counter,
        max_queued = MaxQueued,
        waiters = atomics:new(1, [{signed, false}])
    }}.

-spec handle_call(term(), gen_server:from(), #state{}) -> {reply, term(), #state{}}.
handle_call(waiters_ref, _From, #state{waiters = Ref} = State) ->
    {reply, Ref, State};
handle_call(_Other, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast({cancel, Pid, Token}, State) ->
    {noreply, withdraw(Pid, Token, State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(slot_freed, State) ->
    {noreply, serve(State)};
handle_info(
    {park, Pid, Token, Cell, Timeout}, #state{parked = Parked, max_queued = MaxQueued} = State
) when
    Parked >= MaxQueued
->
    %% Full. Its connection parked it anyway because a slot looked free,
    %% or it raced others to the last place. Serving first may make room;
    %% otherwise overload sheds rather than growing the queue without
    %% bound, and the caller refuses the request as it does today.
    case serve(State) of
        #state{parked = Still, waiters = Waiters} = Served when Still >= MaxQueued ->
            %% Only the caller's count comes back down: the request was
            %% never parked here.
            ok = atomics:sub(Waiters, 1, 1),
            _ = erlang:send(Pid, {roadrunner_slot, Token, full}),
            {noreply, Served};
        Served ->
            {noreply, serve(park(Pid, Token, Cell, Timeout, Served))}
    end;
handle_info({park, Pid, Token, Cell, Timeout}, State) ->
    %% Serve at once: a slot can free between the caller's failed acquire
    %% and its count going up, and a releaser that read the count as 0
    %% then sent no wake-up. Any release after the count rose sends one.
    {noreply, serve(park(Pid, Token, Cell, Timeout, State))};
handle_info({expire, Pid, Token}, #state{conns = Conns} = State) ->
    case Conns of
        #{Pid := #conn{parked = #{Token := _} = Parked} = Conn} ->
            Expired = left(Pid, Conn#conn{parked = maps:remove(Token, Parked)}, 1, State),
            _ = erlang:send(Pid, {roadrunner_slot, Token, timeout}),
            {noreply, Expired};
        #{} ->
            %% Served or withdrawn while the timer fired.
            {noreply, State}
    end;
handle_info({adopt, Conn, Cell, Workers, Raced}, #state{conns = Conns} = State) ->
    %% The connection's parked requests have no stream left to serve. Once
    %% they are gone no grant can reach its cell, so what it holds now is
    %% the last of the grants that raced the close.
    State1 =
        case Conns of
            #{Conn := #conn{monitor = Mon} = Gone} ->
                _ = erlang:demonitor(Mon, [flush]),
                forget(Conn, Gone, State);
            #{} ->
                State
        end,
    Adopted = lists:foldl(
        fun(Worker, Acc) -> Acc#{erlang:monitor(process, Worker) => []} end,
        State1#state.adopted,
        Workers
    ),
    Late = atomics:exchange(Cell, 1, 0),
    {noreply, release(Raced + Late, State1#state{adopted = Adopted})};
handle_info({'DOWN', Mon, process, _Pid, _Reason}, #state{adopted = Adopted} = State) when
    is_map_key(Mon, Adopted)
->
    %% A handler that outlived its connection ended: its slot is free, and
    %% the oldest parked request may take it.
    {noreply, release(1, State#state{adopted = maps:remove(Mon, Adopted)})};
handle_info({'DOWN', Mon, process, Pid, _Reason}, #state{conns = Conns} = State) when
    is_map_key(Pid, Conns)
->
    %% A connection that parked here died without its exit path. Its
    %% parked requests go, no slot was taken for them, and the slots it
    %% still held (its workers', and grants it never read, sent before or
    %% after it died) are reclaimed from its cell: emptied, so the
    %% listener's reaper cannot release them again.
    #{Pid := #conn{monitor = Mon, cell = Cell} = Gone} = Conns,
    State1 = forget(Pid, Gone, State),
    {noreply, release(atomics:exchange(Cell, 1, 0), State1)};
handle_info(_Msg, State) ->
    {noreply, State}.

%% Park a request at the back of the queue, monitoring its connection
%% from its first park on.
-spec park(pid(), term(), atomics:atomics_ref(), pos_integer(), #state{}) -> #state{}.
park(Pid, Token, Cell, Timeout, #state{order = Order, parked = Parked, conns = Conns} = State) ->
    Timer = erlang:send_after(Timeout, self(), {expire, Pid, Token}),
    Conn =
        case Conns of
            #{Pid := #conn{parked = Tokens} = Known} ->
                Known#conn{parked = Tokens#{Token => Timer}};
            #{} ->
                #conn{
                    monitor = erlang:monitor(process, Pid),
                    cell = Cell,
                    parked = #{Token => Timer}
                }
        end,
    State#state{
        order = queue:in({Pid, Token}, Order), parked = Parked + 1, conns = Conns#{Pid => Conn}
    }.

%% Its listener stops it (`roadrunner_listener`), and connections that
%% outlive the listener still admit requests against its counter: the
%% slots it counts are given back, so they don't shrink the ceiling those
%% connections see for good. That is each worker it watches, still running
%% or not, and each hand-off still in its mailbox, whose workers no one
%% will watch now. Nothing parked holds a slot. A worker it gives back
%% runs on uncounted: only the connections left from before the stop admit
%% new requests, and they are no more than there were. So is what a
%% connection that parked here and died without its exit path still holds
%% (`dead_conns/1`), its `DOWN` perhaps still unread.
-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{counter = Counter, adopted = Adopted, conns = Conns}) ->
    counters:sub(Counter, 1, map_size(Adopted) + unread_hand_offs() + dead_conns(Conns)).

%% The slots of the hand-offs (`adopt/4`) still in the mailbox.
-spec unread_hand_offs() -> non_neg_integer().
unread_hand_offs() ->
    receive
        {adopt, _Conn, Cell, Workers, Raced} ->
            Raced + atomics:exchange(Cell, 1, 0) + length(Workers) + unread_hand_offs()
    after 0 ->
        0
    end.

%% The slots in the cells of the connections that parked here and are
%% dead. The cell is emptied, so whoever looks at it next (the
%% listener's last reaper pass) takes nothing again.
-spec dead_conns(#{pid() => #conn{}}) -> non_neg_integer().
dead_conns(Conns) ->
    lists:sum([
        atomics:exchange(Cell, 1, 0)
     || Pid := #conn{cell = Cell} <- Conns, not is_process_alive(Pid)
    ]).

%% Hand freed slots to the oldest parked requests. Each slot is taken
%% here, on that caller's behalf, so it cannot be stolen by a request
%% that arrives while the grant is in flight. Several slots may have freed
%% at once: keep granting until the queue is empty or the ceiling is
%% reached.
-spec serve(#state{}) -> #state{}.
serve(#state{max = Max, counter = Counter} = State0) ->
    case head(State0) of
        {empty, State} ->
            State;
        {{Pid, Token}, State} ->
            case roadrunner_conn:try_acquire_request_slot(Max, Counter) of
                true ->
                    serve(grant(Pid, Token, State));
                false ->
                    %% Every slot is taken: the oldest keeps its place.
                    State
            end
    end.

%% Hand the slot just taken to the request at the head. Here, as for every
%% answer, the count comes down before the answer goes out, so a caller
%% that has its answer is no longer counted.
-spec grant(pid(), term(), #state{}) -> #state{}.
grant(Pid, Token, #state{order = Order, conns = Conns} = State) ->
    #{Pid := #conn{cell = Cell, parked = #{Token := Timer} = Parked} = Conn} = Conns,
    ok = erlang:cancel_timer(Timer, [{async, true}, {info, false}]),
    ok = atomics:add(Cell, 1, 1),
    Granted = uncount(1, State#state{
        order = queue:drop(Order),
        conns = Conns#{Pid := Conn#conn{parked = maps:remove(Token, Parked)}}
    }),
    _ = erlang:send(Pid, {roadrunner_slot, Token, granted}),
    Granted.

%% The oldest parked request, after dropping the keys of requests that
%% left without a grant.
-spec head(#state{}) -> {key() | empty, #state{}}.
head(#state{order = Order, conns = Conns, stale = Stale} = State) ->
    case queue:peek(Order) of
        empty ->
            {empty, State};
        {value, {Pid, Token} = Key} ->
            case Conns of
                #{Pid := #conn{parked = #{Token := _}}} ->
                    {Key, State};
                #{} ->
                    head(State#state{order = queue:drop(Order), stale = Stale - 1})
            end
    end.

%% Release `N` slots and hand them to the parked requests.
-spec release(non_neg_integer(), #state{}) -> #state{}.
release(0, State) ->
    State;
release(N, #state{counter = Counter} = State) ->
    ok = counters:sub(Counter, 1, N),
    serve(State).

%% Remove a parked request without telling the caller: it asked to cancel.
-spec withdraw(pid(), term(), #state{}) -> #state{}.
withdraw(Pid, Token, #state{conns = Conns} = State) ->
    case Conns of
        #{Pid := #conn{parked = #{Token := Timer} = Parked} = Conn} ->
            ok = erlang:cancel_timer(Timer, [{async, true}, {info, false}]),
            left(Pid, Conn#conn{parked = maps:remove(Token, Parked)}, 1, State);
        #{} ->
            State
    end.

%% Drop a connection that is going away, with every request it parked.
-spec forget(pid(), #conn{}, #state{}) -> #state{}.
forget(Pid, #conn{parked = Parked}, #state{conns = Conns} = State) ->
    _ = maps:foreach(
        fun(_Token, Timer) -> erlang:cancel_timer(Timer, [{async, true}, {info, false}]) end,
        Parked
    ),
    left_stale(map_size(Parked), State#state{conns = maps:remove(Pid, Conns)}).

%% `N` requests of the connection `Pid`, now `Conn`, left without a grant.
-spec left(pid(), #conn{}, pos_integer(), #state{}) -> #state{}.
left(Pid, Conn, N, #state{conns = Conns} = State) ->
    left_stale(N, State#state{conns = Conns#{Pid := Conn}}).

%% Their keys stay in `order` until they reach the head, or until there
%% are more of them than parked requests: then one pass drops them all,
%% so a client that parks and cancels behind a head that is never served
%% cannot grow it without bound.
-spec left_stale(non_neg_integer(), #state{}) -> #state{}.
left_stale(N, #state{stale = Stale} = State) ->
    compact(uncount(N, State#state{stale = Stale + N})).

-spec compact(#state{}) -> #state{}.
compact(#state{stale = Stale, parked = Parked} = State) when
    Stale < ?MIN_COMPACT; Stale =< Parked
->
    State;
compact(#state{order = Order, conns = Conns} = State) ->
    Live = queue:filter(
        fun({Pid, Token}) ->
            case Conns of
                #{Pid := #conn{parked = #{Token := _}}} -> true;
                #{} -> false
            end
        end,
        Order
    ),
    State#state{order = Live, stale = 0}.

%% `N` parked requests left, granted or not.
-spec uncount(non_neg_integer(), #state{}) -> #state{}.
uncount(N, #state{waiters = Waiters, parked = Parked} = State) ->
    ok = atomics:sub(Waiters, 1, N),
    State#state{parked = Parked - N}.
