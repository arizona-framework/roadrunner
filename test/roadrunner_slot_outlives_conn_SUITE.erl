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
    drained_conn_keeps_its_reset_handler_counted/1,
    conn_closing_after_its_listener_stopped_exits_cleanly/1
]).

-define(H3_REQUEST_REJECTED, 16#10B).
-define(COLLECTOR, roadrunner_h2_slot_collector).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [{group, h2}, {group, h3}].

groups() ->
    Common = [
        refused_until_the_old_handlers_end,
        queued_until_the_old_handler_ends,
        parked_request_of_a_closed_conn_is_dropped,
        drained_conn_keeps_its_reset_handler_counted
    ],
    %% HTTP/3 has no listener-stopped case: stopping the listener stops its
    %% QUIC connections, and with them the linked request loops.
    [
        {h2, [],
            Common ++
                [
                    grant_racing_the_close_is_given_back,
                    conn_closing_after_its_listener_stopped_exits_cleanly
                ]},
        {h3, [], Common}
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

%% A connection's hand-off withdraws the requests it parked before it exits,
%% so no slot that frees later is granted to a connection that is gone,
%% which would leak it. The queue is empty the moment the connection is.
parked_request_of_a_closed_conn_is_dropped(Config) ->
    Name = start(Config, 1, {queue, #{max_queued => 4, timeout => 10000}}),
    Holder = connect(Config),
    ok = request(Holder),
    Handler = expect_handler(),
    Parker = connect(Config),
    ok = request(Parker),
    ok = await_parked(Name),
    ok = close_and_wait(Name, Parker),
    ?assertNot(roadrunner_overload_queue:waiting(waiters(Name))),
    ok = finish(Handler, release),
    ok = close_and_wait(Name, Holder),
    ok = await_inflight(Name, 0),
    %% Once the keeper has handled everything sent to it so far, nothing has
    %% taken the slot back.
    _ = sys:get_state(keeper(Name)),
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

%% =============================================================================
%% Listener and slot accounting
%% =============================================================================

start(Config, Max, Overload) ->
    Name = ?config(listener, Config),
    {ok, _} = roadrunner_listener:start_link(
        Name,
        listener_opts(?config(protocol, Config), #{
            port => 0,
            routes => roadrunner_h2_slot_handler,
            max_concurrent_requests => Max,
            overload_mode => Overload
        })
    ),
    Name.

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

waiters(Name) ->
    #{overload := {queue, _Pid, Waiters, _Timeout}} = proto_opts(Name),
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
    Waiters = waiters(Name),
    Deadline = erlang:monotonic_time(millisecond) + 5000,
    spin(fun() -> roadrunner_overload_queue:waiting(Waiters) end, Deadline).

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
     || {Pid} <- ets:tab2list(Table), server_peer_port(Pid) =:= Port
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
