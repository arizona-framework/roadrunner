-module(roadrunner_send_timeout_SUITE).
-moduledoc """
Listener `send_timeout` and `max_unsent_bytes`: a client that requests a
large response and reads none of it has its connection closed once a send
has waited `send_timeout`, for a buffered, a streamed and a `sendfile`
body, while a client that reads gets the whole body, even one that reads
a large write more slowly than `send_timeout` allows for all of it.
""".
-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    buffered_response_to_non_reader_closes/1,
    streamed_response_to_non_reader_closes/1,
    slow_steady_reader_is_not_closed/1,
    sendfile_response_to_non_reader_closes/1,
    reader_gets_whole_body/1,
    limits_off_still_serve/1,
    invalid_values_refuse_to_start/1,
    socket_options_per_os/1,
    sliced_writes_arrive_whole_on_tcp/1,
    sliced_writes_arrive_whole_on_tls/1,
    kernel_timeout_writes_are_not_sliced/1,
    emulator_timeout_closes_non_reader/1,
    pre_fix_linux_closes_non_reader/1,
    tls_send_timeout_slices_sends/1
]).

%% Far larger than what the kernel queues for one connection with a
%% client receive buffer of 4 KB and `max_unsent_bytes` at its default.
-define(SIZE, 16 * 1024 * 1024).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        buffered_response_to_non_reader_closes,
        streamed_response_to_non_reader_closes,
        slow_steady_reader_is_not_closed,
        sendfile_response_to_non_reader_closes,
        reader_gets_whole_body,
        limits_off_still_serve,
        invalid_values_refuse_to_start,
        socket_options_per_os,
        sliced_writes_arrive_whole_on_tcp,
        sliced_writes_arrive_whole_on_tls,
        kernel_timeout_writes_are_not_sliced,
        emulator_timeout_closes_non_reader,
        pre_fix_linux_closes_non_reader,
        tls_send_timeout_slices_sends
    ].

init_per_testcase(_Case, Config) ->
    File = filename:join(?config(priv_dir, Config), "large.bin"),
    ok = file:write_file(File, binary:copy(~"y", ?SIZE)),
    [{file, File} | Config].

end_per_testcase(_Case, _Config) ->
    _ = persistent_term:erase({roadrunner_transport, slice_sends}),
    _ = persistent_term:erase({roadrunner_listener, listen_os}),
    case whereis(send_timeout_test) of
        undefined -> ok;
        _ -> roadrunner_listener:stop(send_timeout_test)
    end.

%% =============================================================================
%% Cases
%% =============================================================================

buffered_response_to_non_reader_closes(Config) ->
    %% A keep-alive request: without the timeout the connection would
    %% wait for the next request for `keep_alive_timeout` (60 s).
    non_reader_closes(Config, ~"/buffered").

streamed_response_to_non_reader_closes(Config) ->
    %% The last chunk waits behind the unread body.
    non_reader_closes(Config, ~"/stream").

slow_steady_reader_is_not_closed(Config) ->
    %% Reading the 16 MB body takes far longer than `send_timeout`, but
    %% the client never stops taking bytes, so the last chunk, written
    %% after the whole body, still goes out.
    Port = start(Config, #{send_timeout => 300}),
    {ok, Sock} = request(Port, ~"/stream", [{recbuf, 16384}], ~"Connection: close\r\n"),
    Body = read_paced(Sock, <<>>, []),
    ?assertMatch(<<_:(?SIZE)/binary, "\r\n3\r\nend\r\n0\r\n\r\n">>, chunk_tail(Body)),
    ok = gen_tcp:close(Sock).

sendfile_response_to_non_reader_closes(Config) ->
    %% The emulator's `send_timeout` does not cover `sendfile`; the
    %% kernel's `TCP_USER_TIMEOUT` does, on a Linux that closes a client
    %% that stops reading with it.
    case roadrunner_listener:send_opts(#{}, os:type(), os:version()) of
        [{raw, 6, 18, _}, {raw, 6, 25, _}] -> non_reader_closes(Config, ~"/sendfile");
        _ -> {skip, no_tcp_user_timeout}
    end.

reader_gets_whole_body(Config) ->
    %% A client that reads at full speed is never closed for it.
    Port = start(Config, #{send_timeout => 200}),
    lists:foreach(
        fun(Path) ->
            {ok, Sock} = request(Port, Path, [], ~"Connection: close\r\n"),
            ?assertEqual(?SIZE, read_body(Sock)),
            ok = gen_tcp:close(Sock)
        end,
        [~"/buffered", ~"/sendfile"]
    ).

limits_off_still_serve(Config) ->
    Port = start(Config, #{send_timeout => infinity, max_unsent_bytes => infinity}),
    {ok, Sock} = request(Port, ~"/sendfile", [], ~"Connection: close\r\n"),
    ?assertEqual(?SIZE, read_body(Sock)),
    ok = gen_tcp:close(Sock).

invalid_values_refuse_to_start(_Config) ->
    process_flag(trap_exit, true),
    lists:foreach(
        fun({Key, Value}) ->
            R = roadrunner_listener:start_link(send_timeout_invalid, #{
                port => 0, Key => Value, routes => roadrunner_hello_handler
            }),
            ?assertMatch({error, {{invalid_listener_opt, Key, Value}, _Stack}}, R)
        end,
        [
            {send_timeout, 0},
            {send_timeout, 16#80000000},
            {send_timeout, soon},
            {max_unsent_bytes, 0},
            {max_unsent_bytes, 16#80000000},
            {max_unsent_bytes, lots}
        ]
    ).

socket_options_per_os(_Config) ->
    %% The kernel enforces `send_timeout` on a Linux whose
    %% `TCP_USER_TIMEOUT` closes a client that stops reading, the emulator
    %% as well on an older or unknown Linux, and alone elsewhere.
    Opts = #{send_timeout => 1000, max_unsent_bytes => 4096},
    Kernel = [{raw, 6, 18, <<1000:32/native>>}, {raw, 6, 25, <<4096:32/native>>}],
    Both = [
        {raw, 6, 18, <<1000:32/native>>},
        {send_timeout, 1000},
        {send_timeout_close, true},
        {raw, 6, 25, <<4096:32/native>>}
    ],
    lists:foreach(
        fun({Version, Want}) ->
            ?assertEqual(
                {Version, Want},
                {Version, roadrunner_listener:send_opts(Opts, {unix, linux}, Version)}
            )
        end,
        [
            {{7, 0, 11}, Kernel},
            {{5, 11, 0}, Kernel},
            {{5, 10, 11}, Kernel},
            {{5, 10, 10}, Both},
            {{5, 4, 93}, Kernel},
            {{5, 4, 0}, Both},
            {{4, 18, 0}, Both},
            {"5.15.0-custom", Both}
        ]
    ),
    ?assertEqual(
        [{send_timeout, 1000}, {send_timeout_close, true}, {raw, 6, 16#201, <<4096:32/native>>}],
        roadrunner_listener:send_opts(Opts, {unix, darwin}, {24, 1, 0})
    ),
    ?assertEqual(
        [{send_timeout, 1000}, {send_timeout_close, true}],
        roadrunner_listener:send_opts(Opts, {win32, nt}, {10, 0, 19045})
    ),
    ?assertEqual(
        [{raw, 6, 18, <<60000:32/native>>}, {raw, 6, 25, <<65536:32/native>>}],
        roadrunner_listener:send_opts(#{}, {unix, linux}, {6, 1, 0})
    ),
    ?assertEqual(
        [],
        roadrunner_listener:send_opts(
            #{send_timeout => infinity, max_unsent_bytes => infinity}, {unix, linux}, {5, 4, 0}
        )
    ).

sliced_writes_arrive_whole_on_tcp(_Config) ->
    %% Where the emulator's `send_timeout` is in use, writes over 256 KB
    %% go out in slices; the client gets every byte in order, whatever the
    %% shape of the iolist, and a write on a closed socket fails on its
    %% first slice.
    ok = roadrunner_transport:slice_sends(
        roadrunner_listener:send_opts(#{}, {unix, darwin}, {24, 1, 0})
    ),
    {Sends, Closed} = tcp_writes(),
    ?assertEqual([], [N || N <- Sends, N < 2]),
    ?assertEqual({error, closed}, Closed).

sliced_writes_arrive_whole_on_tls(_Config) ->
    ok = roadrunner_transport:slice_sends(
        roadrunner_listener:send_opts(#{}, {unix, linux}, {5, 4, 0})
    ),
    tls_writes().

kernel_timeout_writes_are_not_sliced(_Config) ->
    %% The kernel's `TCP_USER_TIMEOUT` alone (and no timeout at all) leaves
    %% each write whole: one send, whatever its size.
    ok = roadrunner_transport:slice_sends(
        roadrunner_listener:send_opts(#{}, {unix, linux}, {5, 11, 0})
    ),
    ok = roadrunner_transport:slice_sends(
        roadrunner_listener:send_opts(#{send_timeout => infinity}, {unix, darwin}, {24, 1, 0})
    ),
    {Sends, Closed} = tcp_writes(),
    ?assertEqual([1, 1, 1], Sends),
    ?assertEqual({error, closed}, Closed),
    tls_writes().

emulator_timeout_closes_non_reader(Config) ->
    %% Where only the emulator enforces it (a system without
    %% `TCP_USER_TIMEOUT`), a client that reads nothing is still closed,
    %% for a buffered and a streamed body, and large sends are sliced.
    ok = persistent_term:put({roadrunner_listener, listen_os}, {{win32, nt}, {10, 0, 19045}}),
    non_reader_closes(Config, ~"/buffered"),
    ?assert(persistent_term:get({roadrunner_transport, slice_sends}, false)),
    ok = roadrunner_listener:stop(send_timeout_test),
    non_reader_closes(Config, ~"/stream").

pre_fix_linux_closes_non_reader(Config) ->
    %% A Linux whose `TCP_USER_TIMEOUT` does not close a client that stops
    %% reading has the emulator's timeout as well, which closes it. The
    %% kernel running this test closes that client by itself, so the close
    %% cannot tell the two apart: the accepted socket must carry the
    %% emulator's `send_timeout`.
    ok = persistent_term:put({roadrunner_listener, listen_os}, {{unix, linux}, {5, 4, 0}}),
    non_reader_closes(Config, ~"/buffered", fun(Conn) ->
        [Socket] = [
            Port
         || Port <- erlang:ports(),
            erlang:port_info(Port, connected) =:= {connected, Conn},
            erlang:port_info(Port, name) =:= {name, "tcp_inet"}
        ],
        ?assertEqual(
            {ok, [{send_timeout, 200}, {send_timeout_close, true}]},
            inet:getopts(Socket, [send_timeout, send_timeout_close])
        )
    end),
    ?assert(persistent_term:get({roadrunner_transport, slice_sends}, false)).

tls_send_timeout_slices_sends(_Config) ->
    %% A `send_timeout` among the listener's `tls` options is the
    %% emulator's own, so it turns on sliced sends like the listener's.
    {ok, _} = application:ensure_all_started(ssl),
    ok = persistent_term:put({roadrunner_listener, listen_os}, {{unix, linux}, {6, 1, 0}}),
    {ok, _} = roadrunner_listener:start_link(send_timeout_test, #{
        port => 0,
        tls => [{send_timeout, 30000} | roadrunner_test_certs:server_opts()],
        routes => roadrunner_hello_handler
    }),
    ?assert(persistent_term:get({roadrunner_transport, slice_sends}, false)).

%% Each of `sliced_data/0` written with `roadrunner_transport:send/2` on a
%% TCP socket: how many `gen_tcp:send/2` calls each took, and the result
%% of a write once the socket is closed.
tcp_writes() ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}]),
    {ok, Port} = inet:port(L),
    {ok, C} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    {ok, S} = gen_tcp:accept(L),
    1 = erlang:trace_pattern({gen_tcp, send, 2}, true, []),
    Sends = lists:map(
        fun(Data) ->
            Tracer = spawn_link(fun() -> count_traced_sends(0) end),
            1 = erlang:trace(self(), true, [call, {tracer, Tracer}]),
            ok = roadrunner_transport:send({gen_tcp, S}, Data),
            1 = erlang:trace(self(), false, [call]),
            Want = iolist_to_binary(Data),
            ?assertEqual({ok, Want}, gen_tcp:recv(C, byte_size(Want), 5000)),
            Ref = erlang:trace_delivered(self()),
            receive
                {trace_delivered, _, Ref} -> ok
            end,
            Tracer ! {count, self()},
            receive
                {sends, Tracer, N} -> N
            end
        end,
        sliced_data()
    ),
    1 = erlang:trace_pattern({gen_tcp, send, 2}, false, []),
    ok = gen_tcp:close(C),
    ok = gen_tcp:close(S),
    Closed = roadrunner_transport:send({gen_tcp, S}, hd(sliced_data())),
    ok = gen_tcp:close(L),
    {Sends, Closed}.

%% A tracer (a process does not get its own trace messages) counting the
%% `gen_tcp:send/2` calls it is told of until asked for the count.
count_traced_sends(N) ->
    receive
        {trace, _Pid, call, {gen_tcp, send, [_, _]}} -> count_traced_sends(N + 1);
        {count, From} -> From ! {sends, self(), N}
    end.

tls_writes() ->
    {ok, _} = application:ensure_all_started(ssl),
    {ok, L} = ssl:listen(
        0, roadrunner_test_certs:server_opts() ++ [binary, {active, false}, {reuseaddr, true}]
    ),
    {ok, {_, Port}} = ssl:sockname(L),
    Test = self(),
    _ = spawn_link(fun() ->
        {ok, Pre} = ssl:transport_accept(L),
        {ok, S} = ssl:handshake(Pre),
        [ok = roadrunner_transport:send({ssl, S}, Data) || Data <- sliced_data()],
        Test ! sent,
        receive
            stop -> ssl:close(S)
        end
    end),
    {ok, C} = ssl:connect(
        {127, 0, 0, 1},
        Port,
        [{verify, verify_none} | roadrunner_test_certs:client_opts()] ++ [binary, {active, false}],
        5000
    ),
    Want = iolist_to_binary(sliced_data()),
    ?assertEqual({ok, Want}, ssl:recv(C, byte_size(Want), 5000)),
    ok = ssl:close(C),
    ok = ssl:close(L).

%% =============================================================================
%% Helpers

%% iolists over one 256 KB slice: binaries split across slices, bytes,
%% nested and empty lists, an improper tail, and exactly two slices.
sliced_data() ->
    [
        [1, 2, [~"ab", []], binary:copy(~"y", 300000), [[3 | ~"tail"]], binary:copy(~"z", 250000)],
        binary:copy(~"w", 2 * 262144),
        [binary:copy(~"v", 262143), 4, 5 | ~"end"]
    ].
%% =============================================================================

%% The client asks for a large body with a small receive buffer and reads
%% none of it; the process serving it ends once a send has waited the
%% timeout.
non_reader_closes(Config, Path) ->
    non_reader_closes(Config, Path, fun(_Conn) -> ok end).

%% `Check` runs on the process serving the request before it closes.
non_reader_closes(Config, Path, Check) ->
    Port = start(Config, #{send_timeout => 200}),
    {ok, Sock} = request(Port, Path, [{recbuf, 4096}], ~""),
    Conn =
        receive
            {roadrunner_slow_reader_handler, Pid} -> Pid
        end,
    _ = Check(Conn),
    Ref = monitor(process, Conn),
    receive
        {'DOWN', Ref, process, Conn, _Reason} -> ok
    end,
    ok = gen_tcp:close(Sock).

start(Config, Extra) ->
    {ok, _} = roadrunner_listener:start_link(send_timeout_test, Extra#{
        port => 0,
        routes => [
            #{
                path => ~"/:what",
                handler => roadrunner_slow_reader_handler,
                state => #{test => self(), file => ?config(file, Config), size => ?SIZE}
            }
        ]
    }),
    roadrunner_listener:port(send_timeout_test).

request(Port, Path, SockOpts, Extra) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false} | SockOpts], 1000
    ),
    ok = gen_tcp:send(Sock, [~"GET ", Path, ~" HTTP/1.1\r\nHost: x\r\n", Extra, ~"\r\n"]),
    {ok, Sock}.

%% Everything until the server closes, read 16 KB at a time with a pause
%% of 2 ms between reads: about 8 MB/s, so the body takes over a second.
read_paced(Sock, Head, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} ->
            receive
            after 2 -> ok
            end,
            read_paced(Sock, Head, [Acc | Data]);
        {error, closed} ->
            iolist_to_binary([Head | Acc])
    end.

%% The chunked body after the head and the first chunk-size line.
chunk_tail(Response) ->
    [_Head, Body] = binary:split(Response, ~"\r\n\r\n"),
    [_Size, Rest] = binary:split(Body, ~"\r\n"),
    Rest.

%% The body bytes read until the server closes.
read_body(Sock) ->
    {ok, Head} = recv_head(Sock, <<>>),
    [_, Body] = binary:split(Head, ~"\r\n\r\n"),
    read_rest(Sock, byte_size(Body)).

recv_head(Sock, Acc) ->
    {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
    Buf = <<Acc/binary, Data/binary>>,
    case binary:match(Buf, ~"\r\n\r\n") of
        nomatch -> recv_head(Sock, Buf);
        _ -> {ok, Buf}
    end.

read_rest(Sock, Got) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> read_rest(Sock, Got + byte_size(Data));
        {error, closed} -> Got
    end.
