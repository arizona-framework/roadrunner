-module(roadrunner_ws_opts_SUITE).
-moduledoc """
Per-upgrade WebSocket options (`t:roadrunner_ws_handler:upgrade_opts/0`)
and the listener `ws` options they fall back to: compression, the idle
timeout, size caps and the session process's GC settings. The handler is
`roadrunner_ws_opts_handler`; each route's state carries the options.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    compress_by_default/1,
    upgrade_declines_compression/1,
    listener_declines_compression/1,
    idle_session_closes/1,
    traffic_keeps_session_open/1,
    listener_idle_timeout/1,
    tls_idle_session_closes/1,
    tls_echo_past_active_window/1,
    tcp_echo_past_active_window/1,
    tls_closed_before_arm_exits_cleanly/1,
    upgrade_frame_cap/1,
    upgrade_gc_settings/1,
    default_session_min_heap/1,
    every_option_accepted/1
]).

-define(H, roadrunner_ws_opts_handler).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        compress_by_default,
        upgrade_declines_compression,
        listener_declines_compression,
        idle_session_closes,
        traffic_keeps_session_open,
        listener_idle_timeout,
        tls_idle_session_closes,
        tls_echo_past_active_window,
        tcp_echo_past_active_window,
        tls_closed_before_arm_exits_cleanly,
        upgrade_frame_cap,
        upgrade_gc_settings,
        default_session_min_heap,
        every_option_accepted
    ].

init_per_testcase(Case, Config) ->
    {ok, _} = roadrunner_listener:start_link(
        ?MODULE,
        maps:merge(listener_tls(Case), #{
            port => 0,
            ws => listener_ws(Case),
            routes => [{~"/ws", ?H, #{report => self(), opts => upgrade_opts(Case)}}]
        })
    ),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_listener:stop(?MODULE).

listener_tls(Case) when
    Case =:= tls_idle_session_closes;
    Case =:= tls_echo_past_active_window;
    Case =:= tls_closed_before_arm_exits_cleanly
->
    {ok, _} = application:ensure_all_started(ssl),
    #{tls => roadrunner_test_certs:server_opts()};
listener_tls(_Case) ->
    #{}.

listener_ws(listener_declines_compression) -> #{compress => false};
listener_ws(listener_idle_timeout) -> #{idle_timeout => 100};
listener_ws(_Case) -> #{}.

upgrade_opts(upgrade_declines_compression) ->
    #{compress => false};
upgrade_opts(Case) when
    Case =:= idle_session_closes;
    Case =:= traffic_keeps_session_open;
    Case =:= tls_idle_session_closes
->
    #{idle_timeout => 100};
upgrade_opts(tcp_echo_past_active_window) ->
    #{active => 4};
upgrade_opts(upgrade_frame_cap) ->
    #{max_frame_size => 4};
upgrade_opts(upgrade_gc_settings) ->
    #{fullsweep_after => 7, min_heap_size => 987, max_heap_size => 1000000};
upgrade_opts(every_option_accepted) ->
    #{
        headers => [{~"x-session", ~"1"}],
        compress => false,
        idle_timeout => 60000,
        max_frame_size => 1024,
        max_message_size => 4096,
        recv_buffer => 2048,
        hibernate_after => 60000,
        active => once,
        fullsweep_after => 10,
        max_heap_size => 1000000
    };
upgrade_opts(_Case) ->
    #{}.

%% =============================================================================
%% Compression
%% =============================================================================

compress_by_default(Config) ->
    {_Sock, Head, _Pid} = upgrade(Config, deflate_offer()),
    ?assertNotEqual(nomatch, binary:match(Head, ~"sec-websocket-extensions: permessage-deflate")).

upgrade_declines_compression(Config) ->
    {_Sock, Head, _Pid} = upgrade(Config, deflate_offer()),
    ?assertEqual(nomatch, binary:match(Head, ~"sec-websocket-extensions")).

listener_declines_compression(Config) ->
    {_Sock, Head, _Pid} = upgrade(Config, deflate_offer()),
    ?assertEqual(nomatch, binary:match(Head, ~"sec-websocket-extensions")).

%% =============================================================================
%% Idle timeout
%% =============================================================================

idle_session_closes(Config) ->
    %% Nothing from the client: a 1001 close within two intervals.
    {Sock, _Head, _Pid} = upgrade(Config, []),
    ?assertEqual(<<16#88, 2, 1001:16>>, recv_frame(Sock, 1000)),
    ?assertEqual({terminated, timeout}, terminated()).

traffic_keeps_session_open(Config) ->
    %% Five echoes 60 ms apart span three 100 ms intervals; each one is
    %% answered, then the silence after them closes the session.
    {Sock, _Head, _Pid} = upgrade(Config, []),
    ok = lists:foreach(
        fun(_) ->
            receive
            after 60 -> ok
            end,
            ok = gen_tcp:send(Sock, masked(16#81, ~"hi")),
            ?assertEqual(<<16#81, 2, "hi">>, recv_frame(Sock, 1000))
        end,
        lists:seq(1, 5)
    ),
    ?assertEqual(<<16#88, 2, 1001:16>>, recv_frame(Sock, 1000)),
    ?assertEqual({terminated, timeout}, terminated()).

listener_idle_timeout(Config) ->
    {Sock, _Head, _Pid} = upgrade(Config, []),
    ?assertEqual(<<16#88, 2, 1001:16>>, recv_frame(Sock, 1000)).

tls_idle_session_closes(Config) ->
    %% Over TLS the idle check reads the TLS socket's byte count.
    {ok, Sock} = ssl:connect(
        {127, 0, 0, 1},
        ?config(port, Config),
        [binary, {active, false}, {verify, verify_none}],
        5000
    ),
    ok = ssl:send(Sock, upgrade_request([])),
    {ok, Bytes} = ssl:recv(Sock, 0, 5000),
    ?assertMatch(<<"HTTP/1.1 101", _/binary>>, Bytes),
    _ = session(),
    ?assertEqual({terminated, timeout}, terminated()).

tls_echo_past_active_window(Config) ->
    %% A TLS session reads with `{active, N}`; more echoes than one arm
    %% allows make ssl report the socket passive, and the session re-arms
    %% it and keeps answering.
    {ok, Sock} = ssl:connect(
        {127, 0, 0, 1},
        ?config(port, Config),
        [binary, {active, false}, {verify, verify_none}],
        5000
    ),
    ok = ssl:send(Sock, upgrade_request([])),
    {ok, Bytes} = ssl:recv(Sock, 0, 5000),
    ?assertMatch(<<"HTTP/1.1 101", _/binary>>, Bytes),
    ok = lists:foreach(
        fun(_) ->
            ok = ssl:send(Sock, masked(16#81, ~"hi")),
            ?assertEqual({ok, <<16#81, 2, "hi">>}, ssl:recv(Sock, 4, 1000))
        end,
        lists:seq(1, 20)
    ).

tls_closed_before_arm_exits_cleanly(_Config) ->
    %% A TLS socket that is already closed when the session arms it for
    %% `{active, N}` ends the session normally instead of crashing it.
    {ok, LSock} = ssl:listen(0, [binary, {active, false} | roadrunner_test_certs:server_opts()]),
    {ok, {_, Port}} = ssl:sockname(LSock),
    Client = spawn_link(fun() ->
        {ok, _} = ssl:connect(
            {127, 0, 0, 1}, Port, [binary, {active, false}, {verify, verify_none}], 5000
        ),
        receive
            stop -> ok
        end
    end),
    {ok, Accepted} = ssl:transport_accept(LSock, 5000),
    {ok, Sock} = ssl:handshake(Accepted, 5000),
    ok = ssl:close(Sock),
    ProtoOpts = #{
        ws_max_frame_size => 1024,
        ws_max_message_size => 1024,
        ws_hibernate_after => infinity,
        ws_idle_timeout => infinity,
        ws_active => undefined,
        handler_spawn_opts => []
    },
    {module, _} = code:ensure_loaded(roadrunner_ws_echo_handler),
    {Pid, Ref} = spawn_monitor(fun() ->
        roadrunner_ws_session:serve(
            fun() -> exit(normal) end,
            {
                {ssl, Sock},
                roadrunner_ws_echo_handler,
                undefined,
                {?MODULE, undefined},
                none,
                <<>>,
                ProtoOpts
            }
        )
    end),
    receive
        {'DOWN', Ref, process, Pid, Reason} -> ?assertEqual(normal, Reason)
    after 5000 -> ct:fail(session_still_running)
    end,
    Client ! stop,
    ok = ssl:close(LSock).

tcp_echo_past_active_window(Config) ->
    %% An upgrade reading with `{active, 4}`: more echoes than one arm
    %% allows make the socket passive, and the session re-arms it and
    %% keeps answering.
    {Sock, _Head, _Pid} = upgrade(Config, []),
    ok = lists:foreach(
        fun(_) ->
            ok = gen_tcp:send(Sock, masked(16#81, ~"hi")),
            ?assertEqual(<<16#81, 2, "hi">>, recv_frame(Sock, 1000))
        end,
        lists:seq(1, 10)
    ).

%% =============================================================================
%% Size caps and process settings
%% =============================================================================

upgrade_frame_cap(Config) ->
    {Sock, _Head, _Pid} = upgrade(Config, []),
    ok = gen_tcp:send(Sock, masked(16#81, ~"hello")),
    ?assertEqual(<<16#88, 2, 1009:16>>, recv_frame(Sock, 1000)),
    ?assertEqual({terminated, {error, max_frame_size}}, terminated()).

upgrade_gc_settings(Config) ->
    {_Sock, _Head, Pid} = upgrade(Config, []),
    ?assertEqual(
        7, proplists:get_value(fullsweep_after, element(2, process_info(Pid, garbage_collection)))
    ),
    ?assertMatch({max_heap_size, #{size := 1000000}}, process_info(Pid, max_heap_size)),
    ?assertMatch({min_heap_size, 987}, process_info(Pid, min_heap_size)).

default_session_min_heap(Config) ->
    %% No `min_heap_size` from the upgrade or the listener: the session
    %% takes its own 610-word minimum.
    {_Sock, _Head, Pid} = upgrade(Config, []),
    ?assertMatch({min_heap_size, 610}, process_info(Pid, min_heap_size)).

every_option_accepted(Config) ->
    {Sock, Head, _Pid} = upgrade(Config, deflate_offer()),
    ?assertNotEqual(nomatch, binary:match(Head, ~"x-session: 1")),
    ?assertEqual(nomatch, binary:match(Head, ~"sec-websocket-extensions")),
    ok = gen_tcp:send(Sock, masked(16#81, ~"hi")),
    ?assertEqual(<<16#81, 2, "hi">>, recv_frame(Sock, 1000)).

%% =============================================================================
%% Helpers
%% =============================================================================

deflate_offer() ->
    [~"Sec-WebSocket-Extensions: permessage-deflate\r\n"].

%% Upgrade and return the socket, the 101's head and the session pid.
upgrade(Config, Extra) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 5000
    ),
    ok = gen_tcp:send(Sock, upgrade_request(Extra)),
    Head = recv_head(Sock, <<>>),
    ?assertMatch(<<"HTTP/1.1 101", _/binary>>, Head),
    {Sock, Head, session()}.

upgrade_request(Extra) ->
    [
        ~"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
        ~"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n",
        Extra,
        ~"\r\n"
    ].

recv_head(Sock, Acc) ->
    case binary:match(Acc, ~"\r\n\r\n") of
        nomatch ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            recv_head(Sock, <<Acc/binary, Data/binary>>);
        _ ->
            Acc
    end.

session() ->
    receive
        {session, Pid} -> Pid
    after 5000 -> ct:fail(no_session)
    end.

terminated() ->
    receive
        {terminated, _} = Msg -> Msg
    after 5000 -> ct:fail(no_terminate)
    end.

%% One unmasked server frame with a payload under 126 bytes.
recv_frame(Sock, Timeout) ->
    {ok, <<Op, Len>>} = gen_tcp:recv(Sock, 2, Timeout),
    {ok, Payload} = gen_tcp:recv(Sock, Len, Timeout),
    <<Op, Len, Payload/binary>>.

masked(OpByte, Payload) ->
    Key = <<1, 2, 3, 4>>,
    KeyBin = binary:copy(Key, (byte_size(Payload) div 4) + 1),
    <<KeySlice:(byte_size(Payload))/binary, _/binary>> = KeyBin,
    <<OpByte, (16#80 bor byte_size(Payload)), Key/binary, (crypto:exor(Payload, KeySlice))/binary>>.
