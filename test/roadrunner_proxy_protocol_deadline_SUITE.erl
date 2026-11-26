-module(roadrunner_proxy_protocol_deadline_SUITE).
-moduledoc """
How long a PROXY protocol header may take to arrive.

The header gets one deadline for all of its reads: `request_timeout` on
plain TCP, `tls_handshake_timeout` on a TLS listener. On plain TCP its
bytes also count toward `min_bytes_per_second`, like the request head that
follows. A peer that sends the header a few bytes at a time is closed by
one or the other, and the close is reported as a `listener_accept_error`
with a `{proxy_protocol, Reason}` reason.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    tcp_v1_trickle_hits_the_deadline/1,
    tcp_v2_trickle_hits_the_deadline/1,
    tcp_v1_trickle_below_rate_is_closed/1,
    tcp_v2_trickle_below_rate_is_closed/1,
    tcp_header_gone_silent_is_closed_at_the_rate/1,
    tcp_whole_header_passes_the_rate/1,
    tcp_header_split_inside_the_grace_passes/1,
    tls_split_header_shares_one_deadline/1,
    tcp_drain_closes_a_header_on_its_way/1,
    tcp_drain_closes_a_conn_before_its_header/1,
    tcp_header_wait_never_wakes/1,
    tcp_peer_gone_before_its_header/1,
    tcp_transport_error_before_its_header/1,
    tcp_stray_message_before_its_header/1
]).

-define(V2_SIG, 16#0D, 16#0A, 16#0D, 16#0A, 16#00, 16#0D, 16#0A, 16#51, 16#55, 16#49, 16#54, 16#0A).
-define(V1, ~"PROXY TCP4 192.168.0.7 10.0.0.1 5000 443\r\n").

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        tcp_v1_trickle_hits_the_deadline,
        tcp_v2_trickle_hits_the_deadline,
        tcp_v1_trickle_below_rate_is_closed,
        tcp_v2_trickle_below_rate_is_closed,
        tcp_header_gone_silent_is_closed_at_the_rate,
        tcp_whole_header_passes_the_rate,
        tcp_header_split_inside_the_grace_passes,
        tls_split_header_shares_one_deadline,
        tcp_drain_closes_a_header_on_its_way,
        tcp_drain_closes_a_conn_before_its_header,
        tcp_header_wait_never_wakes,
        tcp_peer_gone_before_its_header,
        tcp_transport_error_before_its_header,
        tcp_stray_message_before_its_header
    ].

init_per_testcase(Case, Config) ->
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = roadrunner_test_event_handler:start(),
    Self = self(),
    HandlerId = {?MODULE, Case},
    ok = telemetry:attach(
        HandlerId,
        [roadrunner, listener, accept_error],
        fun(_Event, _Measure, Meta, _Cfg) -> Self ! {accept_error, Meta} end,
        undefined
    ),
    [{handler_id, HandlerId} | Config].

end_per_testcase(_Case, Config) ->
    ok = telemetry:detach(?config(handler_id, Config)),
    %% A drain case leaves no listener to stop.
    case whereis(?MODULE) of
        undefined -> ok;
        _Listener -> roadrunner_listener:stop(?MODULE)
    end.

tcp_v1_trickle_hits_the_deadline(_Config) ->
    %% One byte every 50 ms would take about 2 s for the whole line. Each
    %% byte comes well inside `request_timeout`, so a per-read timeout never
    %% fires; the header's single deadline does, with the line unfinished.
    %% The rate check is off to isolate the deadline.
    Port = start_tcp_listener(#{request_timeout => 300, min_bytes_per_second => 0}),
    {ok, Tcp} = connect(Port),
    ?assertMatch({closed, Left} when Left > 0, trickle(Tcp, ?V1, 50)),
    ?assertEqual({proxy_protocol, timeout}, await_accept_error()).

tcp_v2_trickle_hits_the_deadline(_Config) ->
    Port = start_tcp_listener(#{request_timeout => 300, min_bytes_per_second => 0}),
    {ok, Tcp} = connect(Port),
    ?assertMatch({closed, Left} when Left > 0, trickle(Tcp, v2_tcp4(), 50)),
    ?assertEqual({proxy_protocol, timeout}, await_accept_error()).

tcp_v1_trickle_below_rate_is_closed(_Config) ->
    %% Far inside `request_timeout`, but two bytes past the 1 s grace are
    %% far below `min_bytes_per_second`: the second read closes it.
    Port = start_tcp_listener(#{request_timeout => 20000, min_bytes_per_second => 1000}),
    {ok, Tcp} = connect(Port),
    ?assertMatch({closed, Left} when Left > 0, trickle(Tcp, ?V1, 1100)),
    ?assertEqual({proxy_protocol, slow_client}, await_accept_error()).

tcp_v2_trickle_below_rate_is_closed(_Config) ->
    Port = start_tcp_listener(#{request_timeout => 20000, min_bytes_per_second => 1000}),
    {ok, Tcp} = connect(Port),
    ?assertMatch({closed, Left} when Left > 0, trickle(Tcp, v2_tcp4(), 1100)),
    ?assertEqual({proxy_protocol, slow_client}, await_accept_error()).

tcp_header_gone_silent_is_closed_at_the_rate(_Config) ->
    %% A header begun, then nothing: silence counts toward the rate, as it
    %% does for the request head, so the bytes so far fall below
    %% `min_bytes_per_second` once the 1 s grace is over and the connection
    %% is closed then, long before `request_timeout`.
    Port = start_tcp_listener(#{request_timeout => 20000, min_bytes_per_second => 100}),
    {ok, Tcp} = connect(Port),
    ok = gen_tcp:send(Tcp, ~"PROXY TCP4 "),
    ?assertEqual({error, closed}, gen_tcp:recv(Tcp, 0, 5000)),
    ?assertEqual({proxy_protocol, slow_client}, await_accept_error()).

tcp_whole_header_passes_the_rate(_Config) ->
    %% A header that arrives in one segment is measured at its own first
    %% byte, so even a steep minimum lets it through.
    Port = start_tcp_listener(#{min_bytes_per_second => 1000000}),
    ?assertEqual(~"192.168.0.7", peer_through(Port, [?V1])),
    ?assertEqual(~"203.0.113.9", peer_through(Port, [v2_tcp4()])).

tcp_header_split_inside_the_grace_passes(_Config) ->
    %% The window starts at the first byte and its first second is grace,
    %% so a balancer whose header spans two segments is not cut off.
    %% The two halves go out 200 ms apart, well inside the grace; the wait
    %% between them also shows the server has not closed the connection.
    Port = start_tcp_listener(#{min_bytes_per_second => 1000000}),
    <<First:20/binary, Second/binary>> = ?V1,
    {ok, Tcp} = connect(Port),
    ok = gen_tcp:send(Tcp, First),
    ?assertEqual({error, timeout}, gen_tcp:recv(Tcp, 0, 200)),
    ok = gen_tcp:send(Tcp, [Second, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"]),
    ?assertEqual(~"192.168.0.7", body_of(recv_until_closed(Tcp, <<>>))),
    ok = gen_tcp:close(Tcp).

tls_split_header_shares_one_deadline(_Config) ->
    %% A v2 header read in its three exact reads (6 bytes, 10 bytes, the
    %% address block), each piece 400 ms after the last. Every read alone
    %% finishes inside `tls_handshake_timeout`; together they do not, and
    %% the one deadline closes the connection before the address block. A
    %% connection that got through would fail the handshake instead, so the
    %% reported reason tells the two apart.
    {ok, _} = roadrunner_listener:start_link(?MODULE, #{
        port => 0,
        tls => roadrunner_test_certs:server_opts(),
        proxy_protocol => true,
        tls_handshake_timeout => 500,
        routes => roadrunner_proxy_peer_handler
    }),
    Port = roadrunner_listener:port(?MODULE),
    {ok, Tcp} = connect(Port),
    <<Sig:6/binary, Prefix:10/binary, Block/binary>> = v2_tcp4(),
    ?assertMatch({closed, _}, send_spaced(Tcp, [Sig, Prefix, Block], 400)),
    ?assertEqual({proxy_protocol, timeout}, await_accept_error()).

tcp_drain_closes_a_header_on_its_way(_Config) ->
    %% A peer that sent part of its header and went quiet does not hold up a
    %% graceful drain: the connection waits for the rest in `receive`, where
    %% it sees the drain at once, so the drain ends long before the header's
    %% deadline.
    Port = start_tcp_listener(#{request_timeout => 20000, min_bytes_per_second => 0}),
    ok = drain_while_waiting(Port, ~"PROXY TCP4 ").

tcp_drain_closes_a_conn_before_its_header(_Config) ->
    %% The same for a peer that has sent nothing yet.
    Port = start_tcp_listener(#{request_timeout => 20000}),
    ok = drain_while_waiting(Port, ~"").

tcp_header_wait_never_wakes(_Config) ->
    %% A connection waiting for its header, before any byte or with part of
    %% it in (no rate to keep), never wakes while it waits: over a second of
    %% silence nothing reaches it and its receive never times out.
    Port = start_tcp_listener(#{request_timeout => 20000, min_bytes_per_second => 0}),
    {ok, Idle} = connect(Port),
    ok = still_while_silent(Idle, ~""),
    {ok, Partial} = connect(Port),
    ok = gen_tcp:send(Partial, ~"PROXY TCP4 "),
    ok = still_while_silent(Partial, ~"PROXY TCP4 ").

tcp_peer_gone_before_its_header(_Config) ->
    Port = start_tcp_listener(#{}),
    {ok, Tcp} = connect(Port),
    _Conn = waiting_for_header(Tcp, ~""),
    ok = gen_tcp:close(Tcp),
    ?assertEqual({proxy_protocol, closed}, await_accept_error()).

tcp_transport_error_before_its_header(_Config) ->
    Port = start_tcp_listener(#{}),
    {ok, Tcp} = connect(Port),
    Conn = waiting_for_header(Tcp, ~""),
    Conn ! {tcp_error, Tcp, econnreset},
    ?assertEqual({proxy_protocol, econnreset}, await_accept_error()),
    ok = gen_tcp:close(Tcp).

tcp_stray_message_before_its_header(_Config) ->
    %% A message the wait does not know is dropped, and the header still
    %% comes through.
    Port = start_tcp_listener(#{}),
    {ok, Tcp} = connect(Port),
    Conn = waiting_for_header(Tcp, ~""),
    Conn ! stray,
    ok = gen_tcp:send(Tcp, [?V1, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"]),
    ?assertEqual(~"192.168.0.7", body_of(recv_until_closed(Tcp, <<>>))),
    ok = gen_tcp:close(Tcp).

%% --- helpers ---

%% Send part of a header, wait until the connection has taken it in and waits
%% for the rest, then drain: it returns `{ok, drained}` with the connection
%% closed, and no accept error is reported for the drain.
drain_while_waiting(Port, Part) ->
    {ok, Tcp} = connect(Port),
    ok = gen_tcp:send(Tcp, Part),
    _Conn = waiting_for_header(Tcp, Part),
    ?assertEqual({ok, drained}, roadrunner_listener:drain(?MODULE, 5000)),
    ?assertEqual({error, closed}, gen_tcp:recv(Tcp, 0, 1000)),
    receive
        {accept_error, Meta} -> ct:fail({accept_error, Meta})
    after 0 -> ok
    end.

%% The connection serving `Tcp`, once it waits for the rest of its PROXY
%% header with `Sent`, everything sent so far, taken in: its socket has read
%% those bytes, and the connection is back in its wait after that.
waiting_for_header(Tcp, Sent) ->
    {ok, Local} = inet:sockname(Tcp),
    waiting_for_header(Local, Sent, erlang:monotonic_time(millisecond) + 5000).

waiting_for_header(Local, Sent, Deadline) ->
    case [P || P <- processes(), waiting(P), serves(P, Local, Sent), waiting(P)] of
        [Conn] ->
            Conn;
        [] ->
            erlang:monotonic_time(millisecond) < Deadline orelse ct:fail(never_waiting),
            erlang:yield(),
            waiting_for_header(Local, Sent, Deadline)
    end.

%% Whether `Pid` waits for the bytes of a PROXY header, its mailbox empty.
waiting(Pid) ->
    erlang:process_info(Pid, [current_function, message_queue_len]) =:=
        [{current_function, {roadrunner_conn_loop, await_proxy_bytes, 6}}, {message_queue_len, 0}].

%% Whether `Pid` owns the server side of the connection whose client end
%% is at `Local`, which has read as many bytes as `Sent`.
serves(Pid, Local, Sent) ->
    lists:any(
        fun(Port) ->
            erlang:port_info(Port, connected) =:= {connected, Pid} andalso
                inet:peername(Port) =:= {ok, Local} andalso
                inet:getstat(Port, [recv_oct]) =:= {ok, [{recv_oct, byte_size(Sent)}]}
        end,
        erlang:ports()
    ).

%% The connection serving `Tcp` never wakes over a second in which the
%% client sends nothing: a trace of its `receive` catches no message and no
%% timeout. Its reductions would not tell, as the VM charges a process for
%% the housekeeping it does on it: a `persistent_term` value bigger than a
%% word, replaced or erased anywhere in the node, has every process scanned
%% for it, and the replacements here have the wait scanned too.
still_while_silent(Tcp, Sent) ->
    Conn = waiting_for_header(Tcp, Sent),
    1 = erlang:trace(Conn, true, ['receive']),
    ok = replace_persistent_term(20),
    ?assertEqual({error, timeout}, gen_tcp:recv(Tcp, 0, 1000)),
    1 = erlang:trace(Conn, false, ['receive']),
    ?assertEqual([], traced(Conn)),
    ok.

%% Replace a `persistent_term` value `N` times, then erase it.
replace_persistent_term(N) ->
    Key = {?MODULE, scanned},
    lists:foreach(fun(_) -> ok = persistent_term:put(Key, make_ref()) end, lists:seq(1, N)),
    true = persistent_term:erase(Key),
    ok.

%% What a trace of `Conn`'s `receive` caught, once all of it has arrived.
traced(Conn) ->
    Ref = erlang:trace_delivered(Conn),
    receive
        {trace_delivered, Conn, Ref} -> traced_messages(Conn)
    end.

traced_messages(Conn) ->
    receive
        {trace, Conn, 'receive', Msg} -> [Msg | traced_messages(Conn)]
    after 0 -> []
    end.

start_tcp_listener(Extra) ->
    {ok, _} = roadrunner_listener:start_link(
        ?MODULE,
        Extra#{
            port => 0,
            proxy_protocol => true,
            protocols => [http1],
            routes => roadrunner_proxy_peer_handler
        }
    ),
    roadrunner_listener:port(?MODULE).

connect(Port) ->
    gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000).

%% Send `Bin` one byte at a time, `Gap` ms apart, until the server closes
%% the connection (`{closed, BytesNotSent}`) or every byte is out.
trickle(Tcp, <<B, Rest/binary>> = Bin, Gap) ->
    case gen_tcp:send(Tcp, <<B>>) of
        ok ->
            case gen_tcp:recv(Tcp, 0, Gap) of
                {error, timeout} when Rest =/= <<>> ->
                    trickle(Tcp, Rest, Gap);
                {error, timeout} ->
                    ok = gen_tcp:close(Tcp),
                    all_sent;
                {error, Reason} when Reason =:= closed; Reason =:= econnreset ->
                    ok = gen_tcp:close(Tcp),
                    {closed, byte_size(Rest)}
            end;
        {error, Reason} when Reason =:= closed; Reason =:= econnreset ->
            ok = gen_tcp:close(Tcp),
            {closed, byte_size(Bin)}
    end.

%% Send each piece `Gap` ms after the last, the first at once, until the
%% server closes the connection (`{closed, PiecesNotSent}`). A close shows as
%% `closed`, or as `econnreset` when it caught bytes the server never read.
send_spaced(Tcp, [], _Gap) ->
    closed_after(Tcp, 5000, 0);
send_spaced(Tcp, [Piece | Rest] = Pieces, Gap) ->
    case gen_tcp:send(Tcp, Piece) of
        ok ->
            case gen_tcp:recv(Tcp, 0, Gap) of
                {error, timeout} -> send_spaced(Tcp, Rest, Gap);
                Other -> closed(Tcp, Other, length(Rest))
            end;
        {error, _} = Error ->
            closed(Tcp, Error, length(Pieces))
    end.

closed_after(Tcp, Wait, Left) ->
    closed(Tcp, gen_tcp:recv(Tcp, 0, Wait), Left).

closed(Tcp, {error, Reason}, Left) when Reason =:= closed; Reason =:= econnreset ->
    ok = gen_tcp:close(Tcp),
    {closed, Left}.

%% Send the header pieces, then a request; the peer-echo handler answers
%% with the client address the server saw and closes.
peer_through(Port, Pieces) ->
    {ok, Tcp} = connect(Port),
    ok = gen_tcp:send(Tcp, [Pieces, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"]),
    Body = body_of(recv_until_closed(Tcp, <<>>)),
    ok = gen_tcp:close(Tcp),
    Body.

body_of(Reply) ->
    [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
    Body.

recv_until_closed(Tcp, Acc) ->
    case gen_tcp:recv(Tcp, 0, 5000) of
        {ok, Data} -> recv_until_closed(Tcp, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

%% A v2 PROXY command for TCP over IPv4 from 203.0.113.9.
v2_tcp4() ->
    Block = <<203, 0, 113, 9, 10, 0, 0, 1, 5000:16, 443:16>>,
    <<?V2_SIG, 16#21, 16#11, (byte_size(Block)):16, Block/binary>>.

await_accept_error() ->
    receive
        {accept_error, #{reason := Reason}} -> Reason
    after 5000 -> error(no_accept_error)
    end.
