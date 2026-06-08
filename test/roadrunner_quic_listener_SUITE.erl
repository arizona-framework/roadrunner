-module(roadrunner_quic_listener_SUITE).
-moduledoc """
Integration tests for `roadrunner_quic_listener`.

A CT suite rather than eunit: the load-bearing case drives the native QUIC
client through a real handshake against the native listener over
loopback, and the process-loop edges (sys/gen messages, monitor cleanup,
datagram routing) need a live listener process with the suite timetrap as
an outer guard. The pure routing decision (`classify/2`) is unit-tested in
`roadrunner_quic_listener_tests`.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([
    native_client_handshakes_through_listener/1,
    bind_failure_is_reported/1,
    stop_closes_listener/1,
    unsupported_gen_call_replies_error/1,
    gen_cast_is_ignored/1,
    system_message_exposes_state/1,
    stray_message_is_ignored/1,
    malformed_datagram_is_dropped/1,
    sends_version_negotiation_for_unsupported_version/1,
    uses_injected_registry/1,
    conn_death_before_set_owner_does_not_wedge/1,
    conn_down_is_cleaned_up/1
]).

-define(LOOPBACK, {127, 0, 0, 1}).
-define(QUIC_V1, 16#00000001).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        native_client_handshakes_through_listener,
        bind_failure_is_reported,
        stop_closes_listener,
        unsupported_gen_call_replies_error,
        gen_cast_is_ignored,
        system_message_exposes_state,
        stray_message_is_ignored,
        malformed_datagram_is_dropped,
        sends_version_negotiation_for_unsupported_version,
        uses_injected_registry,
        conn_death_before_set_owner_does_not_wedge,
        conn_down_is_cleaned_up
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(ssl),
    %% The default `pg` scope hosts a connection owner's drain group; start it
    %% unlinked so it outlives this transient process.
    ok = ensure_pg_started(),
    Config.

end_per_suite(_Config) ->
    ok.

%% =============================================================================
%% The native client completes a real handshake routed through the native
%% listener: this exercises the whole spawn ordering (spawn -> register CIDs ->
%% run handler -> set_owner_sync -> feed first Initial), the active-socket read
%% path, and datagram routing (the first Initial spawns, every follow-up
%% datagram forwards to the registered connection by its server SCID).
%% =============================================================================

native_client_handshakes_through_listener(_Config) ->
    %% Report the spawned owner so it can be torn down with the case rather than
    %% leaking an idle drain process for the rest of the suite run.
    Test = self(),
    Handler = fun(_ConnPid) ->
        Owner = spawn(fun drain/0),
        Test ! {owner, Owner},
        {ok, Owner}
    end,
    {Listener, Port} = start_listener(Handler),

    %% A {ok, _} from connect/2 means the full QUIC + TLS 1.3 handshake
    %% completed (the server's HANDSHAKE_DONE arrived) through the listener.
    Result =
        case roadrunner_quic_test_conn:connect(?LOOPBACK, Port) of
            {ok, Conn} ->
                ok = roadrunner_quic_test_conn:close(Conn),
                ok;
            {error, Reason} ->
                {error, Reason}
        end,

    receive
        {owner, Owner} -> exit(Owner, kill)
    after 0 -> ok
    end,
    ok = roadrunner_quic_listener:stop(Listener),
    ?assertEqual(ok, Result).

%% A bind onto a port already held without reuseport surfaces synchronously as
%% {error, _} from start_link (init's error clause): a plain gen_udp blocker
%% (no reuseaddr) refuses the second bind.
bind_failure_is_reported(_Config) ->
    {ok, Blocker} = gen_udp:open(0, [binary, {active, false}]),
    {ok, {_Ip, Port}} = inet:sockname(Blocker),
    ?assertMatch(
        {error, _}, roadrunner_quic_listener:start_link(listener_opts(Port, drain_handler()))
    ),
    ok = gen_udp:close(Blocker).

%% stop/1 replies ok, closes the socket, and exits normally.
stop_closes_listener(_Config) ->
    {Listener, _Port} = start_listener(drain_handler()),
    Mon = monitor(process, Listener),
    ?assertEqual(ok, roadrunner_quic_listener:stop(Listener)),
    receive
        {'DOWN', Mon, process, Listener, normal} -> ok
    after 2000 ->
        ct:fail(listener_did_not_stop)
    end.

%% A stray gen_server:call (anything but get_port/stop) is answered with
%% {error, not_supported} so the caller fails fast instead of hanging.
unsupported_gen_call_replies_error(_Config) ->
    {Listener, _Port} = start_listener(drain_handler()),
    ?assertEqual({error, not_supported}, gen_server:call(Listener, bogus_request)),
    ok = roadrunner_quic_listener:stop(Listener).

%% A gen_server:cast is dropped; the loop survives (a later get_port answers).
gen_cast_is_ignored(_Config) ->
    {Listener, Port} = start_listener(drain_handler()),
    ok = gen_server:cast(Listener, anything),
    ?assertEqual(Port, roadrunner_quic_listener:get_port(Listener)),
    ok = roadrunner_quic_listener:stop(Listener).

%% The OTP system protocol works via roadrunner_loop_sys: sys:get_state returns
%% the listener's own state record.
system_message_exposes_state(_Config) ->
    {Listener, _Port} = start_listener(drain_handler()),
    State = sys:get_state(Listener),
    ?assertEqual(listener, element(1, State)),
    ok = roadrunner_quic_listener:stop(Listener).

%% A message that is neither an OTP nor a socket message parses to `ignore`
%% (handle_message's ignore clause) and is dropped; the loop survives.
stray_message_is_ignored(_Config) ->
    {Listener, Port} = start_listener(drain_handler()),
    _ = Listener ! not_a_datagram,
    ?assertEqual(Port, roadrunner_quic_listener:get_port(Listener)),
    ok = roadrunner_quic_listener:stop(Listener).

%% A datagram whose header cannot be classified is dropped (route's drop
%% clause), and a connection_handler that refuses (e.g. {error, max_clients})
%% does not get an owner installed (install_owner's error clause). Both are
%% driven from one ordered send: a malformed datagram, then a v1 Initial.
%% Loopback delivers the two in order to the active socket, so the handler
%% firing for the Initial proves the malformed datagram was already read and
%% routed to drop. The refusing handler also keeps the spawned connection
%% owner-less, so killing it for cleanup cannot race a set_owner_sync.
malformed_datagram_is_dropped(_Config) ->
    Test = self(),
    Handler = fun(ConnPid) ->
        Test ! {server_conn, ConnPid},
        {error, max_clients}
    end,
    {Listener, Port} = start_listener(Handler),
    {ok, Client} = roadrunner_quic_socket:open(0),
    %% A short-header first byte with too few bytes for the fixed 8-byte SCID:
    %% dcid/2 reports {error, truncated}, so classify -> drop.
    ok = roadrunner_quic_socket:send(Client, ?LOOPBACK, Port, <<16#40, 1, 2, 3>>),
    ok = roadrunner_quic_socket:send(Client, ?LOOPBACK, Port, crafted_initial()),
    ConnPid = receive_server_conn(),
    ?assert(is_pid(ConnPid)),
    ?assertEqual(Port, roadrunner_quic_listener:get_port(Listener)),
    exit(ConnPid, kill),
    ok = roadrunner_quic_socket:close(Client),
    ok = roadrunner_quic_listener:stop(Listener).

%% RFC 9000 §5.2.2/§17.2.1: an unsupported-version Initial at the 1200-byte
%% floor draws a Version Negotiation reply listing the supported versions, with
%% the client's connection ids echoed swapped (the reply's destination id is the
%% client's source id, its source id is the client's destination id). No
%% connection is spawned.
sends_version_negotiation_for_unsupported_version(_Config) ->
    {Listener, Port} = start_listener(drain_handler()),
    {ok, Client} = roadrunner_quic_socket:open(0),
    DCID = <<1, 2, 3, 4, 5, 6, 7, 8>>,
    SCID = <<9, 9, 9>>,
    Header =
        <<16#C0, 16#FF000001:32, (byte_size(DCID)), DCID/binary, (byte_size(SCID)), SCID/binary>>,
    Initial = <<Header/binary, 0:((1200 - byte_size(Header)) * 8)>>,
    ok = roadrunner_quic_socket:send(Client, ?LOOPBACK, Port, Initial),
    VN =
        case roadrunner_quic_socket:recv(Client, 2000) of
            {ok, _Peer, Datagram} -> Datagram;
            Other -> ct:fail({no_version_negotiation, Other})
        end,
    <<FirstByte, 0:32, VNDcidLen, VNDcid:VNDcidLen/binary, VNScidLen, VNScid:VNScidLen/binary,
        VersionsBin/binary>> = VN,
    %% Long-header form bit and the RFC7983 fixed-bit position are both set.
    ?assertEqual(16#C0, FirstByte band 16#C0),
    ?assertEqual(SCID, VNDcid),
    ?assertEqual(DCID, VNScid),
    ?assertEqual([?QUIC_V1], [V || <<V:32>> <= VersionsBin]),
    ok = roadrunner_quic_socket:close(Client),
    ok = roadrunner_quic_listener:stop(Listener).

%% When a spawned connection dies, the listener's monitor fires and the CID
%% registry row is dropped (delete_pid). This is proven, not merely
%% line-covered: an Initial with the dead connection's DCID is forwarded to it
%% while it lives, but once its row is gone the SAME DCID classifies as a new
%% connection and spawns a fresh one. So a different connection answering the
%% repeated Initial is direct evidence the row was removed. (delete_pid's own
%% correctness is unit-tested in roadrunner_quic_cid_registry_tests.)
%%
%% A refusing handler is used so no owner is installed (no set_owner_sync to
%% race the kill) while the connection is still spawned and registered.
conn_down_is_cleaned_up(_Config) ->
    Test = self(),
    Handler = fun(ConnPid) ->
        Test ! {server_conn, ConnPid},
        {error, max_clients}
    end,
    {Listener, Port} = start_listener(Handler),
    {ok, Client} = roadrunner_quic_socket:open(0),
    DCID = <<9, 9, 9, 9, 9, 9, 9, 9>>,
    Initial = crafted_initial(DCID),

    ok = roadrunner_quic_socket:send(Client, ?LOOPBACK, Port, Initial),
    Conn1 = receive_server_conn(),

    %% Kill the connection; the listener must drop its DCID row so the next
    %% Initial with the same DCID spawns a *different* connection.
    Mon = monitor(process, Conn1),
    exit(Conn1, kill),
    receive
        {'DOWN', Mon, process, Conn1, killed} -> ok
    after 2000 ->
        ct:fail(conn_not_killed)
    end,
    Conn2 = await_respawn(Client, Port, Initial, Conn1, 25),
    ?assertNotEqual(Conn1, Conn2),

    exit(Conn2, kill),
    ok = roadrunner_quic_socket:close(Client),
    ok = roadrunner_quic_listener:stop(Listener).

%% A connection that dies before accepting ownership does not wedge the listener
%% in set_owner_sync: its private monitor sees the death and aborts, so the loop
%% keeps serving. Without the guard the loop would block on the never-arriving
%% reply forever, a silent loss of a pool listener (no crash, no restart).
conn_death_before_set_owner_does_not_wedge(_Config) ->
    Test = self(),
    Handler = fun(ConnPid) ->
        %% Kill the connection before returning, so set_owner_sync races a dead
        %% conn (a stand-in for the connection crashing in its own init).
        exit(ConnPid, kill),
        Test ! {killed, ConnPid},
        {ok, spawn(fun drain/0)}
    end,
    {Listener, Port} = start_listener(Handler),
    {ok, Client} = roadrunner_quic_socket:open(0),
    ok = roadrunner_quic_socket:send(Client, ?LOOPBACK, Port, crafted_initial()),
    receive
        {killed, _ConnPid} -> ok
    after 2000 ->
        ct:fail(handler_not_invoked)
    end,
    %% The listener did not wedge: it still answers.
    ?assertEqual(Port, roadrunner_quic_listener:get_port(Listener)),
    ok = roadrunner_quic_socket:close(Client),
    ok = roadrunner_quic_listener:stop(Listener).

%% A listener routes through an INJECTED registry (the pool's shared table), not
%% a private one: a datagram for a connection id registered in the injected
%% table is forwarded to that connection. This is what lets a SO_REUSEPORT pool
%% route a datagram landing on any listener to the owning connection.
uses_injected_registry(_Config) ->
    Registry = roadrunner_quic_cid_registry:new(),
    DCID = <<1, 2, 3, 4, 5, 6, 7, 8>>,
    ok = roadrunner_quic_cid_registry:register_pair(
        Registry, DCID, <<9, 9, 9, 9, 9, 9, 9, 9>>, self()
    ),
    Opts = (listener_opts(0, drain_handler()))#{registry => Registry},
    {ok, Listener} = roadrunner_quic_listener:start_link(Opts),
    Port = roadrunner_quic_listener:get_port(Listener),
    {ok, Client} = roadrunner_quic_socket:open(0),
    %% A short-header (1-RTT) datagram whose destination id is the registered id.
    ok = roadrunner_quic_socket:send(Client, ?LOOPBACK, Port, <<16#40, DCID/binary, 0>>),
    receive
        {quic_datagram, _Peer, _Bytes} -> ok
    after 2000 ->
        ct:fail(not_forwarded_via_injected_registry)
    end,
    ok = roadrunner_quic_socket:close(Client),
    ok = roadrunner_quic_listener:stop(Listener).

%% =============================================================================
%% Helpers
%% =============================================================================

start_listener(Handler) ->
    {ok, Listener} = roadrunner_quic_listener:start_link(listener_opts(0, Handler)),
    Port = roadrunner_quic_listener:get_port(Listener),
    {Listener, Port}.

%% The connection pid reported by a spawn-signalling connection_handler.
receive_server_conn() ->
    receive
        {server_conn, Pid} -> Pid
    after 2000 ->
        ct:fail(handler_not_invoked)
    end.

%% Resend an Initial until a *different* connection answers it. While the dead
%% connection's DCID row lingers the Initial forwards to it (no new spawn, no
%% signal); once the row is dropped the same DCID spawns a fresh connection. So
%% a different pid answering is direct proof the row was removed. Bounded, so a
%% genuine cleanup failure fails the case rather than looping forever.
await_respawn(_Client, _Port, _Initial, _Old, 0) ->
    ct:fail(cid_row_not_cleaned_up);
await_respawn(Client, Port, Initial, Old, Attempts) ->
    ok = roadrunner_quic_socket:send(Client, ?LOOPBACK, Port, Initial),
    receive
        {server_conn, New} when New =/= Old -> New
    after 200 ->
        await_respawn(Client, Port, Initial, Old, Attempts - 1)
    end.

listener_opts(Port, Handler) ->
    {CertChain, PrivKey} = cert_key(),
    #{
        port => Port,
        cert_chain => CertChain,
        priv_key => PrivKey,
        alpn => ~"h3",
        transport_params => #{
            initial_max_data => 1048576,
            initial_max_stream_data_bidi_local => 262144,
            initial_max_stream_data_bidi_remote => 262144,
            initial_max_stream_data_uni => 262144,
            initial_max_streams_bidi => 100,
            initial_max_streams_uni => 100,
            max_idle_timeout => 30000
        },
        connection_handler => Handler
    }.

%% A handler returning a process that swallows the connection's emitted events,
%% so a real handshake can run to completion.
drain_handler() ->
    fun(_ConnPid) -> {ok, spawn(fun drain/0)} end.

drain() ->
    receive
        _ -> drain()
    end.

%% A long-header QUIC v1 Initial (first byte 0xC0 = long+fixed+type 00) with a
%% fresh 8-byte DCID, padded to the RFC 9000 §14.1 1200-byte floor so the
%% listener spawns for it; the body is junk (the spawned connection drops the
%% undecryptable packet and idles).
crafted_initial() ->
    crafted_initial(crypto:strong_rand_bytes(8)).

crafted_initial(DCID) ->
    Header = <<16#C0, ?QUIC_V1:32, (byte_size(DCID)), DCID/binary>>,
    <<Header/binary, 0:((1200 - byte_size(Header)) * 8)>>.

cert_key() ->
    Opts = roadrunner_test_certs:server_opts(),
    {cert, CertDer} = lists:keyfind(cert, 1, Opts),
    {key, {KeyType, KeyDer}} = lists:keyfind(key, 1, Opts),
    {[CertDer], public_key:der_decode(KeyType, KeyDer)}.

ensure_pg_started() ->
    case whereis(pg) of
        undefined ->
            case pg:start_link() of
                {ok, Pid} ->
                    _ = unlink(Pid),
                    ok;
                {error, {already_started, _}} ->
                    ok
            end;
        _ ->
            ok
    end.
