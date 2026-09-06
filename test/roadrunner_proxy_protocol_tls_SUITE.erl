-module(roadrunner_proxy_protocol_tls_SUITE).
-moduledoc """
PROXY protocol in front of TLS.

An L4 balancer prepends its PROXY header in plaintext before the
ClientHello, so a TLS listener with `proxy_protocol => true` accepts
plain TCP, reads exactly the header, and only then upgrades the socket
to TLS. Drives a real listener with clients that speak PROXY-then-TLS
and checks the served peer, the exact-read bounds, and every failure
path between the header and the handshake.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    v2_header_then_tls_reports_client_peer/1,
    v1_header_then_tls_reports_client_peer/1,
    v1_unknown_then_tls_keeps_os_peer/1,
    v2_header_split_across_segments/1,
    v2_local_without_address_block_keeps_os_peer/1,
    h2_alpn_negotiates_after_the_header/1,
    missing_header_closes_without_handshake/1,
    overlong_v1_header_closes/1,
    v1_line_without_cr_closes/1,
    silence_before_header_times_out/1,
    peer_gone_mid_header_closes/1,
    garbage_after_header_fails_handshake/1,
    silence_after_header_times_out/1
]).

-define(V2_SIG, 16#0D, 16#0A, 16#0D, 16#0A, 16#00, 16#0D, 16#0A, 16#51, 16#55, 16#49, 16#54, 16#0A).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        v2_header_then_tls_reports_client_peer,
        v1_header_then_tls_reports_client_peer,
        v1_unknown_then_tls_keeps_os_peer,
        v2_header_split_across_segments,
        v2_local_without_address_block_keeps_os_peer,
        h2_alpn_negotiates_after_the_header,
        missing_header_closes_without_handshake,
        overlong_v1_header_closes,
        v1_line_without_cr_closes,
        silence_before_header_times_out,
        peer_gone_mid_header_closes,
        garbage_after_header_fails_handshake,
        silence_after_header_times_out
    ].

init_per_testcase(Case, Config) ->
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    HandlerId = {?MODULE, Case},
    ok = telemetry:attach_many(
        HandlerId,
        [[roadrunner, listener, accept], [roadrunner, listener, accept_error]],
        fun(Event, _Measure, Meta, _Cfg) -> Self ! {lists:last(Event), Meta} end,
        undefined
    ),
    [{handler_id, HandlerId} | Config].

end_per_testcase(_Case, Config) ->
    ok = telemetry:detach(?config(handler_id, Config)),
    ok = roadrunner_listener:stop(?MODULE).

v2_header_then_tls_reports_client_peer(_Config) ->
    Port = start_listener(#{}),
    Hdr = v2(16#21, 16#11, <<203, 0, 113, 9, 10, 0, 0, 1, 5000:16, 443:16>>),
    ?assertEqual(~"203.0.113.9", peer_through(Port, [Hdr])),
    ok = wait_for_active_clients(0).

v1_header_then_tls_reports_client_peer(_Config) ->
    Port = start_listener(#{}),
    ?assertEqual(
        ~"192.168.0.7",
        peer_through(Port, [~"PROXY TCP4 192.168.0.7 10.0.0.1 5000 443\r\n"])
    ).

v1_unknown_then_tls_keeps_os_peer(_Config) ->
    Port = start_listener(#{}),
    ?assertEqual(~"127.0.0.1", peer_through(Port, [~"PROXY UNKNOWN\r\n"])).

v2_header_split_across_segments(_Config) ->
    %% The exact reads wait for the rest of the header rather than deciding
    %% on a partial one.
    Port = start_listener(#{}),
    <<First:10/binary, Second/binary>> =
        v2(16#21, 16#11, <<198, 51, 100, 23, 10, 0, 0, 1, 40000:16, 443:16>>),
    ?assertEqual(~"198.51.100.23", peer_through(Port, [First, Second])).

v2_local_without_address_block_keeps_os_peer(_Config) ->
    %% LOCAL command, AF_UNSPEC, zero-length address block: nothing to read
    %% past the 16-byte prefix, and the OS peer stands.
    Port = start_listener(#{}),
    ?assertEqual(~"127.0.0.1", peer_through(Port, [v2(16#20, 16#00, <<>>)])).

h2_alpn_negotiates_after_the_header(_Config) ->
    %% The upgrade carries the listener's ALPN list like `ssl:listen` does.
    Port = start_listener(#{protocols => [http2, http1]}),
    {ok, Tcp} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Tcp, v2(16#21, 16#11, <<203, 0, 113, 9, 10, 0, 0, 1, 5000:16, 443:16>>)),
    {ok, Tls} = ssl:connect(
        Tcp, client_opts() ++ [{alpn_advertised_protocols, [~"h2"]}], 5000
    ),
    ?assertEqual({ok, ~"h2"}, ssl:negotiated_protocol(Tls)),
    ok = ssl:close(Tls).

missing_header_closes_without_handshake(_Config) ->
    %% A raw ClientHello-less request on a PROXY listener is a misconfigured
    %% upstream: the connection closes before any TLS is attempted, so the
    %% peer sees plain EOF and no alert, and the close is reported with the
    %% parser's reason.
    Port = start_listener(#{}),
    {ok, Tcp} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Tcp, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
    ?assertEqual({error, closed}, gen_tcp:recv(Tcp, 0, 5000)),
    ok = gen_tcp:close(Tcp),
    ?assertEqual({proxy_protocol, not_proxy_header}, await_accept_error()),
    ok = wait_for_active_clients(0).

overlong_v1_header_closes(_Config) ->
    %% A v1 line that runs past the spec's 107 bytes without a CRLF.
    Port = start_listener(#{}),
    {ok, Tcp} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Tcp, <<"PROXY ", (binary:copy(~"x", 120))/binary>>),
    ?assertEqual({error, closed}, gen_tcp:recv(Tcp, 0, 5000)),
    ok = gen_tcp:close(Tcp),
    %% `line` packet mode fails the read at the bound with `emsgsize`.
    ?assertEqual({proxy_protocol, emsgsize}, await_accept_error()).

v1_line_without_cr_closes(_Config) ->
    %% The spec's line ends in CRLF; a bare LF is read as a line but is not a
    %% header, and the connection closes before any TLS is attempted.
    Port = start_listener(#{}),
    {ok, Tcp} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Tcp, ~"PROXY UNKNOWN\n"),
    ?assertEqual({error, closed}, gen_tcp:recv(Tcp, 0, 5000)),
    ok = gen_tcp:close(Tcp),
    ?assertEqual({proxy_protocol, v1_malformed}, await_accept_error()).

silence_before_header_times_out(_Config) ->
    %% The header read shares `tls_handshake_timeout`, so a peer that connects
    %% and sends nothing is cut off on the same schedule as one that never
    %% sends a ClientHello, and reported with the transport's `timeout`.
    Port = start_listener(#{tls_handshake_timeout => 200}),
    {ok, Tcp} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual({error, closed}, gen_tcp:recv(Tcp, 0, 5000)),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 2000),
    ok = gen_tcp:close(Tcp),
    ?assertEqual({proxy_protocol, timeout}, await_accept_error()),
    ok = wait_for_active_clients(0).

peer_gone_mid_header_closes(_Config) ->
    %% The peer disconnects with the header half sent, once inside a v1 line
    %% and once inside a v2 prefix: both reads fail with `closed`, the conn
    %% closes and reports it.
    Port = start_listener(#{}),
    lists:foreach(
        fun(Partial) ->
            {ok, Tcp} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
            ok = gen_tcp:send(Tcp, Partial),
            ok = gen_tcp:shutdown(Tcp, write),
            ?assertEqual({error, closed}, gen_tcp:recv(Tcp, 0, 5000)),
            ok = gen_tcp:close(Tcp),
            ?assertEqual({proxy_protocol, closed}, await_accept_error())
        end,
        [~"PROXY TCP4 192.168", <<?V2_SIG, 16#21>>]
    ),
    ok = wait_for_active_clients(0).

garbage_after_header_fails_handshake(_Config) ->
    %% A good header followed by plain HTTP instead of a ClientHello: the
    %% upgrade fails and is reported like any other failed handshake.
    Port = start_listener(#{}),
    {ok, Tcp} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Tcp, [
        v2(16#21, 16#11, <<203, 0, 113, 9, 10, 0, 0, 1, 5000:16, 443:16>>),
        ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
    ]),
    receive
        {accept_error, Meta} ->
            ?assertEqual(?MODULE, maps:get(listener_name, Meta)),
            ?assertMatch({handshake, _}, maps:get(reason, Meta))
    after 5000 ->
        error(no_handshake_accept_error)
    end,
    ok = gen_tcp:close(Tcp),
    ok = wait_for_active_clients(0).

silence_after_header_times_out(_Config) ->
    %% Header, then nothing: `tls_handshake_timeout` cuts the upgrade off,
    %% the peer sees the socket go away, and nothing was ever accepted.
    Port = start_listener(#{tls_handshake_timeout => 200}),
    {ok, Tcp} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Tcp, ~"PROXY TCP4 192.168.0.7 10.0.0.1 5000 443\r\n"),
    receive
        {accept_error, Meta} ->
            ?assertEqual({handshake, timeout}, maps:get(reason, Meta))
    after 5000 ->
        error(no_handshake_timeout)
    end,
    ?assertEqual({error, closed}, gen_tcp:recv(Tcp, 0, 5000)),
    ok = gen_tcp:close(Tcp),
    ok = wait_for_active_clients(0),
    receive
        {accept, _} -> error(accept_fired_for_unhandshaken_peer)
    after 0 -> ok
    end.

%% --- helpers ---

%% The reason of the next accept_error the per-case telemetry handler forwards.
await_accept_error() ->
    receive
        {accept_error, #{reason := Reason}} -> Reason
    after 5000 -> error(no_accept_error)
    end.

start_listener(Extra) ->
    {ok, _} = roadrunner_listener:start_link(
        ?MODULE,
        Extra#{
            port => 0,
            tls => roadrunner_test_certs:server_opts(),
            proxy_protocol => true,
            routes => roadrunner_proxy_peer_handler
        }
    ),
    roadrunner_listener:port(?MODULE).

client_opts() ->
    [{verify, verify_none} | roadrunner_test_certs:client_opts()] ++ [binary, {active, false}].

%% Send the header pieces on a plain socket, upgrade it to TLS, and ask the
%% peer-echo handler which client address the server saw.
peer_through(Port, HeaderPieces) ->
    {ok, Tcp} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    lists:foreach(fun(Piece) -> ok = gen_tcp:send(Tcp, Piece) end, HeaderPieces),
    {ok, Tls} = ssl:connect(Tcp, client_opts(), 5000),
    ok = ssl:send(Tls, ~"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"),
    Reply = recv_until_closed(Tls, <<>>),
    ok = ssl:close(Tls),
    [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
    Body.

%% The peer handler answers with `connection: close`, so read to EOF.
recv_until_closed(Tls, Acc) ->
    case ssl:recv(Tls, 0, 5000) of
        {ok, Data} -> recv_until_closed(Tls, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

%% A v2 header: signature, version/command byte, family/transport byte, the
%% address block's length and the block itself.
v2(VerCmd, FamTrans, Body) ->
    <<?V2_SIG, VerCmd, FamTrans, (byte_size(Body)):16, Body/binary>>.

%% Slot release happens after the telemetry event or the close the peer
%% observes, so poll the counter until it settles.
wait_for_active_clients(N) ->
    wait_for_active_clients(N, erlang:monotonic_time(millisecond) + 5000).

wait_for_active_clients(N, Deadline) ->
    case roadrunner_listener:info(?MODULE) of
        #{active_clients := N} ->
            ok;
        #{active_clients := Other} ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    timer:sleep(10),
                    wait_for_active_clients(N, Deadline);
                false ->
                    error({active_clients, Other, expected, N})
            end
    end.
