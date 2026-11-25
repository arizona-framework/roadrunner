-module(roadrunner_route_keeper).
-moduledoc false.

-behaviour(gen_server).

%% The count of one route's `max_concurrent_requests` (`roadrunner_router`),
%% and the process that watches it. A listener starts one keeper per route
%% that sets a ceiling, linked to it, so admission to one route never waits
%% behind another route's traffic, and a fault in one keeper leaves the
%% other routes' counts alone.
%%
%% A slot is a row `{K, Owner, Holder}` in the route's `slots` table, K in
%% 1..Max. `ets:insert_new/2` on K is the admission and the record of who
%% holds the slot, in one step: with only Max keys, the route can never run
%% more than its ceiling, whatever else happens at the same time. A request
%% that inserts its row also reads the table's size after the insert and
%% backs off when the route runs over its ceiling, which only a reload that
%% lowered it leaves behind. A row is removed by matching all of it, so a
%% second removal, or one after the slot went to someone else, does
%% nothing. The table's size is the number of requests running.
%%
%% Most requests never reach the keeper:
%%
%% - an HTTP/1.1 connection's first request asks the keeper, which grants it
%%   a free key, watches the connection for the rest of its life, and keeps
%%   that key as the connection's home in the route's `regs` table. Its
%%   later requests insert the home row themselves and delete it as they
%%   end. A home taken by another request, or past a lowered ceiling, sends
%%   the request to the keeper, which grants another key and makes it the
%%   new home. When the connection dies the keeper deletes the home row it
%%   may still hold;
%% - a stream worker of HTTP/2 or HTTP/3 takes a slot owned by the process
%%   that monitors it (the connection, or HTTP/3's loop), while the route is
%%   under half its ceiling and that owner is registered; the keeper
%%   registers an owner, and watches it for the rest of its life, when one
%%   of its workers first asks. Before its row, the worker tells the owner
%%   its key (`{roadrunner_route_slot, ...}`, which the owner keeps with
%%   `noted/1`), writes an intent `{Owner, Worker, K}` in the route's
%%   `intents` table, and checks that the owner is still registered. The
%%   owner frees the row, then the intent, on the worker's `'DOWN'`
%%   (`worker_down/1`): it must take the key and the `'DOWN'` in the same
%%   receive, so the key, sent first, is handled first. When the owner dies
%%   the keeper takes its registration, then watches every worker it has
%%   an intent of, freeing each row as its worker ends: either the keeper
%%   finds a worker's intent, or the worker finds the registration gone
%%   before its row exists. An owner that lives on but stops answering its
%%   workers (an HTTP/2 connection lingering after its GOAWAY) tells the
%%   keeper of every route it may hold a slot of (`hand_over/1`), which
%%   takes its registration the same way, and never registers it again
%%   while it lives. A worker killed between its intent and backing
%%   off leaves only the intent, which the keeper looks for again a second
%%   later; one stalled for longer than that before it died leaves the
%%   intent, a few words and never a slot, until a keeper takes over or the
%%   route's tables go. A worker at a route half full or more, or one whose
%%   owner is not registered, asks the keeper, which grants it a key and
%%   watches it: the worker's exit, however it comes, frees the slot.
%%
%% The gate, in the `'$keeper'` row of `regs`, sends every request to the
%% keeper while requests wait for a slot (so a new request queues behind
%% them) or the route drains, and has a request that ends tell the keeper
%% its key (`{done, K}`) while requests wait, the route drains, or the
%% keeper collects free keys. Two races decide whether a slot is lost or
%% let in late, and the gate's row settles both:
%%
%% - the keeper closes the gate before its last look for room for a request
%%   it may park, and a request that ends reads the gate after deleting its
%%   row. The two touch the gate's row, so one comes first: either the
%%   keeper sees the slot free, or the request sees the gate closed and
%%   tells the keeper, so no request waits beside a free slot;
%% - a draining keeper marks the gate before it looks at the table's size,
%%   and a request that inserted its row reads the gate after the insert:
%%   either the keeper sees the row and stays, or the request sees the
%%   drain and backs off, so nothing runs on a table the listener deleted.
%%
%% Each side reads the table's size, a count ETS updates with every insert
%% and delete, after its own operation on the gate's row, so it sees any
%% row the other side changed before that.
%%
%% The keeper grants the keys it heard were freed first, then tries a few
%% keys in turn, then scans the table for the free ones and keeps them for
%% the grants to come. When a scan finds the route at least half full,
%% every request that ends tells the keeper its key until the route is back
%% under a quarter, so the keys it keeps stay complete and it seldom scans.
%%
%% The tables and `counts` belong to the listener, not to the keeper, so a
%% keeper that crashes loses no count: the listener starts a new one on the
%% same tables, which watches every registered connection and every holder
%% the table has, and the workers of owners no longer registered
%% (`init/1`). Requests that were waiting for the dead keeper
%% see it go and are refused, each removing the row the keeper may have
%% added for it before dying; connections with a home keep taking it
%% meanwhile.
%%
%% A route a reload dropped drains: its keeper goes on serving the requests
%% it counts and any still routed by the old table, and stops in the step
%% it finds nothing running or waiting, so nothing is granted after that.
%% The listener then deletes the tables, or, when a reload brought the
%% route back meanwhile, starts a new keeper on them.
%%
%% `counts` holds the ceiling and the queue depth the listener configured
%% (both updated in place by `reload_routes/2`, so a new ceiling applies
%% to the requests already counted), the number of requests waiting, and
%% the cumulative number refused.

-export([
    new/3,
    start_link/3,
    configure/3,
    set_draining/2,
    ceiling/4,
    stats/1,
    delete_table/1,
    acquire/1,
    acquire/4,
    release/2,
    noted/1,
    worker_down/1,
    hand_over/1
]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).
-export_type([ceiling/0, table/0, token/0, wait/0]).

%% Common Test builds can stop a process at these points, so a test runs
%% what races it in between (`roadrunner_route_pause`). Other builds have
%% none, the `test` profile's own (`rebar3 as test,bench`, which measures
%% the server) included: only `rebar3 ct` defines `COMMON_TEST`.
-ifdef(COMMON_TEST).
-define(PAUSE(Point), roadrunner_route_pause:here(Point)).
-else.
-define(PAUSE(Point), ok).
-endif.

%% The `counts` cells.
-define(MAX, 1).
-define(MAX_QUEUED, 2).
-define(QUEUED, 3).
-define(THROTTLED, 4).

%% The gate's bits: requests wait for a slot, the route drains, every
%% request that ends tells the keeper its key.
-define(SLOW, 1).
-define(DRAINING, 2).
-define(REPORT, 4).
-define(CLOSED, (?SLOW bor ?DRAINING)).

%% The keys the keeper tries in turn before it scans the table.
-define(PROBES, 16).

%% A keeper idle this long hibernates, giving back the heap that a burst
%% of connections it watched grew.
-define(HIBERNATE_AFTER_MS, 1000).

%% How long after an owner died the keeper looks for its workers' intents
%% again.
-define(SWEEP_MS, 1000).

%% A route's ceiling as a request meets it, carried in the route's compiled
%% entry: the tables and counts the listener keeps for the route across
%% reloads, how a request over the ceiling waits (`shed`, or a queue
%% timeout in milliseconds), the `Retry-After` its refusal carries, and the
%% listener that reports it.
-record(ceiling, {
    slots :: ets:tid(),
    regs :: ets:tid(),
    intents :: ets:tid(),
    counts :: atomics:atomics_ref(),
    wait :: wait(),
    retry_after :: pos_integer(),
    listener :: atom()
}).

-opaque ceiling() :: #ceiling{}.
-opaque table() :: {ets:tid(), ets:tid(), ets:tid()}.
-type token() :: pos_integer().
-type wait() :: shed | pos_integer().
-type kind() :: h1 | worker.
%% The key a stream worker tells its owner it took.
-type note() :: {roadrunner_route_slot, pid(), ceiling(), token()}.
-type row() :: {token(), pid(), pid()}.

%% A request waiting for a slot.
-record(waiter, {
    pid :: pid(),
    kind :: kind(),
    monitor :: reference(),
    timer :: reference()
}).

%% A process the keeper watches: a registered connection, or a stream
%% worker holding a slot it granted or one whose owner died, with the rows
%% to free when it dies. Only a registered one has a registration to remove
%% then. An owner that handed over stays watched, so it is not registered
%% again while it lives.
-record(watched, {
    monitor :: reference(),
    registered = false :: boolean(),
    handed_over = false :: boolean(),
    rows = [] :: [row()]
}).

-record(state, {
    slots :: ets:tid(),
    regs :: ets:tid(),
    intents :: ets:tid(),
    counts :: atomics:atomics_ref(),
    %% Set once the route left the table: the keeper stops when nothing is
    %% running or waiting any more.
    draining :: boolean(),
    %% The gate as written in `regs`; only this keeper writes it.
    gate :: non_neg_integer(),
    %% Waiting tokens in arrival order. One that stopped waiting (served,
    %% expired, gone) leaves `waiters` but stays here until a pop reaches
    %% it, so a removal does not search the queue.
    order = queue:new() :: queue:queue(reference()),
    waiters = #{} :: #{reference() => #waiter{}},
    %% Every monitor this keeper holds.
    monitors = #{} :: #{reference() => {waiter, reference()} | {watched, pid()}},
    watched = #{} :: #{pid() => #watched{}},
    %% Keys heard freed, which may be free still, and the next key to try.
    spare = #{} :: #{token() => []},
    rotor = 1 :: token(),
    %% Owners that died, whose workers' intents the keeper looks for again
    %% when `sweep` fires.
    late = [] :: [pid()],
    sweep :: reference() | undefined
}).

%% --- listener side ---

%% A route's tables and counts, made in (and owned by) the listener so they
%% outlive any one keeper. The slot table keeps one count of its rows, so a
%% read of its size sees every insert and delete before it.
-spec new(pos_integer(), pos_integer(), boolean()) -> {pid(), table(), atomics:atomics_ref()}.
new(Max, MaxQueued, Draining) ->
    Slots = ets:new(roadrunner_route_slots, [
        set, public, {write_concurrency, true}, {decentralized_counters, false}
    ]),
    Regs = ets:new(roadrunner_route_regs, [
        set, public, {read_concurrency, true}, {write_concurrency, true}
    ]),
    Intents = ets:new(roadrunner_route_intents, [duplicate_bag, public, {write_concurrency, true}]),
    Counts = atomics:new(4, [{signed, false}]),
    ok = atomics:put(Counts, ?MAX, Max),
    ok = atomics:put(Counts, ?MAX_QUEUED, MaxQueued),
    {ok, Pid} = start_link({Slots, Regs, Intents}, Counts, Draining),
    {Pid, {Slots, Regs, Intents}, Counts}.

%% Start a keeper on a route's tables, linked to the caller (the listener):
%% the first, or one taking over from a keeper that died or drained.
%%
%% The keeper runs at high priority. Its queue is first in, first out, and
%% no longer than `max_queued`, only while it keeps up with its messages: at
%% normal priority, on a server busy with the very requests it counts, it
%% waits its turn behind them, the requests asking for a slot pile up unread
%% in its mailbox (a queue `max_queued` does not count), and it finds no
%% request waiting and opens the gate while they do. Connections already
%% served then take their home slots as they free, and the requests in the
%% mailbox can wait for seconds. Its work is a few messages for each
%% request that reaches it, and once its queue is full a request is refused
%% without reaching it. Its bursts of work run ahead of the connections on
%% its scheduler as well: many connections it knows closing at once cost it
%% about 1.5 us each.
-spec start_link(table(), atomics:atomics_ref(), boolean()) -> {ok, pid()}.
start_link(Table, Counts, Draining) ->
    gen_server:start_link(
        ?MODULE,
        {Table, Counts, Draining},
        [{hibernate_after, ?HIBERNATE_AFTER_MS}, {spawn_opt, [{priority, high}]}]
    ).

%% A new ceiling and queue depth, from a reload. They apply at once: the
%% ceiling to the requests already counted too, the depth to the requests
%% that ask from then on (those already waiting stay); a raised ceiling hands
%% its slots to the requests waiting. Asynchronous, so the listener never
%% waits on a keeper.
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
ceiling({Slots, Regs, Intents}, Counts, {shed, #{retry_after := RetryAfter}}, Listener) ->
    #ceiling{
        slots = Slots,
        regs = Regs,
        intents = Intents,
        counts = Counts,
        wait = shed,
        retry_after = RetryAfter,
        listener = Listener
    };
ceiling({Slots, Regs, Intents}, Counts, {queue, #{timeout := Timeout}}, Listener) ->
    #ceiling{
        slots = Slots,
        regs = Regs,
        intents = Intents,
        counts = Counts,
        wait = Timeout,
        retry_after = 1,
        listener = Listener
    }.

%% What `roadrunner_listener:info/1` reports of a route.
-spec stats({table(), atomics:atomics_ref()}) ->
    #{
        max_concurrent_requests := pos_integer(),
        in_flight := non_neg_integer(),
        queued := non_neg_integer(),
        throttled := non_neg_integer()
    }.
stats({{Slots, _Regs, _Intents}, Counts}) ->
    #{
        max_concurrent_requests => atomics:get(Counts, ?MAX),
        in_flight => ets:info(Slots, size),
        queued => atomics:get(Counts, ?QUEUED),
        throttled => atomics:get(Counts, ?THROTTLED)
    }.

%% The tables of a route whose keeper is gone for good.
-spec delete_table(table()) -> true.
delete_table({Slots, Regs, Intents}) ->
    true = ets:delete(Slots),
    true = ets:delete(Regs),
    ets:delete(Intents).

%% --- request side ---

%% Take a slot for the calling HTTP/1.1 connection, waiting in queue mode:
%% its home slot when it has one and the gate is open, else through the
%% keeper. `{refused, RetryAfter}` is counted and reported as a throttled
%% request.
-spec acquire(ceiling()) -> {ok, token()} | {refused, pos_integer()}.
acquire(#ceiling{slots = Slots} = Ceiling) ->
    case get({?MODULE, Slots}) of
        undefined ->
            ask_home(Ceiling);
        Home ->
            case take_home(Ceiling, Home) of
                taken -> {ok, Home};
                busy -> ask_home(Ceiling);
                gone -> gone(Ceiling)
            end
    end.

%% Take a slot for the calling stream worker, whose `Owner` (the process
%% that monitors it: the HTTP/2 connection, or HTTP/3's loop) frees it when
%% the worker ends: one owned by `Owner` while that owner is registered and
%% the route under half its ceiling, else through the keeper. Waiting, the
%% worker also stops on the message that says its stream was reset
%% (`{Tag, StreamId, _Why}` for `Reset` `{Tag, StreamId}`), or when its
%% connection process `Conn` goes: it returns `reset` and ends, which frees
%% a slot granted in the meantime (the keeper watches it).
-spec acquire(ceiling(), {atom(), term()}, pid(), pid()) ->
    {ok, token()} | {refused, pos_integer()} | reset.
acquire(#ceiling{} = Ceiling, Reset, Conn, Owner) ->
    case take_owned(Ceiling, Owner) of
        {taken, K} -> {ok, K};
        {busy, Rows, Max} -> ask_worker(Ceiling, Rows, Max, Reset, Conn, Owner);
        busy -> ask_worker(Ceiling, Reset, Conn, Owner);
        gone -> refuse(Ceiling)
    end.

%% A stream worker's owner keeps the key its worker took (the message the
%% worker sent it), until the worker's `'DOWN'`.
-spec noted(note()) -> ok.
noted({roadrunner_route_slot, Worker, Ceiling, K}) ->
    _ = put({?MODULE, Worker}, {Ceiling, K}),
    ok.

%% A worker of the calling owner ended: the slot it took goes, row first,
%% then its intent, so the keeper finding the intent of a worker never
%% misses its row.
-spec worker_down(pid()) -> ok.
worker_down(Worker) ->
    case erase({?MODULE, Worker}) of
        undefined ->
            ok;
        {#ceiling{slots = Slots, intents = Intents} = Ceiling, K} ->
            Self = self(),
            try
                true = ets:delete_object(Slots, {K, Self, Worker}),
                ok = ?PAUSE(owner_row_freed),
                true = ets:delete_object(Intents, {Self, Worker, K}),
                notify(Ceiling, K)
            catch
                error:badarg -> ok
            end
    end.

%% The calling owner stops answering its workers while it lives on: an
%% HTTP/2 connection lingering after its GOAWAY. It first takes the keys
%% and `'DOWN'`s already sent to it, in the order they came, freeing the
%% slot of each worker that ended. Then it tells the keeper of each route
%% in `Ceilings` (its listener's routes with a ceiling), and of each route a
%% worker still holds a key of (one a reload dropped among them), to take
%% its registration, as the owner's death would: the keeper frees each row
%% of a worker still running as the worker ends, and the owner's workers
%% take no slot of their own from now on. Two cases stay counted until the
%% owner exits, which the linger bounds: a slot a worker takes of a route a
%% reload dropped, where the owner is registered but held no key when it
%% handed over, and one a worker takes after a keeper that crashed during
%% the linger restarts, as the new keeper does not know the owner handed
%% over and registers it again when a worker asks.
-spec hand_over([ceiling()]) -> ok.
hand_over(Ceilings) ->
    ok = ?PAUSE(handing_over),
    take_sent(Ceilings).

-spec take_sent([ceiling()]) -> ok.
take_sent(Ceilings) ->
    receive
        {roadrunner_route_slot, _Worker, _Ceiling, _K} = Note ->
            ok = noted(Note),
            take_sent(Ceilings);
        {'DOWN', _Mon, process, Worker, _Reason} ->
            ok = worker_down(Worker),
            take_sent(Ceilings)
    after 0 ->
        Self = self(),
        Tables = lists:usort(
            lists:foldl(
                fun
                    ({{?MODULE, _Worker}, {#ceiling{regs = Regs}, _K}}, Acc) -> [Regs | Acc];
                    (_Entry, Acc) -> Acc
                end,
                [Regs || #ceiling{regs = Regs} <- Ceilings],
                get()
            )
        ),
        lists:foreach(fun(Regs) -> tell_keeper(Regs, Self) end, Tables)
    end.

%% A table already gone went with its listener, or with a route that
%% drained, and counts nothing any more.
-spec tell_keeper(ets:tid(), pid()) -> ok.
tell_keeper(Regs, Owner) ->
    try ets:lookup_element(Regs, '$keeper', 2) of
        Keeper ->
            _ = erlang:send(Keeper, {hand_over, Owner}),
            ok
    catch
        error:badarg -> ok
    end.

%% An HTTP/1.1 connection hands its slot back as its request ends, telling
%% the keeper while the gate says so. A table already gone went with its
%% listener, or with a route that drained, and counts nothing any more.
-spec release(ceiling(), token()) -> ok.
release(#ceiling{slots = Slots} = Ceiling, K) ->
    Self = self(),
    try
        true = ets:delete_object(Slots, {K, Self, Self}),
        ok = ?PAUSE(released),
        notify(Ceiling, K)
    catch
        error:badarg -> ok
    end.

%% The connection's home row, while the gate is open and the home is within
%% the ceiling.
-spec take_home(ceiling(), token()) -> taken | busy | gone.
take_home(#ceiling{slots = Slots, regs = Regs, counts = Counts} = Ceiling, K) ->
    Self = self(),
    try
        case open(Regs) andalso K =< atomics:get(Counts, ?MAX) of
            true ->
                ok = ?PAUSE(home_open),
                case ets:insert_new(Slots, {K, Self, Self}) of
                    true -> kept(Ceiling, K, Self);
                    false -> busy
                end;
            false ->
                busy
        end
    catch
        error:badarg -> gone
    end.

%% A row inserted without the keeper stays only while the route runs no
%% more than its ceiling and does not drain. Backing off tells the keeper
%% while the gate says so, as a release does: the row may have kept a
%% request waiting.
-spec kept(ceiling(), token(), pid()) -> taken | busy.
kept(Ceiling, K, Self) ->
    case within(Ceiling) of
        true ->
            taken;
        false ->
            true = ets:delete_object(Ceiling#ceiling.slots, {K, Self, Self}),
            ok = notify(Ceiling, K),
            busy
    end.

-spec within(ceiling()) -> boolean().
within(#ceiling{slots = Slots, regs = Regs, counts = Counts}) ->
    ets:info(Slots, size) =< atomics:get(Counts, ?MAX) andalso
        ets:lookup_element(Regs, '$keeper', 3) band ?DRAINING =:= 0.

%% A slot owned by the worker's owner, at a key picked from the worker's
%% pid. The owner hears of it first, as its `'DOWN'` of the worker comes
%% after anything the worker sent; then the intent goes in, then the
%% owner's registration is checked again, then the row. A route at half its
%% ceiling or more goes to the keeper: a key picked at random is likely
%% taken there, and the try wasted. That is looked at first, as it costs a
%% request that goes to the keeper anyway the least, and the request asks
%% with the size and ceiling it read.
-spec take_owned(ceiling(), pid()) ->
    {taken, token()} | {busy, non_neg_integer() | undefined, pos_integer()} | busy | gone.
take_owned(#ceiling{slots = Slots, regs = Regs, counts = Counts} = Ceiling, Owner) ->
    Max = atomics:get(Counts, ?MAX),
    case ets:info(Slots, size) of
        Rows when Rows < (Max + 1) div 2 ->
            try
                case open(Regs) andalso ets:member(Regs, Owner) of
                    true -> take_owned(Ceiling, Owner, erlang:phash2(self(), Max) + 1);
                    false -> busy
                end
            catch
                error:badarg -> gone
            end;
        Rows ->
            {busy, Rows, Max}
    end.

-spec take_owned(ceiling(), pid(), token()) -> {taken, token()} | busy.
take_owned(#ceiling{slots = Slots, regs = Regs, intents = Intents} = Ceiling, Owner, K) ->
    Self = self(),
    _ = erlang:send(Owner, {roadrunner_route_slot, Self, Ceiling, K}),
    ok = ?PAUSE(worker_noted),
    true = ets:insert(Intents, {Owner, Self, K}),
    ok = ?PAUSE(worker_intent),
    case ets:member(Regs, Owner) of
        true ->
            ok = ?PAUSE(worker_checked),
            case ets:insert_new(Slots, {K, Owner, Self}) of
                true ->
                    ok = ?PAUSE(worker_inserted),
                    case within(Ceiling) of
                        true ->
                            {taken, K};
                        false ->
                            true = ets:delete_object(Slots, {K, Owner, Self}),
                            true = ets:delete_object(Intents, {Owner, Self, K}),
                            ok = notify(Ceiling, K),
                            busy
                    end;
                false ->
                    true = ets:delete_object(Intents, {Owner, Self, K}),
                    busy
            end;
        false ->
            true = ets:delete_object(Intents, {Owner, Self, K}),
            busy
    end.

%% Whether a request may take its slot without the keeper.
-spec open(ets:tid()) -> boolean().
open(Regs) ->
    ets:lookup_element(Regs, '$keeper', 3) band ?CLOSED =:= 0.

%% The keeper hears of a freed slot while its gate says so.
-spec notify(ceiling(), token()) -> ok.
notify(#ceiling{regs = Regs}, K) ->
    case ets:lookup(Regs, '$keeper') of
        [{'$keeper', _Keeper, 0}] ->
            ok;
        [{'$keeper', Keeper, _Gate}] ->
            _ = erlang:send(Keeper, {done, K}),
            ok
    end.

%% A stream worker asks the keeper, which registers its owner.
-spec ask_worker(ceiling(), {atom(), term()}, pid(), pid()) ->
    {ok, token()} | {refused, pos_integer()} | reset.
ask_worker(#ceiling{slots = Slots, counts = Counts} = Ceiling, Reset, Conn, Owner) ->
    ask_worker(
        Ceiling, ets:info(Slots, size), atomics:get(Counts, ?MAX), Reset, Conn, Owner
    ).

-spec ask_worker(
    ceiling(), non_neg_integer() | undefined, pos_integer(), {atom(), term()}, pid(), pid()
) ->
    {ok, token()} | {refused, pos_integer()} | reset.
ask_worker(Ceiling, Rows, Max, {ResetTag, ResetId}, Conn, Owner) ->
    case ask(Ceiling, {worker, Owner}, Rows, Max) of
        {asked, Token} ->
            ConnMon = erlang:monitor(process, Conn),
            Result =
                receive
                    {Token, {granted, K}} ->
                        {ok, K};
                    {Token, refused} ->
                        refuse(Ceiling);
                    {'DOWN', Token, process, _Keeper, _Reason} ->
                        keeper_gone(Ceiling);
                    {ResetTag, ResetId, _Why} ->
                        true = erlang:demonitor(Token, [flush]),
                        reset;
                    {'DOWN', ConnMon, process, Conn, _Reason} ->
                        true = erlang:demonitor(Token, [flush]),
                        reset
                end,
            true = erlang:demonitor(ConnMon, [flush]),
            Result;
        _FullOrGone ->
            refuse(Ceiling)
    end.

%% An HTTP/1.1 connection asks the keeper, which makes the key it grants the
%% connection's home.
-spec ask_home(ceiling()) -> {ok, token()} | {refused, pos_integer()}.
ask_home(#ceiling{slots = Slots, counts = Counts} = Ceiling) ->
    case ask(Ceiling, h1, ets:info(Slots, size), atomics:get(Counts, ?MAX)) of
        {asked, Token} ->
            receive
                {Token, {granted, K}} ->
                    _ = put({?MODULE, Slots}, K),
                    {ok, K};
                {Token, refused} ->
                    refuse(Ceiling);
                {'DOWN', Token, process, _Keeper, _Reason} ->
                    keeper_gone(Ceiling)
            end;
        full ->
            refuse(Ceiling);
        gone ->
            gone(Ceiling)
    end.

%% Ask the keeper for a slot, unless the route, with `Rows` running against
%% its ceiling `Max`, is full and the request would not wait for one. The
%% ask carries a monitor of the keeper that is also the alias its answer
%% comes on.
-spec ask(ceiling(), h1 | {worker, pid()}, non_neg_integer() | undefined, pos_integer()) ->
    {asked, reference()} | full | gone.
ask(#ceiling{regs = Regs, counts = Counts, wait = Wait}, Kind, Rows, Max) ->
    case Rows of
        undefined ->
            gone;
        Rows ->
            case full(Rows, Max, Counts, Wait) of
                true ->
                    full;
                false ->
                    try ets:lookup_element(Regs, '$keeper', 2) of
                        Keeper ->
                            Token = erlang:monitor(process, Keeper, [{alias, reply_demonitor}]),
                            _ = erlang:send(Keeper, {acquire, Token, self(), Kind, Wait}),
                            {asked, Token}
                    catch
                        error:badarg -> gone
                    end
            end
    end.

%% Whether a request would be turned away without asking: the route runs
%% its ceiling and, for a queue, its queue is full too.
-spec full(non_neg_integer(), pos_integer(), atomics:atomics_ref(), wait()) -> boolean().
full(Rows, Max, _Counts, shed) ->
    Rows >= Max;
full(Rows, Max, Counts, _Timeout) ->
    Rows >= Max andalso atomics:get(Counts, ?QUEUED) >= atomics:get(Counts, ?MAX_QUEUED).

%% The keeper died before it answered. It may have added the caller's row
%% first, and a caller asking holds no other row of the route, so every row
%% the caller holds goes, or the slot would stay taken by a request that
%% never ran; the keeper serving the table now hears of it. It may also
%% have made that row's key a connection's home: the connection forgets
%% its own, so its next request asks the keeper and the two agree again
%% (the keeper frees only the home it knows when the connection dies).
-spec keeper_gone(ceiling()) -> {refused, pos_integer()}.
keeper_gone(#ceiling{slots = Slots} = Ceiling) ->
    Self = self(),
    _ = erase({?MODULE, Slots}),
    try
        lists:foreach(
            fun({K, _, _} = Row) ->
                true = ets:delete_object(Slots, Row),
                ok = notify(Ceiling, K)
            end,
            ets:match_object(Slots, {'_', Self, Self})
        )
    catch
        error:badarg -> ok
    end,
    refuse(Ceiling).

%% The route's tables are gone: the connection forgets its home there.
-spec gone(ceiling()) -> {refused, pos_integer()}.
gone(#ceiling{slots = Slots} = Ceiling) ->
    _ = erase({?MODULE, Slots}),
    refuse(Ceiling).

-spec refuse(ceiling()) -> {refused, pos_integer()}.
refuse(#ceiling{counts = Counts, retry_after = RetryAfter, listener = Listener}) ->
    ok = atomics:add(Counts, ?THROTTLED, 1),
    ok = roadrunner_event:request_throttled(Listener, route_max_concurrent_requests),
    {refused, RetryAfter}.

%% --- keeper ---

-spec init({table(), atomics:atomics_ref(), boolean()}) ->
    {ok, #state{}} | {ok, #state{}, {continue, drained}}.
init({{Slots, Regs, Intents}, Counts, Draining}) ->
    Gate = draining(Draining),
    %% Published first: a request asking from now on reaches this keeper.
    true = ets:insert(Regs, {'$keeper', self(), Gate}),
    %% Whatever waited for a keeper before this one was refused when it went.
    ok = atomics:put(Counts, ?QUEUED, 0),
    State0 = #state{
        slots = Slots,
        regs = Regs,
        intents = Intents,
        counts = Counts,
        draining = Draining,
        gate = Gate
    },
    %% Every registered connection is watched again, every worker of an
    %% owner no longer registered (whose keeper died taking it), and every
    %% other holder with its row.
    State1 = ets:foldl(fun watch_registered/2, State0, Regs),
    State2 = ets:foldl(fun adopt_orphan/2, State1, Intents),
    State = ets:foldl(fun take_over_row/2, State2, Slots),
    case Draining of
        %% Taking over a route already dropped: it may have drained.
        true -> {ok, State, {continue, drained}};
        false -> {ok, State}
    end.

-spec watch_registered(tuple(), #state{}) -> #state{}.
watch_registered({'$keeper', _Keeper, _Gate}, State) ->
    State;
watch_registered({Conn, _Home}, State) ->
    registered(Conn, undefined, State).

%% An intent whose owner is not registered: the owner died, and the keeper
%% that took its registration died before it watched every worker.
-spec adopt_orphan({pid(), pid(), token()}, #state{}) -> #state{}.
adopt_orphan({Owner, Worker, K}, #state{regs = Regs} = State) ->
    case ets:member(Regs, Owner) of
        true -> State;
        false -> hold_row(Worker, {K, Owner, Worker}, undefined, State)
    end.

%% A row found at a takeover. A registered connection's row at its home is
%% its own. At any other key it is a grant the connection never received,
%% as the old keeper died before answering: the connection removes it when
%% it sees that keeper gone, and the keeper frees it should the connection
%% die first. A worker's row owned by another process is that owner's, or
%% the keeper's through its intent. Any other holder is watched with its
%% row.
-spec take_over_row(row(), #state{}) -> #state{}.
take_over_row({K, Pid, Pid} = Row, #state{regs = Regs} = State) ->
    case ets:lookup(Regs, Pid) of
        [{Pid, K}] -> State;
        _NotItsHome -> hold_row(Pid, Row, undefined, State)
    end;
take_over_row({_K, _Owner, _Worker}, State) ->
    State.

-spec handle_continue(drained, #state{}) ->
    {noreply, #state{}} | {stop, {shutdown, drained}, #state{}}.
handle_continue(drained, State) ->
    noreply(State).

-spec handle_call(term(), gen_server:from(), #state{}) -> {reply, {error, unknown_call}, #state{}}.
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, {shutdown, drained}, #state{}}.
handle_info({acquire, Token, Pid, h1, Wait}, State) ->
    %% The requests already waiting go first.
    noreply(admit(Token, Pid, h1, Wait, serve(State)));
handle_info({acquire, Token, Pid, {worker, Owner}, Wait}, State) ->
    noreply(admit(Token, Pid, worker, Wait, serve(register_owner(Owner, State))));
handle_info({hand_over, Owner}, State) ->
    noreply(handed_over(Owner, State));
handle_info({done, K}, State) ->
    noreply(serve(spare(K, State)));
handle_info({expire, Token}, #state{waiters = Waiters} = State) ->
    case Waiters of
        #{Token := #waiter{monitor = Mon}} ->
            _ = erlang:send(Token, {Token, refused}),
            true = erlang:demonitor(Mon, [flush]),
            noreply(forget_waiter(Token, Mon, State));
        #{} ->
            {noreply, State}
    end;
handle_info({'DOWN', Mon, process, Pid, _Reason}, #state{monitors = Monitors} = State) ->
    case Monitors of
        #{Mon := {watched, Pid}} ->
            noreply(serve(watched_down(Pid, Mon, State)));
        #{Mon := {waiter, Token}} ->
            #{Token := #waiter{timer = Timer}} = State#state.waiters,
            _ = erlang:cancel_timer(Timer),
            noreply(forget_waiter(Token, Mon, State));
        #{} ->
            {noreply, State}
    end;
handle_info(serve, State) ->
    noreply(serve(State));
handle_info(sweep, #state{late = Late} = State) ->
    noreply(lists:foldl(fun sweep/2, State#state{late = [], sweep = undefined}, Late));
handle_info({draining, Draining}, #state{gate = Gate} = State) ->
    noreply(
        set_gate(Gate band bnot ?DRAINING bor draining(Draining), State#state{draining = Draining})
    );
handle_info(_Msg, State) ->
    {noreply, State}.

-spec draining(boolean()) -> 0 | ?DRAINING.
draining(true) -> ?DRAINING;
draining(false) -> 0.

%% A request asking, once those waiting were served: granted while there
%% is room, else refused, or parked in queue mode while the queue has room.
-spec admit(reference(), pid(), kind(), wait(), #state{}) -> #state{}.
admit(Token, Pid, Kind, Wait, #state{waiters = Waiters} = State) when map_size(Waiters) =:= 0 ->
    case grant(Token, Pid, Kind, undefined, State) of
        {granted, State1} -> State1;
        {no_room, State1} -> no_room(Token, Pid, Kind, Wait, State1)
    end;
admit(Token, Pid, Kind, Wait, State) ->
    no_room(Token, Pid, Kind, Wait, State).

-spec no_room(reference(), pid(), kind(), wait(), #state{}) -> #state{}.
no_room(Token, _Pid, _Kind, shed, State) ->
    _ = erlang:send(Token, {Token, refused}),
    State;
no_room(Token, Pid, Kind, Timeout, #state{counts = Counts} = State) ->
    case atomics:get(Counts, ?QUEUED) < atomics:get(Counts, ?MAX_QUEUED) of
        true ->
            ok = ?PAUSE(full),
            %% The gate closes before the last look for room: a request
            %% that ends from now on tells the keeper, and one that ended
            %% before freed its slot ahead of this look.
            case last_look(Token, Pid, Kind, close(State)) of
                {granted, State1} ->
                    State1;
                {no_room, State1} ->
                    ok = ?PAUSE(parking),
                    park(Token, Pid, Kind, Timeout, State1)
            end;
        false ->
            _ = erlang:send(Token, {Token, refused}),
            State
    end.

-spec last_look(reference(), pid(), kind(), #state{}) ->
    {granted, #state{}} | {no_room, #state{}}.
last_look(Token, Pid, Kind, #state{waiters = Waiters} = State) when map_size(Waiters) =:= 0 ->
    grant(Token, Pid, Kind, undefined, State);
last_look(_Token, _Pid, _Kind, State) ->
    {no_room, State}.

-spec park(reference(), pid(), kind(), pos_integer(), #state{}) -> #state{}.
park(Token, Pid, Kind, Timeout, #state{counts = Counts} = State) ->
    #state{order = Order, waiters = Waiters, monitors = Monitors} = State,
    Mon = erlang:monitor(process, Pid),
    Waiter = #waiter{
        pid = Pid,
        kind = Kind,
        monitor = Mon,
        timer = erlang:send_after(Timeout, self(), {expire, Token})
    },
    ok = atomics:add(Counts, ?QUEUED, 1),
    State#state{
        order = queue:in(Token, Order),
        waiters = Waiters#{Token => Waiter},
        monitors = Monitors#{Mon => {waiter, Token}}
    }.

%% Hand free slots to the waiting requests, oldest first.
-spec serve(#state{}) -> #state{}.
serve(#state{order = Order, waiters = Waiters} = State) ->
    case queue:out(Order) of
        {empty, _} ->
            State;
        {{value, Token}, Rest} ->
            case Waiters of
                #{Token := #waiter{pid = Pid, kind = Kind, monitor = Mon, timer = Timer}} ->
                    case grant(Token, Pid, Kind, Mon, State) of
                        {granted, #state{counts = Counts, waiters = Waiters1} = State1} ->
                            _ = erlang:cancel_timer(Timer),
                            ok = atomics:sub(Counts, ?QUEUED, 1),
                            serve(State1#state{
                                order = Rest, waiters = maps:remove(Token, Waiters1)
                            });
                        {no_room, State1} ->
                            State1
                    end;
                #{} ->
                    serve(State#state{order = Rest})
            end
    end.

%% Give `Pid` a free key. Its row goes in before the answer goes out: a
%% keeper killed between the two leaves a row the caller removes when it
%% sees the keeper go, never a running request without one. The row stays
%% only while the route runs no more than its ceiling, which requests that
%% took their slot without the keeper can fill after a reload lowered it.
%% `Mon` is the monitor of a waiter served, which watches it from now on.
-spec grant(reference(), pid(), kind(), reference() | undefined, #state{}) ->
    {granted, #state{}} | {no_room, #state{}}.
grant(Token, Pid, Kind, Mon, #state{slots = Slots, counts = Counts} = State) ->
    Max = atomics:get(Counts, ?MAX),
    case ets:info(Slots, size) < Max of
        true ->
            ok = ?PAUSE(granting),
            case claim(Pid, Max, State) of
                {ok, K, State1} ->
                    case ets:info(Slots, size) =< Max of
                        true ->
                            State2 = hold(Kind, Pid, K, Mon, State1),
                            ok = ?PAUSE(held),
                            _ = erlang:send(Token, {Token, {granted, K}}),
                            {granted, State2};
                        false ->
                            true = ets:delete_object(Slots, {K, Pid, Pid}),
                            {no_room, spare(K, State1)}
                    end;
                {none, State1} ->
                    {no_room, State1}
            end;
        false ->
            {no_room, State}
    end.

%% An HTTP/1.1 connection is watched, then registered with the key as its
%% home, so every registration is watched. A stream worker is watched with
%% its row.
-spec hold(kind(), pid(), token(), reference() | undefined, #state{}) -> #state{}.
hold(h1, Conn, K, Mon, #state{regs = Regs} = State) ->
    State1 = registered(Conn, Mon, State),
    true = ets:insert(Regs, {Conn, K}),
    State1;
hold(worker, Pid, K, Mon, State) ->
    hold_row(Pid, {K, Pid, Pid}, Mon, State).

%% The owner of a stream worker asking: watched, then registered, once, so
%% every registration is watched and its workers take their slots from now
%% on.
-spec register_owner(pid(), #state{}) -> #state{}.
register_owner(Owner, #state{watched = Watched, regs = Regs} = State) ->
    case Watched of
        #{Owner := #watched{registered = true}} ->
            State;
        #{Owner := #watched{handed_over = true}} ->
            State;
        #{} ->
            State1 = registered(Owner, undefined, State),
            true = ets:insert_new(Regs, {Owner, none}),
            State1
    end.

%% Watch `Pid` from now on, once. A waiter's monitor is the one kept when
%% the process is not watched yet, and dropped when it is.
-spec watch(pid(), reference() | undefined, #state{}) -> #state{}.
watch(Pid, Mon, #state{watched = Watched} = State) when is_map_key(Pid, Watched) ->
    drop_monitor(Mon, State);
watch(Pid, Mon, #state{watched = Watched, monitors = Monitors} = State) ->
    Mon1 = monitor_once(Pid, Mon),
    State#state{
        watched = Watched#{Pid => #watched{monitor = Mon1}},
        monitors = Monitors#{Mon1 => {watched, Pid}}
    }.

%% Watch `Pid`, which has a registration from now on.
-spec registered(pid(), reference() | undefined, #state{}) -> #state{}.
registered(Pid, Mon, State) ->
    #state{watched = Watched} = State1 = watch(Pid, Mon, State),
    #{Pid := W} = Watched,
    State1#state{watched = Watched#{Pid := W#watched{registered = true}}}.

%% Watch `Pid` with a row to free when it dies.
-spec hold_row(pid(), row(), reference() | undefined, #state{}) -> #state{}.
hold_row(Pid, Row, Mon, #state{watched = Watched, monitors = Monitors} = State) ->
    case Watched of
        #{Pid := #watched{rows = Rows} = W} ->
            State1 = State#state{watched = Watched#{Pid := W#watched{rows = [Row | Rows]}}},
            drop_monitor(Mon, State1);
        #{} ->
            Mon1 = monitor_once(Pid, Mon),
            State#state{
                watched = Watched#{Pid => #watched{monitor = Mon1, rows = [Row]}},
                monitors = Monitors#{Mon1 => {watched, Pid}}
            }
    end.

-spec monitor_once(pid(), reference() | undefined) -> reference().
monitor_once(Pid, undefined) ->
    erlang:monitor(process, Pid);
monitor_once(_Pid, Mon) ->
    Mon.

-spec drop_monitor(reference() | undefined, #state{}) -> #state{}.
drop_monitor(undefined, State) ->
    State;
drop_monitor(Mon, #state{monitors = Monitors} = State) ->
    true = erlang:demonitor(Mon, [flush]),
    State#state{monitors = maps:remove(Mon, Monitors)}.

%% A watched process died. A registered one's registration goes first, so
%% none of its workers takes a slot from now on; then the keeper watches
%% every worker it has an intent of, and frees the home row it may hold
%% and every row it held.
-spec watched_down(pid(), reference(), #state{}) -> #state{}.
watched_down(Pid, Mon, #state{regs = Regs, watched = Watched, monitors = Monitors} = State) ->
    #{Pid := #watched{registered = Registered, rows = Rows}} = Watched,
    State1 = State#state{
        watched = maps:remove(Pid, Watched), monitors = maps:remove(Mon, Monitors)
    },
    case Registered of
        true ->
            [{Pid, Home}] = ets:take(Regs, Pid),
            ok = ?PAUSE(owner_taken),
            free_rows(home(Home, Pid, Rows), sweep_later(Pid, adopt(Pid, State1)));
        false ->
            free_rows(Rows, State1)
    end.

%% A live owner handed over. It is watched from now on, registered or not,
%% so a worker of it asking is not taken for a new owner. A registration it
%% has is taken as its death takes it, then the keeper watches every worker
%% it has an intent of.
-spec handed_over(pid(), #state{}) -> #state{}.
handed_over(Owner, #state{regs = Regs} = State0) ->
    #state{watched = Watched} = State = watch(Owner, undefined, State0),
    #{Owner := #watched{registered = Registered} = W} = Watched,
    State1 = State#state{
        watched = Watched#{Owner := W#watched{registered = false, handed_over = true}}
    },
    case Registered of
        true ->
            [{Owner, none}] = ets:take(Regs, Owner),
            sweep_later(Owner, adopt(Owner, State1));
        false ->
            State1
    end.

-spec home(token() | none, pid(), [row()]) -> [row()].
home(none, _Pid, Rows) ->
    Rows;
home(K, Pid, Rows) ->
    [{K, Pid, Pid} | Rows].

%% Watch every worker `Owner` has an intent of, freeing its row when it
%% ends.
-spec adopt(pid(), #state{}) -> #state{}.
adopt(Owner, #state{intents = Intents} = State) ->
    lists:foldl(
        fun({_Owner, Worker, K}, Acc) -> hold_row(Worker, {K, Owner, Worker}, undefined, Acc) end,
        State,
        ets:lookup(Intents, Owner)
    ).

%% A worker can write its intent after the keeper looked for them, if it
%% read the owner registered before then; it then finds the registration
%% gone and takes its intent back, unless it dies first. The keeper looks
%% again a little later and removes the intents of workers it does not
%% watch, which hold no row.
-spec sweep_later(pid(), #state{}) -> #state{}.
sweep_later(Owner, #state{late = Late, sweep = undefined} = State) ->
    State#state{late = [Owner | Late], sweep = erlang:send_after(?SWEEP_MS, self(), sweep)};
sweep_later(Owner, #state{late = Late} = State) ->
    State#state{late = [Owner | Late]}.

-spec sweep(pid(), #state{}) -> #state{}.
sweep(Owner, #state{regs = Regs, intents = Intents, watched = Watched} = State) ->
    %% An owner registered again (a dead one, until the keeper sees it die
    %% once more) may have workers holding rows from then on, which only
    %% their intents lead the keeper to: its next death looks for them.
    case ets:member(Regs, Owner) of
        true ->
            State;
        false ->
            lists:foreach(
                fun({_Owner, Worker, K} = Intent) ->
                    adopted(Worker, {K, Owner, Worker}, Watched) orelse
                        ets:delete_object(Intents, Intent)
                end,
                ets:lookup(Intents, Owner)
            ),
            State
    end.

-spec adopted(pid(), row(), #{pid() => #watched{}}) -> boolean().
adopted(Worker, Row, Watched) ->
    case Watched of
        #{Worker := #watched{rows = Rows}} -> lists:member(Row, Rows);
        #{} -> false
    end.

%% Free each row, and the intent of one a worker took for its owner.
-spec free_rows([row()], #state{}) -> #state{}.
free_rows([], State) ->
    State;
free_rows([{_K, Pid, Pid} = Row | Rows], State) ->
    free_rows(Rows, free_row(Row, State));
free_rows([{K, Owner, Worker} = Row | Rows], #state{intents = Intents} = State) ->
    State1 = free_row(Row, State),
    true = ets:delete_object(Intents, {Owner, Worker, K}),
    free_rows(Rows, State1).

%% A row goes, and its key is kept for the grants to come only when the row
%% was there: a connection that died idle held none, and its home may be
%% another request's by then. Only its holder, its owner and the keeper
%% remove a row, and the keeper frees one only once the holder and any
%% other owner are dead, so the row read is still there for the delete.
-spec free_row(row(), #state{}) -> #state{}.
free_row({K, _Owner, _Holder} = Row, #state{slots = Slots} = State) ->
    case ets:lookup(Slots, K) of
        [Row] ->
            true = ets:delete_object(Slots, Row),
            spare(K, State);
        _Other ->
            State
    end.

%% A key heard freed, kept for the grants to come. There are no more of
%% them than the largest ceiling the route had.
-spec spare(token(), #state{}) -> #state{}.
spare(K, #state{spare = Spare} = State) ->
    State#state{spare = Spare#{K => []}}.

%% A free key for `Pid`, its row inserted: one heard freed, else the next
%% few in turn, else one a scan of the table finds.
-spec claim(pid(), pos_integer(), #state{}) ->
    {ok, token(), #state{}} | {none, #state{}}.
claim(Pid, Max, #state{slots = Slots, spare = Spare, rotor = Rotor} = State) ->
    case claim_spare(Slots, Pid, Max, Spare) of
        {ok, K, Spare1} ->
            {ok, K, State#state{spare = Spare1}};
        {none, Spare1} ->
            case probe(Slots, Pid, Max, min(Rotor, Max), min(Max, ?PROBES)) of
                {ok, K} ->
                    {ok, K, State#state{spare = Spare1, rotor = K rem Max + 1}};
                {none, Next} when Max =< ?PROBES ->
                    {none, State#state{spare = Spare1, rotor = Next}};
                {none, Next} ->
                    scan(Pid, Max, State#state{spare = Spare1, rotor = Next})
            end
    end.

-spec claim_spare(ets:tid(), pid(), pos_integer(), #{token() => []}) ->
    {ok, token(), #{token() => []}} | {none, #{token() => []}}.
claim_spare(Slots, Pid, Max, Spare) ->
    case maps:next(maps:iterator(Spare)) of
        none ->
            {none, Spare};
        {K, [], _Iterator} ->
            Rest = maps:remove(K, Spare),
            case K =< Max andalso ets:insert_new(Slots, {K, Pid, Pid}) of
                true -> {ok, K, Rest};
                false -> claim_spare(Slots, Pid, Max, Rest)
            end
    end.

-spec probe(ets:tid(), pid(), pos_integer(), token(), non_neg_integer()) ->
    {ok, token()} | {none, token()}.
probe(_Slots, _Pid, _Max, K, 0) ->
    {none, K};
probe(Slots, Pid, Max, K, Left) ->
    case ets:insert_new(Slots, {K, Pid, Pid}) of
        true -> {ok, K};
        false -> probe(Slots, Pid, Max, K rem Max + 1, Left - 1)
    end.

%% The free keys, from the taken ones, kept for the grants to come. A route
%% at least half full has every request that ends tell the keeper its key
%% from before the scan, so the keys kept stay complete.
-spec scan(pid(), pos_integer(), #state{}) -> {ok, token(), #state{}} | {none, #state{}}.
scan(Pid, Max, #state{slots = Slots} = State0) ->
    State =
        case ets:info(Slots, size) * 2 >= Max of
            true -> report(State0);
            false -> State0
        end,
    Taken = ets:select(Slots, [{{'$1', '_', '_'}, [], ['$1']}]),
    case claim_spare(Slots, Pid, Max, maps:from_keys(lists:seq(1, Max) -- Taken, [])) of
        {ok, K, Spare} -> {ok, K, State#state{spare = Spare}};
        {none, Spare} -> {none, State#state{spare = Spare}}
    end.

%% --- the gate ---

%% Requests wait, or may: the fast paths go to the keeper.
-spec close(#state{}) -> #state{}.
close(#state{gate = Gate} = State) when Gate band ?SLOW =/= 0 ->
    State;
close(#state{gate = Gate} = State) ->
    set_gate(Gate bor ?SLOW, State).

-spec report(#state{}) -> #state{}.
report(#state{gate = Gate} = State) ->
    set_gate(Gate bor ?REPORT, State).

-spec set_gate(non_neg_integer(), #state{}) -> #state{}.
set_gate(Gate, #state{regs = Regs} = State) ->
    true = ets:update_element(Regs, '$keeper', {3, Gate}),
    State#state{gate = Gate}.

%% The gate opens once nothing waits, and requests stop reporting their
%% keys once the route is back under a quarter of its ceiling.
-spec open_gate(#state{}) -> #state{}.
open_gate(#state{gate = Gate, waiters = Waiters} = State) when
    Gate band ?SLOW =/= 0, map_size(Waiters) =:= 0
->
    open_gate(set_gate(Gate band bnot ?SLOW, State));
open_gate(#state{gate = Gate, slots = Slots, counts = Counts} = State) when
    Gate band ?REPORT =/= 0
->
    case ets:info(Slots, size) * 4 < atomics:get(Counts, ?MAX) of
        true -> set_gate(Gate band bnot ?REPORT, State);
        false -> State
    end;
open_gate(State) ->
    State.

%% A request stops waiting: expired or gone. Its token stays in `order`
%% until a pop reaches it.
-spec forget_waiter(reference(), reference(), #state{}) -> #state{}.
forget_waiter(Token, Mon, #state{waiters = Waiters, monitors = Monitors, counts = Counts} = State) ->
    ok = atomics:sub(Counts, ?QUEUED, 1),
    State#state{waiters = maps:remove(Token, Waiters), monitors = maps:remove(Mon, Monitors)}.

%% The end of every step: the gate opens when it may, and a draining keeper
%% with nothing running or waiting stops, in the same step it finds so: no
%% request is let in after that. The listener deletes the tables on its
%% exit (`{shutdown, drained}`), or starts a new keeper on them when a
%% reload brought the route back meanwhile. A request still asking sees the
%% keeper go and is refused.
-spec noreply(#state{}) -> {noreply, #state{}} | {stop, {shutdown, drained}, #state{}}.
noreply(State0) ->
    case open_gate(State0) of
        #state{draining = true, slots = Slots, waiters = Waiters} = State when
            map_size(Waiters) =:= 0
        ->
            case ets:info(Slots, size) of
                0 -> {stop, {shutdown, drained}, State};
                _Busy -> {noreply, State}
            end;
        State ->
            {noreply, State}
    end.
