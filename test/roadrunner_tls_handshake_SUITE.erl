-module(roadrunner_tls_handshake_SUITE).
-moduledoc """
The TLS handshake runs in the connection process, not the acceptor.

Drives a real `roadrunner_listener` over TLS with clients that never
complete a handshake, and checks the three things that follow from
where the handshake runs: a failed handshake is reported as an
`accept_error` and frees its `max_clients` slot, a silent peer is cut
off by `tls_handshake_timeout` without ever firing `accept`, and
parked peers do not stop other connections from being accepted.

Lives as a CT suite so every case gets its own process and its own
listener, and a parked connection left by one case cannot leak into
the next.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    garbage_hello_reports_accept_error_and_releases_slot/1,
    silent_peer_times_out_without_accept_telemetry/1,
    parked_handshakes_do_not_block_accepting/1,
    alert_logging_follows_the_tls_opts/1
]).
%% `logger` handler callback for `alert_logging_follows_the_tls_opts/1`.
-export([log/2]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        garbage_hello_reports_accept_error_and_releases_slot,
        silent_peer_times_out_without_accept_telemetry,
        parked_handshakes_do_not_block_accepting,
        alert_logging_follows_the_tls_opts
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

garbage_hello_reports_accept_error_and_releases_slot(_Config) ->
    Port = start_listener(#{}),
    {ok, Noise} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    %% Plain HTTP bytes can't form a TLS hello: the conn's handshake fails.
    ok = gen_tcp:send(Noise, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
    receive
        {accept_error, Meta} ->
            ?assertEqual(?MODULE, maps:get(listener_name, Meta)),
            ?assertMatch({handshake, _}, maps:get(reason, Meta))
    after 5000 ->
        error(no_handshake_accept_error)
    end,
    ok = gen_tcp:close(Noise),
    %% The slot the acceptor took for the noise connection is given back.
    ok = wait_for_active_clients(0),
    %% And the listener is none the worse for it.
    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, tls_get(Port, 5000)),
    ok.

silent_peer_times_out_without_accept_telemetry(_Config) ->
    Port = start_listener(#{tls_handshake_timeout => 200}),
    {ok, Silent} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    receive
        {accept_error, Meta} ->
            ?assertEqual({handshake, timeout}, maps:get(reason, Meta))
    after 5000 ->
        error(no_handshake_timeout)
    end,
    %% The parked connection was closed, so the peer sees it go away ...
    ?assertEqual({error, closed}, gen_tcp:recv(Silent, 0, 5000)),
    ok = gen_tcp:close(Silent),
    ok = wait_for_active_clients(0),
    %% ... and nothing was ever accepted: `accept` pairs with a served peer.
    receive
        {accept, _} -> error(accept_fired_for_unhandshaken_peer)
    after 0 -> ok
    end.

parked_handshakes_do_not_block_accepting(_Config) ->
    %% One acceptor, three peers that never send a ClientHello. With the
    %% handshake in the acceptor each would park it for the whole
    %% `tls_handshake_timeout` and a real client would wait behind them;
    %% with the handshake in the connection process the acceptor is free
    %% the moment it has handed the socket over.
    Port = start_listener(#{num_acceptors => 1, tls_handshake_timeout => 10000}),
    Parked = [
        begin
            {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
            S
        end
     || _ <- lists:seq(1, 3)
    ],
    %% While parked, each conn is labelled as handshaking, so an operator
    %% can tell a silent-peer pile-up from conns that were never shot.
    ok = wait_for_labels({roadrunner_conn, tls_handshake, ?MODULE}, 3),
    ?assertMatch(<<"HTTP/1.1 200 OK", _/binary>>, tls_get(Port, 2000)),
    lists:foreach(fun gen_tcp:close/1, Parked).

alert_logging_follows_the_tls_opts(_Config) ->
    %% ssl reports every alert it raises at notice level. An internet-facing
    %% port raises one for every bit of background noise, and the conn
    %% already reports each as a `{handshake, _}` accept error, so the
    %% hardened defaults lower ssl's `log_level` to `warning`; a listener that
    %% wants ssl's own reports back sets `log_level` in its `tls` opts. The
    %% test profile pins the primary logger level at `critical`, so it is
    %% raised for this case and the capturing handler is the only one attached.
    #{level := PrimaryLevel} = logger:get_primary_config(),
    ok = logger:set_primary_config(level, notice),
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => self(), level => notice}),
    try
        QuietPort = start_listener(#{}),
        ok = garbage_hello(QuietPort),
        receive
            {ssl_notice, Msg} -> error({ssl_alert_logged_by_default, Msg})
        after 300 -> ok
        end,
        ok = roadrunner_listener:stop(?MODULE),
        LoudPort = start_listener(#{
            tls => [{log_level, notice} | roadrunner_test_certs:server_opts()]
        }),
        ok = garbage_hello(LoudPort),
        receive
            {ssl_notice, _} -> ok
        after 5000 -> error(ssl_alert_not_logged_when_asked_for)
        end
    after
        _ = logger:remove_handler(?MODULE),
        ok = logger:set_primary_config(level, PrimaryLevel)
    end.

%% `logger` handler callback: forwards notice-level events to the test.
log(#{level := notice, msg := Msg}, #{config := Pid}) ->
    Pid ! {ssl_notice, Msg};
log(_Event, _Config) ->
    ok.

%% --- helpers ---

%% Plain HTTP bytes can't form a TLS hello: the conn's handshake fails and
%% is reported as a `{handshake, _}` accept error.
garbage_hello(Port) ->
    {ok, Noise} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Noise, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
    receive
        {accept_error, #{reason := {handshake, _}}} -> ok
    after 5000 ->
        error(no_handshake_accept_error)
    end,
    gen_tcp:close(Noise).

%% `Extra` wins over the defaults, so a case can bring its own `tls` opts.
start_listener(Extra) ->
    {ok, _} = roadrunner_listener:start_link(
        ?MODULE,
        maps:merge(
            #{
                port => 0,
                tls => roadrunner_test_certs:server_opts(),
                routes => roadrunner_hello_handler
            },
            Extra
        )
    ),
    roadrunner_listener:port(?MODULE).

%% A full TLS request; `Timeout` bounds connect + handshake, which is the
%% part these cases are about.
tls_get(Port, Timeout) ->
    ClientOpts = [{verify, verify_none} | roadrunner_test_certs:client_opts()],
    {ok, Sock} = ssl:connect(
        {127, 0, 0, 1}, Port, ClientOpts ++ [binary, {active, false}], Timeout
    ),
    ok = ssl:send(Sock, ~"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"),
    {ok, Reply} = ssl:recv(Sock, 0, 5000),
    ok = ssl:close(Sock),
    Reply.

%% Labels are set by the conn after the acceptor's handoff, so poll for
%% the expected count rather than assert on the first read.
wait_for_labels(Label, N) ->
    wait_for_labels(Label, N, erlang:monotonic_time(millisecond) + 5000).

wait_for_labels(Label, N, Deadline) ->
    case length([P || P <- processes(), proc_lib:get_label(P) =:= Label]) of
        N ->
            ok;
        Other ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    timer:sleep(10),
                    wait_for_labels(Label, N, Deadline);
                false ->
                    error({labelled_conns, Other, expected, N})
            end
    end.

%% Slot release happens after the telemetry event, so poll the counter
%% until it settles rather than assert on the first read.
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
