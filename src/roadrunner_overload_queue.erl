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
%% Callers therefore `enqueue/4` and go back to their frame loop; the
%% grant arrives later as a message.
%%
%% Each connection keeps its own count of the slots it holds, an
%% `atomics` cell (`roadrunner_conn:with_slot_cell/1`). A grant adds to it
%% before it is sent. A connection that dies without its exit path has
%% the cell emptied here, when it was parked, or by the listener's reaper
%% otherwise; `atomics:exchange/3` makes every slot released exactly once.
%%
%% The queue sits on the slow path only. Taking a slot is a plain
%% `counters` operation in the caller, and this process is consulted
%% solely when that fails; releases read one atomic (`waiting/1`) and
%% message us only when someone is actually parked.

-export([
    start_link/3,
    enqueue/4,
    cancel/2,
    note_release/1,
    waiting/1,
    waiters_ref/1,
    adopt/4
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% A parked request. `token` is chosen by the caller (the stream id) and
%% only has to be unique within that caller, since entries are keyed by
%% `{pid, token}`.
-record(entry, {
    pid :: pid(),
    token :: term(),
    %% The caller's in-flight cell: a grant adds its slot to it before it
    %% is sent, so a slot on its way to a conn is already the conn's.
    cell :: atomics:atomics_ref(),
    monitor :: reference(),
    timer :: reference()
}).

-record(state, {
    max :: pos_integer(),
    counter :: counters:counters_ref(),
    max_queued :: pos_integer(),
    waiters :: atomics:atomics_ref(),
    %% Keys in arrival order, so grants are FIFO and the worst-case wait
    %% is bounded. An entry that was served, expired or cancelled is
    %% removed from `live` but left here, so the order queue is drained
    %% lazily on the next pop rather than searched on every removal.
    order = queue:new() :: queue:queue(key()),
    live = #{} :: #{key() => #entry{}},
    %% The monitors of workers whose connection closed while they ran
    %% (`adopt/4`). Each holds one slot, released on its `DOWN`.
    adopted = #{} :: #{reference() => []}
}).

-type key() :: {pid(), term()}.

-spec start_link(pos_integer(), counters:counters_ref(), pos_integer()) ->
    {ok, pid()} | {error, term()}.
start_link(Max, Counter, MaxQueued) ->
    gen_server:start_link(?MODULE, {Max, Counter, MaxQueued}, []).

-doc false.
%% Park the caller's request. Returns immediately; the outcome arrives as
%% `{roadrunner_slot, Token, granted | timeout | full}`. A `granted`
%% message means the slot has ALREADY been taken on the caller's behalf,
%% so a caller that no longer wants it must release it rather than drop
%% it.
-spec enqueue(pid(), term(), atomics:atomics_ref(), pos_integer()) -> ok.
enqueue(Pid, Token, Cell, Timeout) ->
    gen_server:cast(Pid, {enqueue, self(), Token, Cell, Timeout}).

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
%% caller is exiting. A keeper already gone went down with its listener,
%% whose counter nothing reads any more.
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
handle_cast(
    {enqueue, Pid, Token, _Cell, _Timeout}, #state{live = Live, max_queued = MaxQueued} = State
) when
    map_size(Live) >= MaxQueued
->
    %% The shed valve: overload still sheds rather than growing the queue
    %% without bound. The caller refuses the request as it does today.
    _ = erlang:send(Pid, {roadrunner_slot, Token, full}),
    {noreply, State};
handle_cast({enqueue, Pid, Token, Cell, Timeout}, State) ->
    #state{order = Order, live = Live, waiters = Waiters} = State,
    Key = {Pid, Token},
    Entry = #entry{
        pid = Pid,
        token = Token,
        cell = Cell,
        monitor = erlang:monitor(process, Pid),
        timer = erlang:send_after(Timeout, self(), {expire, Key})
    },
    ok = atomics:add(Waiters, 1, 1),
    %% Try to serve immediately. Enqueuing is a cast, so a slot can free
    %% between the caller's failed acquire and this park: the releaser
    %% would have read the waiters atomic as 0, sent no wake-up, and left
    %% this request stranded until its deadline. Serving here closes that
    %% window from the other side. Once the atomic is set above, any
    %% later release sees it and wakes us the normal way.
    Parked = State#state{order = queue:in(Key, Order), live = Live#{Key => Entry}},
    {noreply, serve(Parked)};
handle_cast({cancel, Pid, Token}, State) ->
    {noreply, forget({Pid, Token}, State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(slot_freed, State) ->
    {noreply, serve(State)};
handle_info({expire, Key}, State) ->
    {noreply, resolve(Key, timeout, State)};
handle_info(
    {adopt, Conn, Cell, Workers, Raced}, #state{adopted = Adopted, live = Live} = State
) ->
    %% The connection's parked requests have no stream left to serve. Once
    %% they are gone no grant can reach its cell, so what it holds now is
    %% the last of the grants that raced the close.
    Parked = [Key || {ConnPid, _Token} = Key <- maps:keys(Live), ConnPid =:= Conn],
    State1 = lists:foldl(fun forget/2, State, Parked),
    Adopted1 = lists:foldl(
        fun(Worker, Acc) -> Acc#{erlang:monitor(process, Worker) => []} end, Adopted, Workers
    ),
    Late = atomics:exchange(Cell, 1, 0),
    {noreply, release(Raced + Late, State1#state{adopted = Adopted1})};
handle_info({'DOWN', Mon, process, _Pid, _Reason}, #state{adopted = Adopted} = State) when
    is_map_key(Mon, Adopted)
->
    %% A handler that outlived its connection ended: its slot is free, and
    %% the oldest parked request may take it.
    {noreply, release(1, State#state{adopted = maps:remove(Mon, Adopted)})};
handle_info({'DOWN', Mon, process, _Pid, _Reason}, #state{live = Live} = State) ->
    %% A parked connection died. Drop everything it was waiting on; no
    %% slot was taken for those entries. If it died without its exit path,
    %% the slots it still held (its workers', and grants it never read) are
    %% reclaimed from its cell: emptied, so the listener's reaper or the
    %% connection's own exit path cannot release them again.
    [#entry{pid = Pid, token = Token, cell = Cell}] =
        [E || _ := #entry{monitor = M} = E <- Live, M =:= Mon],
    State1 = forget({Pid, Token}, State),
    {noreply, release(atomics:exchange(Cell, 1, 0), State1)};
handle_info(_Msg, State) ->
    {noreply, State}.

%% Hand the freed slot to the oldest parked request. The slot is taken
%% here, on that caller's behalf, so it cannot be stolen by a request
%% that arrives while the grant is in flight.
-spec serve(#state{}) -> #state{}.
serve(#state{max = Max, counter = Counter} = State) ->
    case next(State) of
        empty ->
            State;
        {Key, #entry{pid = Pid, token = Token, cell = Cell} = Entry, State1} ->
            case roadrunner_conn:try_acquire_request_slot(Max, Counter) of
                true ->
                    ok = cancel_entry(Entry),
                    ok = atomics:add(Cell, 1, 1),
                    _ = erlang:send(Pid, {roadrunner_slot, Token, granted}),
                    %% Several slots may have freed at once: keep granting
                    %% until the queue is empty or the ceiling is reached.
                    serve(granted_to(Pid, Cell, decrement(State1)));
                false ->
                    %% Lost the slot to a fresh request between the
                    %% release and here. Keep our place at the head.
                    requeue(Key, Entry, State1)
            end
    end.

%% A grant to a conn that is already dead is never read. Its `DOWN` went
%% with the entry's monitor, and the listener's reaper may have emptied
%% its cell before this grant reached it, so the cell is emptied again
%% here: whichever exchange comes first takes each slot, once.
-spec granted_to(pid(), atomics:atomics_ref(), #state{}) -> #state{}.
granted_to(Pid, Cell, #state{counter = Counter} = State) ->
    case is_process_alive(Pid) of
        true ->
            State;
        false ->
            ok = counters:sub(Counter, 1, atomics:exchange(Cell, 1, 0)),
            State
    end.

%% Release `N` slots and hand them to the parked requests.
-spec release(non_neg_integer(), #state{}) -> #state{}.
release(0, State) ->
    State;
release(N, #state{counter = Counter} = State) ->
    ok = counters:sub(Counter, 1, N),
    serve(State).

-spec next(#state{}) -> empty | {key(), #entry{}, #state{}}.
next(#state{order = Order, live = Live} = State) ->
    case queue:out(Order) of
        {empty, _} ->
            empty;
        {{value, Key}, Rest} ->
            case Live of
                #{Key := Entry} ->
                    {Key, Entry, State#state{order = Rest, live = maps:remove(Key, Live)}};
                _ ->
                    next(State#state{order = Rest})
            end
    end.

-spec requeue(key(), #entry{}, #state{}) -> #state{}.
requeue(Key, Entry, #state{order = Order, live = Live} = State) ->
    State#state{order = queue:in_r(Key, Order), live = Live#{Key => Entry}}.

-spec resolve(key(), timeout, #state{}) -> #state{}.
resolve(Key, Reply, #state{live = Live} = State) ->
    case Live of
        #{Key := #entry{pid = Pid, token = Token} = Entry} ->
            ok = cancel_entry(Entry),
            _ = erlang:send(Pid, {roadrunner_slot, Token, Reply}),
            decrement(State#state{live = maps:remove(Key, Live)});
        _ ->
            State
    end.

%% Remove without telling the caller — it either asked to cancel or is
%% gone.
-spec forget(key(), #state{}) -> #state{}.
forget(Key, #state{live = Live} = State) ->
    case Live of
        #{Key := Entry} ->
            ok = cancel_entry(Entry),
            decrement(State#state{live = maps:remove(Key, Live)});
        _ ->
            State
    end.

-spec cancel_entry(#entry{}) -> ok.
cancel_entry(#entry{monitor = Mon, timer = Timer}) ->
    _ = erlang:demonitor(Mon, [flush]),
    _ = erlang:cancel_timer(Timer),
    ok.

-spec decrement(#state{}) -> #state{}.
decrement(#state{waiters = Waiters} = State) ->
    ok = atomics:sub(Waiters, 1, 1),
    State.
