-module(roadrunner_slot_outlives_conn_SUITE).
-moduledoc """
`max_concurrent_requests` counts a handler from dispatch until its process
ends, whatever happens to its connection. HTTP/2 and HTTP/3 handlers run in
stream workers the connection monitors but does not link, so they can
outlive it: the client drops the connection, or a drain ends it. A closing
connection hands their slots to the listener's slot keeper, which releases
each one when its worker ends. A client that fills the ceiling with slow
handlers, drops the connection and reconnects is refused (or queued) until
those handlers end, and every slot is released exactly once.

A connection that dies without its exit path (killed, or crashed) has the
slots it held reclaimed from its own cell: by the slot keeper when it had a
request parked, else by the listener's reaper (`slot_reconciliation`),
whose tick the tests send directly.

The handlers announce themselves to the test process and wait for
`release`, so the test decides when each one ends.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-behaviour(ct_suite).

-export([suite/0, all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    refused_until_the_old_handlers_end/1,
    queued_until_the_old_handler_ends/1,
    parked_request_of_a_closed_conn_is_dropped/1,
    grant_racing_the_close_is_given_back/1,
    killed_conn_is_reclaimed/1,
    killed_parked_conn_is_reclaimed_by_the_keeper/1,
    grant_racing_a_crash_is_reclaimed/1,
    grant_to_a_reaped_conn_is_reclaimed/1,
    reclaimed_slots_are_all_granted/1,
    drained_conn_keeps_its_reset_handler_counted/1,
    conn_closing_after_its_listener_stopped_exits_cleanly/1,
    parked_request_of_a_stopped_listener_is_refused/1,
    parked_request_of_an_ungraceful_drain_is_refused/1,
    never_parked_conn_after_its_listener_stopped_admits_afresh/1,
    hand_off_after_the_keeper_stopped_is_released/1,
    adopted_slots_are_released_as_the_keeper_stops/1,
    unread_hand_off_is_released_as_the_keeper_stops/1,
    listener_goes_down_with_its_keeper/1,
    dead_parked_conn_is_reclaimed_as_the_keeper_stops/1,
    http3_slots_are_released_as_the_listener_stops/1,
    http3_slots_are_released_beside_a_surviving_http2_conn/1,
    http3_listener_without_a_drain_registry_stops/1
]).

-define(H3_REQUEST_REJECTED, 16#10B).
-define(COLLECTOR, roadrunner_h2_slot_collector).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [{group, h1}, {group, h2}, {group, h3}].

groups() ->
    Common = [
        refused_until_the_old_handlers_end,
        queued_until_the_old_handler_ends,
        parked_request_of_a_closed_conn_is_dropped,
        drained_conn_keeps_its_reset_handler_counted,
        killed_conn_is_reclaimed
    ],
    %% HTTP/3 has no case of a connection outliving its listener: stopping
    %% the listener stops its QUIC connections, and with them the linked
    %% request loops.
    [
        {h2, [],
            Common ++
                [
                    grant_racing_the_close_is_given_back,
                    killed_parked_conn_is_reclaimed_by_the_keeper,
                    grant_racing_a_crash_is_reclaimed,
                    grant_to_a_reaped_conn_is_reclaimed,
                    reclaimed_slots_are_all_granted,
                    conn_closing_after_its_listener_stopped_exits_cleanly,
                    parked_request_of_a_stopped_listener_is_refused,
                    parked_request_of_an_ungraceful_drain_is_refused,
                    never_parked_conn_after_its_listener_stopped_admits_afresh,
                    hand_off_after_the_keeper_stopped_is_released,
                    adopted_slots_are_released_as_the_keeper_stops,
                    unread_hand_off_is_released_as_the_keeper_stops,
                    listener_goes_down_with_its_keeper,
                    dead_parked_conn_is_reclaimed_as_the_keeper_stops
                ]},
        {h3, [],
            Common ++
                [
                    http3_slots_are_released_as_the_listener_stops,
                    http3_slots_are_released_beside_a_surviving_http2_conn,
                    http3_listener_without_a_drain_registry_stops
                ]},
        %% HTTP/1.1 counts a request against the ceiling in shed mode only,
        %% its handler running in the connection process itself.
        {h1, [], [killed_conn_is_reclaimed]}
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(ssl),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    true = register(?COLLECTOR, self()),
    Protocol = protocol(Config),
    [
        {protocol, Protocol},
        {listener, list_to_atom(atom_to_list(Protocol) ++ "_" ++ atom_to_list(Case))}
        | Config
    ].

end_per_testcase(_Case, Config) ->
    true = unregister(?COLLECTOR),
    ok = roadrunner_h2_slot_handler:stop_all(),
    %% A case may have stopped its listener already.
    case whereis(?config(listener, Config)) of
        undefined -> ok;
        _ -> roadrunner_listener:stop(?config(listener, Config))
    end.

protocol(Config) ->
    case ?config(tc_group_properties, Config) of
        undefined -> h2;
        Props -> proplists:get_value(name, Props)
    end.

%% =============================================================================
%% Cases
%% =============================================================================

refused_until_the_old_handlers_end(Config) ->
    Name = start(Config, 2, refuse),
    Old = connect(Config),
    ok = request(Old),
    ok = request(Old),
    First = expect_handler(),
    Second = expect_handler(),
    ok = close_and_wait(Name, Old),
    %% The connection is gone, its handlers are not: both slots still count,
    %% so a new connection is refused.
    ?assertEqual(2, inflight(Name)),
    New = connect(Config),
    ?assertEqual(refused, request_outcome(New)),
    %% A handler ending normally frees its slot.
    ok = finish(First, release),
    ok = await_inflight(Name, 1),
    ok = request(New),
    Served = expect_handler(),
    ServedMon = monitor(process, Served),
    Served ! release,
    ?assertEqual(ok, await_ok(New)),
    ok = await_down(ServedMon),
    %% So does one that is killed.
    ok = finish(Second, kill),
    ok = await_inflight(Name, 0),
    ok = close_and_wait(Name, New),
    ?assertEqual(0, inflight(Name)).

queued_until_the_old_handler_ends(Config) ->
    Name = start(Config, 1, {queue, #{max_queued => 4, timeout => 10000}}),
    Old = connect(Config),
    ok = request(Old),
    Handler = expect_handler(),
    ok = close_and_wait(Name, Old),
    ?assertEqual(1, inflight(Name)),
    %% The new request parks behind the handler the closed connection left.
    New = connect(Config),
    ok = request(New),
    ok = await_parked(Name),
    ?assertEqual(no_handler, no_handler()),
    %% Its end hands the slot to the parked request.
    ok = finish(Handler, release),
    Served = expect_handler(),
    ServedMon = monitor(process, Served),
    Served ! release,
    ?assertEqual(ok, await_ok(New)),
    ok = await_down(ServedMon),
    ok = close_and_wait(Name, New),
    ok = await_inflight(Name, 0).

%% The keeper drops the request a closed connection parked, so the slot
%% that frees next is not granted to it; and a grant that did reach it
%% would be in its cell, reclaimed with it. Either way nothing leaks.
parked_request_of_a_closed_conn_is_dropped(Config) ->
    Name = start(Config, 1, {queue, #{max_queued => 4, timeout => 10000}}),
    Holder = connect(Config),
    ok = request(Holder),
    Handler = expect_handler(),
    Parker = connect(Config),
    ok = request(Parker),
    ok = await_parked(Name),
    ok = close_and_wait(Name, Parker),
    Waiters = waiters(Name),
    ok = spin(
        fun() -> not roadrunner_overload_queue:waiting(Waiters) end,
        erlang:monotonic_time(millisecond) + 5000
    ),
    ok = finish(Handler, release),
    ok = close_and_wait(Name, Holder),
    ok = await_inflight(Name, 0),
    %% Once the keeper and the reaper have handled everything so far,
    %% nothing has taken the slot back.
    _ = sys:get_state(keeper(Name)),
    ok = reap(Name),
    ?assertEqual(0, inflight(Name)),
    ?assertEqual(no_handler, no_handler()).

%% A grant the keeper sends while the connection is already closing arrives
%% after the connection has stopped reading requests. The hand-off counts it
%% and gives the slot back. The connection is suspended to put the close
%% ahead of the grant in its mailbox.
grant_racing_the_close_is_given_back(Config) ->
    Name = start(Config, 1, {queue, #{max_queued => 4, timeout => 10000}}),
    Holder = connect(Config),
    ok = request(Holder),
    Handler = expect_handler(),
    {h2, Sock} = Parker = connect(Config),
    ok = request(Parker),
    ok = await_parked(Name),
    Conn = conn_of(Name, Parker),
    Mon = monitor(process, Conn),
    true = erlang:suspend_process(Conn),
    ok = gen_tcp:close(Sock),
    ok = await_queued(Conn, 1),
    %% The slot frees and is granted to the parked request, behind the close.
    ok = finish(Handler, release),
    ok = await_queued(Conn, 2),
    ?assertEqual(1, inflight(Name)),
    true = erlang:resume_process(Conn),
    ok = await_down(Mon),
    ok = close_and_wait(Name, Holder),
    ok = await_inflight(Name, 0),
    ?assertEqual(no_handler, no_handler()).

%% A drained connection closes once its last stream is gone, which a reset
%% stream is at once, while its handler may run on. It keeps its slot.
drained_conn_keeps_its_reset_handler_counted(Config) ->
    Name = start(Config, 1, refuse),
    Client = connect(Config),
    ok = request(Client),
    Handler = expect_handler(),
    Conn = conn_of(Name, Client),
    Mon = monitor(process, Conn),
    ok = reset_and_drain(Name, Client),
    ok = await_down(Mon),
    ?assertEqual(1, inflight(Name)),
    ok = finish(Handler, release),
    ok = await_inflight(Name, 0).

%% A connection killed while its handlers run leaves its slots in its cell.
%% The reaper's next tick reclaims them; the handlers still running stop
%% counting then, and their own ends release nothing more.
killed_conn_is_reclaimed(Config) ->
    Protocol = ?config(protocol, Config),
    Name = start(Config, 2, kill_mode(Protocol)),
    Client = connect(Config),
    Handlers = start_handlers(Protocol, Client),
    N = length(Handlers),
    ?assertEqual(N, inflight(Name)),
    Conn = server_conn(Name, Client, Handlers),
    Mon = monitor(process, Conn),
    true = exit(Conn, kill),
    ok = await_down(Mon),
    %% Nothing ran the exit path: the slots are still held.
    ?assertEqual(N, inflight(Name)),
    ok = reap(Name),
    ?assertEqual(0, inflight(Name)),
    [ok = finish(H, release) || H <- Handlers, is_process_alive(H)],
    _ = sys:get_state(keeper(Name)),
    ok = reap(Name),
    ?assertEqual(0, inflight(Name)).

%% A killed connection with a request parked is watched by the keeper,
%% which reclaims what it held at once, before any reaper tick.
killed_parked_conn_is_reclaimed_by_the_keeper(Config) ->
    Name = start(Config, 2, {queue, #{max_queued => 4, timeout => 10000}}),
    Other = connect(Config),
    ok = request(Other),
    OtherHandler = expect_handler(),
    Client = connect(Config),
    ok = request(Client),
    Handler = expect_handler(),
    ok = request(Client),
    ok = await_parked(Name),
    Conn = conn_of(Name, Client),
    Mon = monitor(process, Conn),
    true = exit(Conn, kill),
    ok = await_down(Mon),
    ok = await_inflight(Name, 1),
    ok = reap(Name),
    ?assertEqual(1, inflight(Name)),
    ok = finish(Handler, release),
    ok = finish(OtherHandler, release),
    ok = close_and_wait(Name, Other),
    ok = await_inflight(Name, 0),
    ?assertEqual(no_handler, no_handler()).

%% A grant on its way to a connection that is killed before it reads it is
%% in the connection's cell already, so the reaper reclaims it. The
%% connection is suspended to have it killed with the grant unread.
grant_racing_a_crash_is_reclaimed(Config) ->
    Name = start(Config, 1, {queue, #{max_queued => 4, timeout => 10000}}),
    Holder = connect(Config),
    ok = request(Holder),
    Handler = expect_handler(),
    Parker = connect(Config),
    ok = request(Parker),
    ok = await_parked(Name),
    Conn = conn_of(Name, Parker),
    Mon = monitor(process, Conn),
    true = erlang:suspend_process(Conn),
    ok = finish(Handler, release),
    ok = await_queued(Conn, 1),
    ?assertEqual(1, inflight(Name)),
    true = exit(Conn, kill),
    ok = await_down(Mon),
    ok = reap(Name),
    ?assertEqual(0, inflight(Name)),
    ok = close_and_wait(Name, Holder),
    ok = reap(Name),
    ?assertEqual(0, inflight(Name)),
    ?assertEqual(no_handler, no_handler()).

%% The keeper grants a freed slot to a parked connection that died after
%% the reaper had already emptied its cell. The grant lands in that cell
%% with nothing left to empty it, so the keeper does. The keeper is
%% suspended to order its mailbox: the freed slot first, then the reaper's
%% tick runs, then the keeper serves.
grant_to_a_reaped_conn_is_reclaimed(Config) ->
    Name = start(Config, 1, {queue, #{max_queued => 4, timeout => 10000}}),
    Holder = connect(Config),
    ok = request(Holder),
    Handler = expect_handler(),
    Parker = connect(Config),
    ok = request(Parker),
    ok = await_parked(Name),
    Conn = conn_of(Name, Parker),
    Keeper = keeper(Name),
    ok = sys:suspend(Keeper),
    ok = finish(Handler, release),
    %% The holder's conn frees the slot and wakes the keeper.
    ok = await_queued(Keeper, 1),
    Mon = monitor(process, Conn),
    true = exit(Conn, kill),
    ok = await_down(Mon),
    ok = reap(Name),
    ok = sys:resume(Keeper),
    _ = sys:get_state(Keeper),
    ?assertEqual(0, inflight(Name)),
    ok = close_and_wait(Name, Holder),
    ok = reap(Name),
    ?assertEqual(0, inflight(Name)),
    ?assertEqual(no_handler, no_handler()).

%% Reclaiming a killed connection's slots frees several at once: every
%% request parked behind them is granted, not just the first.
reclaimed_slots_are_all_granted(Config) ->
    Name = start(Config, 2, {queue, #{max_queued => 4, timeout => 10000}}),
    Killed = connect(Config),
    Handlers = start_handlers(h2, Killed),
    Parker = connect(Config),
    ok = request(Parker),
    ok = request(Parker),
    ok = await_parked(Name, 2),
    Conn = conn_of(Name, Killed),
    Mon = monitor(process, Conn),
    true = exit(Conn, kill),
    ok = await_down(Mon),
    ok = reap(Name),
    Served = [expect_handler(), expect_handler()],
    ?assertEqual(2, inflight(Name)),
    [ok = finish(H, release) || H <- Served ++ Handlers],
    ok = close_and_wait(Name, Parker),
    ok = await_inflight(Name, 0).

kill_mode(h1) -> {shed, #{}};
kill_mode(_) -> refuse.

%% Start the handlers the killed-connection case holds: one on HTTP/1.1
%% (its connection serves one request at a time), two otherwise.
start_handlers(h1, Client) ->
    ok = request(Client),
    [expect_handler()];
start_handlers(_Protocol, Client) ->
    ok = request(Client),
    ok = request(Client),
    [expect_handler(), expect_handler()].

%% On HTTP/1.1 the handler runs in the connection process.
server_conn(_Name, {h1, _Sock}, [Handler]) -> Handler;
server_conn(Name, Client, _Handlers) -> conn_of(Name, Client).

%% Run one tick of the listener's reaper, in its process.
reap(Name) ->
    whereis(Name) ! reconcile_slots,
    _ = sys:get_state(Name),
    ok.

%% The keeper stops with its listener. A connection that outlives both still
%% exits cleanly, with nothing left to hand its handlers' slots to.
conn_closing_after_its_listener_stopped_exits_cleanly(Config) ->
    Name = start(Config, 1, refuse),
    {h2, Sock} = Client = connect(Config),
    ok = request(Client),
    Handler = expect_handler(),
    Conn = conn_of(Name, Client),
    Keeper = keeper(Name),
    KeeperMon = monitor(process, Keeper),
    ok = roadrunner_listener:stop(Name),
    ok = await_down(KeeperMon),
    Mon = monitor(process, Conn),
    ok = gen_tcp:close(Sock),
    receive
        {'DOWN', Mon, process, Conn, Reason} -> ?assertEqual(normal, Reason)
    after 5000 -> ct:fail(conn_did_not_exit)
    end,
    Handler ! release.

%% A listener stopped while requests are parked takes its queue process
%% with it, but not the HTTP/2 connection, which it does not link. That
%% connection refuses what it had parked instead of leaving it to hang,
%% and from then on refuses a request over the ceiling instead of parking
%% it with no one to answer; one under the ceiling is still served.
parked_request_of_a_stopped_listener_is_refused(Config) ->
    Name = start(Config, 1, {queue, #{max_queued => 4, timeout => 30000}}),
    ok = parked_then_queue_gone(Name, Config, fun() -> roadrunner_listener:stop(Name) end).

%% A drain with `graceful_drain => false` kills no connection at its
%% deadline, having no registry of them, so one that outlives it ends as
%% after `roadrunner_listener:stop/1`: its listener and queue process gone.
parked_request_of_an_ungraceful_drain_is_refused(Config) ->
    Name = start(Config, 1, {queue, #{max_queued => 4, timeout => 30000}}, #{
        graceful_drain => false
    }),
    ok = parked_then_queue_gone(Name, Config, fun() ->
        {timeout, 1} = roadrunner_listener:drain(Name, 100),
        ok
    end).

%% A connection that never parked has no watch on the queue process, and
%% once that process is gone the count of parked requests stays up, so the
%% connection's first request still parks. The watch it sets then fires at
%% once, and the request is admitted as one arriving now: refused over the
%% ceiling, served under it.
never_parked_conn_after_its_listener_stopped_admits_afresh(Config) ->
    Name = start(Config, 1, {queue, #{max_queued => 4, timeout => 30000}}),
    {h2, HolderSock} = Holder = connect(Config),
    ok = request(Holder),
    Handler = expect_handler(),
    ok = request(Holder),
    ok = await_parked(Name),
    {h2, OverSock} = Over = connect(Config),
    ok = await_ping_ack(OverSock),
    {h2, UnderSock} = Under = connect(Config),
    ok = await_ping_ack(UnderSock),
    KeeperMon = monitor(process, keeper(Name)),
    ok = roadrunner_listener:stop(Name),
    ok = await_down(KeeperMon),
    ?assertEqual({rst_stream, refused_stream}, h2_end(HolderSock)),
    ?assertEqual(refused, request_outcome(Over)),
    ok = finish(Handler, release),
    ?assertEqual(complete, h2_end(HolderSock)),
    %% The holder frees the slot on its worker's `DOWN`, which comes before
    %% this PING, so the ACK proves the slot free.
    ok = await_ping_ack(HolderSock),
    ok = request(Under),
    Served = expect_handler(),
    ok = finish(Served, release),
    ?assertEqual(ok, await_ok(Under)).

%% One request holds the only slot and a second parks; `End` takes the
%% listener and its queue process down while the connection lives on.
parked_then_queue_gone(Name, Config, End) ->
    {h2, Sock} = Client = connect(Config),
    ok = request(Client),
    Handler = expect_handler(),
    ok = request(Client),
    ok = await_parked(Name),
    KeeperMon = monitor(process, keeper(Name)),
    ok = End(),
    ok = await_down(KeeperMon),
    ?assertEqual({rst_stream, refused_stream}, h2_end(Sock)),
    ?assertEqual(refused, request_outcome(Client)),
    ok = finish(Handler, release),
    ?assertEqual(complete, h2_end(Sock)),
    ok = request(Client),
    Served = expect_handler(),
    ok = finish(Served, release),
    ?assertEqual(ok, await_ok(Client)).

%% The connections that outlive a stopped listener still admit requests
%% against its counter. One that closes after the keeper stopped, its
%% handler still running, has no keeper to hand that slot to: it releases
%% it, so the others still get the whole ceiling.
hand_off_after_the_keeper_stopped_is_released(Config) ->
    Name = start(Config, 2, refuse),
    Counter = counter(Name),
    Old = connect(Config),
    ok = request(Old),
    Handler = expect_handler(),
    Conn = conn_of(Name, Old),
    Survivor = survivor(Config),
    ok = stop_with_keeper(Name),
    Mon = monitor(process, Conn),
    ok = close(Old),
    ok = await_down(Mon),
    ?assertEqual(0, counters:get(Counter, 1)),
    ok = finish(Handler, release),
    ok = served_twice(Survivor, Counter).

%% The slots of handlers whose connection closed before the stop are the
%% keeper's to release, and it releases them as it stops.
adopted_slots_are_released_as_the_keeper_stops(Config) ->
    Name = start(Config, 2, refuse),
    Counter = counter(Name),
    Old = connect(Config),
    ok = request(Old),
    Handler = expect_handler(),
    ok = close_and_wait(Name, Old),
    _ = sys:get_state(keeper(Name)),
    ?assertEqual(1, counters:get(Counter, 1)),
    Survivor = survivor(Config),
    ok = stop_with_keeper(Name),
    ?assertEqual(0, counters:get(Counter, 1)),
    ok = finish(Handler, release),
    ok = served_twice(Survivor, Counter).

%% A hand-off the keeper had not read when it stopped is released too. The
%% keeper is suspended to stop it with the hand-off unread.
unread_hand_off_is_released_as_the_keeper_stops(Config) ->
    Name = start(Config, 2, refuse),
    Counter = counter(Name),
    Old = connect(Config),
    ok = request(Old),
    ok = request(Old),
    Handlers = [expect_handler(), expect_handler()],
    Keeper = keeper(Name),
    ok = sys:suspend(Keeper),
    ok = close_and_wait(Name, Old),
    ok = await_queued(Keeper, 1),
    ?assertEqual(2, counters:get(Counter, 1)),
    Survivor = survivor(Config),
    ok = stop_with_keeper(Name),
    ?assertEqual(0, counters:get(Counter, 1)),
    [ok = finish(H, release) || H <- Handlers],
    ok = served_twice(Survivor, Counter).

%% A keeper that dies takes its listener down, whose stop then finds no
%% keeper left to stop.
listener_goes_down_with_its_keeper(Config) ->
    Name = start(Config, 1, refuse),
    Listener = whereis(Name),
    true = unlink(Listener),
    Mon = monitor(process, Listener),
    true = exit(keeper(Name), kill),
    receive
        {'DOWN', Mon, process, Listener, Reason} -> ?assertEqual(killed, Reason)
    after 5000 -> ct:fail(listener_did_not_exit)
    end.

%% A parked connection killed just before the stop, its `DOWN` unread by
%% the keeper (suspended to keep it so), leaves its slots in its cell. The
%% keeper gives them back as it stops. With `graceful_drain => false` the
%% conn is not registered, so the listener's own last pass cannot.
dead_parked_conn_is_reclaimed_as_the_keeper_stops(Config) ->
    Name = start(Config, 2, {queue, #{max_queued => 4, timeout => 10000}}, #{
        graceful_drain => false
    }),
    Counter = counter(Name),
    Other = connect(Config),
    ok = request(Other),
    OtherHandler = expect_handler(),
    Client = connect(Config),
    ok = request(Client),
    Handler = expect_handler(),
    ok = request(Client),
    ok = await_parked(Name),
    Conn = labelled_conn(Client),
    Keeper = keeper(Name),
    ok = sys:suspend(Keeper),
    Mon = monitor(process, Conn),
    true = exit(Conn, kill),
    ok = await_down(Mon),
    ok = await_queued(Keeper, 1),
    ?assertEqual(2, counters:get(Counter, 1)),
    ok = stop_with_keeper(Name),
    ?assertEqual(1, counters:get(Counter, 1)),
    ok = finish(Handler, release),
    ok = finish(OtherHandler, release),
    ok = spin(
        fun() -> counters:get(Counter, 1) =:= 0 end, erlang:monotonic_time(millisecond) + 5000
    ).

%% The server connection serving `Client`, found by its label: a listener
%% with `graceful_drain => false` keeps no registry to look it up in.
labelled_conn(Client) ->
    Port = client_port(Client),
    [Conn] = [Pid || Pid <- processes(), server_peer_port(Pid) =:= Port],
    Conn.

%% An HTTP/3 request loop goes down with its QUIC connection as the
%% listener stops, without its exit path. The listener gives back the slots
%% in its cell as it stops, as HTTP/2 connections that outlive it still
%% count against them; the handler's own end gives back nothing more.
http3_slots_are_released_as_the_listener_stops(Config) ->
    Name = start(Config, 2, refuse),
    Counter = counter(Name),
    Client = connect(Config),
    ok = request(Client),
    Handler = expect_handler(),
    ?assertEqual(1, counters:get(Counter, 1)),
    ok = roadrunner_listener:stop(Name),
    ?assertEqual(0, counters:get(Counter, 1)),
    ok = finish(Handler, release),
    ?assertEqual(0, counters:get(Counter, 1)).

%% On a listener that serves both, the HTTP/2 connection outlives the stop
%% and keeps its slot; the HTTP/3 loop's slot is given back.
http3_slots_are_released_beside_a_surviving_http2_conn(Config) ->
    Name = start(Config, 2, refuse, #{protocols => [http2, http3]}),
    Counter = counter(Name),
    {ok, Tls} = ssl:connect(
        {127, 0, 0, 1},
        roadrunner_listener:port(Name),
        [binary, {active, false}, {verify, verify_none}, {alpn_advertised_protocols, [~"h2"]}],
        5000
    ),
    ok = ssl:send(Tls, [~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", <<0:24, 4, 0, 0:32>>]),
    {ok, _} = ssl:recv(Tls, 0, 5000),
    {ok, H3} = roadrunner_quic_test_h3:connect(
        {127, 0, 0, 1}, roadrunner_listener:quic_port(Name)
    ),
    ok = request({h3, H3}),
    Handler = expect_handler(),
    ?assertEqual(1, counters:get(Counter, 1)),
    ok = roadrunner_listener:stop(Name),
    ?assertEqual(0, counters:get(Counter, 1)),
    ok = finish(Handler, release),
    %% The HTTP/2 connection is still up: it answers a PING.
    ok = ssl:send(Tls, roadrunner_http2_frame:encode({ping, 0, <<1, 2, 3, 4, 5, 6, 7, 8>>})),
    {ok, _} = ssl:recv(Tls, 0, 5000),
    ok = ssl:close(Tls).

%% A guard: with `graceful_drain => false` no loop registers for drain, so
%% the listener has none to watch as it stops, and the stop does not wait
%% on them.
http3_listener_without_a_drain_registry_stops(Config) ->
    Name = start(Config, 2, refuse, #{graceful_drain => false}),
    Client = connect(Config),
    ok = request(Client),
    Handler = expect_handler(),
    ok = roadrunner_listener:stop(Name),
    ok = finish(Handler, release).

%% A connection that is up before its listener stops, so it outlives it.
survivor(Config) ->
    {h2, Sock} = Client = connect(Config),
    ok = await_ping_ack(Sock),
    Client.

%% Stop the listener and wait for its keeper to be gone.
stop_with_keeper(Name) ->
    KeeperMon = monitor(process, keeper(Name)),
    ok = roadrunner_listener:stop(Name),
    await_down(KeeperMon).

%% Two requests on the connection both run at once: the whole ceiling of
%% two is there for it. Each slot comes back as its handler ends.
served_twice({h2, Sock} = Client, Counter) ->
    ok = request(Client),
    ok = request(Client),
    Handlers = [expect_handler(), expect_handler()],
    ?assertEqual(2, counters:get(Counter, 1)),
    [ok = finish(H, release) || H <- Handlers],
    ok = spin(
        fun() -> counters:get(Counter, 1) =:= 0 end, erlang:monotonic_time(millisecond) + 5000
    ),
    gen_tcp:close(Sock).

%% =============================================================================
%% Listener and slot accounting
%% =============================================================================

start(Config, Max, Overload) ->
    start(Config, Max, Overload, #{}).

start(Config, Max, Overload, Extra) ->
    Name = ?config(listener, Config),
    Opts = listener_opts(?config(protocol, Config), #{
        port => 0,
        routes => roadrunner_h2_slot_handler,
        max_concurrent_requests => Max,
        overload_mode => Overload
    }),
    {ok, _} = roadrunner_listener:start_link(Name, maps:merge(Opts, Extra)),
    Name.

listener_opts(h1, Opts) ->
    Opts#{protocols => [http1]};
listener_opts(h2, Opts) ->
    Opts#{protocols => [http2]};
listener_opts(h3, Opts) ->
    Opts#{protocols => [http3], tls => roadrunner_test_certs:server_opts()}.

proto_opts(Name) ->
    roadrunner_test_proto_opts:to_map(element(4, sys:get_state(whereis(Name)))).

inflight(Name) ->
    #{inflight_counter := Counter} = proto_opts(Name),
    counters:get(Counter, 1).

keeper(Name) ->
    #{slot_keeper := Keeper} = proto_opts(Name),
    Keeper.

counter(Name) ->
    #{inflight_counter := Counter} = proto_opts(Name),
    Counter.

waiters(Name) ->
    #{overload := {queue, _Pid, Waiters, _Timeout, _MaxQueued}} = proto_opts(Name),
    Waiters.

%% End a handler and wait until it is gone. Its slot is released by whoever
%% holds it (its connection or the keeper) on its own `DOWN`, so a test that
%% needs the release waits for the count (`await_inflight/2`).
finish(Handler, How) ->
    Mon = monitor(process, Handler),
    _ =
        case How of
            release -> Handler ! release;
            kill -> exit(Handler, kill)
        end,
    await_down(Mon).

%% Spin until the in-flight count reads `N`.
await_inflight(Name, N) ->
    Deadline = erlang:monotonic_time(millisecond) + 5000,
    spin(fun() -> inflight(Name) =:= N end, Deadline).

%% Spin until `Pid` has `N` messages queued.
await_queued(Pid, N) ->
    Deadline = erlang:monotonic_time(millisecond) + 5000,
    spin(
        fun() -> element(2, erlang:process_info(Pid, message_queue_len)) >= N end, Deadline
    ).

%% Spin until the keeper holds a parked request.
await_parked(Name) ->
    await_parked(Name, 1).

%% Spin until the keeper holds at least `N` parked requests.
await_parked(Name, N) ->
    Waiters = waiters(Name),
    Deadline = erlang:monotonic_time(millisecond) + 5000,
    spin(fun() -> atomics:get(Waiters, 1) >= N end, Deadline).

spin(Check, Deadline) ->
    case Check() of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    erlang:yield(),
                    spin(Check, Deadline);
                false ->
                    ct:fail(condition_never_met)
            end
    end.

await_down(Mon) ->
    receive
        {'DOWN', Mon, process, _, _} -> ok
    after 5000 -> ct:fail(process_did_not_exit)
    end.

expect_handler() ->
    receive
        {handler_started, Pid} -> Pid
    after 5000 -> ct:fail(handler_never_started)
    end.

no_handler() ->
    receive
        {handler_started, _} -> handler_started
    after 0 -> no_handler
    end.

%% =============================================================================
%% Clients
%% =============================================================================

connect(Config) ->
    connect(?config(protocol, Config), roadrunner_listener:port(?config(listener, Config))).

connect(h1, Port) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}, {nodelay, true}], 5000
    ),
    {h1, Sock};
connect(h2, Port) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}, {nodelay, true}], 5000
    ),
    ok = gen_tcp:send(Sock, [~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", <<0:24, 4, 0, 0:32>>]),
    {h2, Sock};
connect(h3, Port) ->
    {ok, Conn} = roadrunner_quic_test_h3:connect({127, 0, 0, 1}, Port),
    {h3, Conn}.

%% Close the client side and wait for the server's connection process to
%% exit, so its hand-off is done.
close_and_wait(Name, Client) ->
    Conn = conn_of(Name, Client),
    Mon = monitor(process, Conn),
    ok = close(Client),
    await_down(Mon).

close({h2, Sock}) ->
    gen_tcp:close(Sock);
close({h3, Conn}) ->
    _ = roadrunner_quic_test_h3:close(Conn),
    ok.

%% The server connection process serving `Client`, matched on the client's
%% local port.
conn_of(Name, Client) ->
    #{drain_table := Table} = proto_opts(Name),
    Port = client_port(Client),
    [Conn] = [
        Pid
     || {Pid, _Cell} <- ets:tab2list(Table), server_peer_port(Pid) =:= Port
    ],
    Conn.

client_port({h2, Sock}) ->
    {ok, {_, Port}} = inet:sockname(Sock),
    Port;
client_port({h3, Conn}) ->
    {ok, {_, Port}} = roadrunner_quic_test_conn:sockname(Conn),
    Port.

%% Each connection process labels itself with its peer.
server_peer_port(Pid) ->
    case proc_lib:get_label(Pid) of
        {roadrunner_conn_loop_http2, _Listener, {_, Port}} -> Port;
        {roadrunner_conn_loop_http3, _Listener, QuicConn} -> quic_peer_port(QuicConn);
        _ -> undefined
    end.

quic_peer_port(QuicConn) ->
    {ok, {_, Port}} = roadrunner_quic:peername(QuicConn),
    Port.

%% Send a GET on a new stream. h2 streams take the next odd id, and h3
%% remembers the stream it opened, both in the process dictionary.
request({h1, Sock}) ->
    gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n");
request({h2, Sock}) ->
    StreamId = next_stream_id(Sock),
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Block, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"http"},
            {~":authority", ~"localhost"},
            {~":path", ~"/"}
        ],
        Enc
    ),
    gen_tcp:send(
        Sock,
        roadrunner_http2_frame:encode(
            {headers, StreamId, 16#04 bor 16#01, undefined, iolist_to_binary(Block)}
        )
    );
request({h3, Conn}) ->
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, [
        {~":method", ~"GET"},
        {~":scheme", ~"https"},
        {~":authority", ~"localhost"},
        {~":path", ~"/"}
    ]),
    _ = put({h3_stream, Conn}, StreamId),
    ok.

next_stream_id(Sock) ->
    Id =
        case get({h2_stream, Sock}) of
            undefined -> 1;
            Last -> Last + 2
        end,
    _ = put({h2_stream, Sock}, Id),
    Id.

%% The outcome of a request expected to be refused at the ceiling.
request_outcome(Client) ->
    ok = request(Client),
    case Client of
        {h2, Sock} ->
            case h2_end(Sock) of
                {rst_stream, refused_stream} -> refused;
                Other -> Other
            end;
        {h3, Conn} ->
            case roadrunner_quic_test_h3:collect(Conn, get({h3_stream, Conn})) of
                {error, {stream_reset, ?H3_REQUEST_REJECTED}} -> refused;
                Other -> Other
            end
    end.

%% Wait for the last request's response to complete with a 200.
await_ok({h2, Sock}) ->
    case h2_end(Sock) of
        complete -> ok;
        Other -> Other
    end;
await_ok({h3, Conn}) ->
    case roadrunner_quic_test_h3:collect(Conn, get({h3_stream, Conn})) of
        {200, _Headers, ~"ok"} -> ok;
        Other -> Other
    end.

%% Read until a stream ends: a response with END_STREAM, or a RST_STREAM.
h2_end(Sock) ->
    h2_end(Sock, <<>>).

h2_end(Sock, Buf) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {ok, {rst_stream, _, Code}, _Rest} ->
            {rst_stream, Code};
        {ok, {data, _, Flags, _, _}, _Rest} when (Flags band 16#01) =/= 0 ->
            complete;
        {ok, {headers, _, Flags, _, _}, _Rest} when (Flags band 16#01) =/= 0 ->
            complete;
        {ok, _, Rest} ->
            h2_end(Sock, Rest);
        {more, _} ->
            {ok, More} = gen_tcp:recv(Sock, 0, 5000),
            h2_end(Sock, <<Buf/binary, More/binary>>)
    end.

%% Reset the client's only request, then drain the listener and wait for
%% the server to close the connection.
reset_and_drain(Name, {h2, Sock}) ->
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({rst_stream, 1, cancel})),
    ok = await_ping_ack(Sock),
    ok = drain(Name),
    closed = read_until_closed(Sock),
    ok;
reset_and_drain(Name, {h3, Conn}) ->
    ok = roadrunner_quic_test_h3:cancel(Conn, get({h3_stream, Conn})),
    ok = drain(Name).

drain(Name) ->
    roadrunner_listener:notify_drain(Name, erlang:monotonic_time(millisecond) + 30000).

%% Frames are handled in order, so the PING's ACK proves everything sent
%% before it has been.
await_ping_ack(Sock) ->
    ok = gen_tcp:send(
        Sock, roadrunner_http2_frame:encode({ping, 0, <<1, 2, 3, 4, 5, 6, 7, 8>>})
    ),
    await_ping_ack(Sock, <<>>).

await_ping_ack(Sock, Buf) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {ok, {ping, 1, _}, _Rest} ->
            ok;
        {ok, _, Rest} ->
            await_ping_ack(Sock, Rest);
        {more, _} ->
            {ok, More} = gen_tcp:recv(Sock, 0, 5000),
            await_ping_ack(Sock, <<Buf/binary, More/binary>>)
    end.

%% Read until the server closes, answering its PINGs (RFC 9113 §6.7): a
%% draining connection sends its final GOAWAY on the ACK of the PING that
%% follows its first one (§6.8).
read_until_closed(Sock) ->
    read_until_closed(Sock, <<>>).

read_until_closed(Sock, Buf) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {ok, {ping, 0, Opaque}, Rest} ->
            ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({ping, 1, Opaque})),
            read_until_closed(Sock, Rest);
        {ok, _Frame, Rest} ->
            read_until_closed(Sock, Rest);
        {more, _} ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, Data} -> read_until_closed(Sock, <<Buf/binary, Data/binary>>);
                {error, Reason} -> Reason
            end
    end.
