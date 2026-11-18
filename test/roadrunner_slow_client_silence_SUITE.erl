-module(roadrunner_slow_client_silence_SUITE).
-moduledoc """
Silence counts toward `min_bytes_per_second` on HTTP/1.1.

A client that starts a request and then stops sending is closed once
the bytes it sent average below the minimum, after the 1 s grace, not
left until `request_timeout`. That holds for the request head (passive,
armed and hibernating reads), for a body the server reads before
dispatch (passive and armed), and for a body a manual-mode handler
reads, including one whose reads have no deadline. Every listener here
has a `request_timeout` far past the case's own wait, so only the rate
can close the connection in time. A client sending slowly but above the
minimum is served.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2, forward/4]).
-export([
    head_silence_passive/1,
    head_silence_armed/1,
    head_silence_hibernating/1,
    auto_body_silence_passive/1,
    auto_body_silence_armed/1,
    manual_body_silence/1,
    manual_body_silence_without_deadline/1,
    pipelined_partial_head_silence/1,
    crlf_after_a_body_waits_for_the_next_request/1,
    cr_after_a_body_waits_for_the_next_request/1,
    crlf_in_its_own_read_waits_for_the_next_request/1,
    cr_and_lf_in_their_own_reads_wait_for_the_next_request/1,
    crlf_in_its_own_read_then_a_request_is_served/1,
    body_read_from_a_spawned_process/1,
    slow_body_above_the_rate_is_served/1,
    body_sent_with_the_head_counts/1,
    body_sent_with_the_head_counts_for_a_spawned_reader/1,
    shared_port_partial_head_behind_a_proxy_header/1
]).

-define(H, roadrunner_manual_body_handler).
%% Far past any wait below: only the rate can close the connection.
-define(REQUEST_TIMEOUT, 60_000).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        head_silence_passive,
        head_silence_armed,
        head_silence_hibernating,
        auto_body_silence_passive,
        auto_body_silence_armed,
        manual_body_silence,
        manual_body_silence_without_deadline,
        pipelined_partial_head_silence,
        crlf_after_a_body_waits_for_the_next_request,
        cr_after_a_body_waits_for_the_next_request,
        crlf_in_its_own_read_waits_for_the_next_request,
        cr_and_lf_in_their_own_reads_wait_for_the_next_request,
        crlf_in_its_own_read_then_a_request_is_served,
        body_read_from_a_spawned_process,
        slow_body_above_the_rate_is_served,
        body_sent_with_the_head_counts,
        body_sent_with_the_head_counts_for_a_spawned_reader,
        shared_port_partial_head_behind_a_proxy_header
    ].

init_per_suite(Config) ->
    {ok, _} = roadrunner_test_event_handler:start(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    Opts = maps:merge(
        #{
            port => 0,
            request_timeout => ?REQUEST_TIMEOUT,
            min_bytes_per_second => 1000,
            routes => [
                {~"/read", ?H, read},
                {~"/report", ?H, {report, self()}},
                {~"/unbounded", ?H, {unbounded, self()}},
                {~"/spawned", ?H, {spawned_report, self()}}
            ]
        },
        opts(Case)
    ),
    {ok, _} = roadrunner_listener:start_link(Case, Opts),
    ok = telemetry:attach(
        ?MODULE, [roadrunner, listener, conn_close], fun ?MODULE:forward/4, self()
    ),
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, roadrunner_listener:port(Case), [binary, {active, false}], 5000
    ),
    [{listener, Case}, {sock, Sock} | Config].

end_per_testcase(_Case, Config) ->
    ok = gen_tcp:close(?config(sock, Config)),
    ok = telemetry:detach(?MODULE),
    ok = roadrunner_listener:stop(?config(listener, Config)).

forward(_Event, _Measurements, Metadata, Pid) ->
    Pid ! {conn_close, Metadata}.

opts(head_silence_armed) ->
    #{protocols => [{http1, #{active => 2}}]};
opts(head_silence_hibernating) ->
    #{hibernate_after => 50};
opts(auto_body_silence_armed) ->
    #{protocols => [{http1, #{active => 2}}]};
opts(manual_body_silence) ->
    #{body_buffering => manual};
opts(manual_body_silence_without_deadline) ->
    #{body_buffering => manual};
opts(crlf_after_a_body_waits_for_the_next_request) ->
    #{keep_alive_timeout => 2500};
opts(cr_after_a_body_waits_for_the_next_request) ->
    #{keep_alive_timeout => 2500};
opts(crlf_in_its_own_read_waits_for_the_next_request) ->
    #{keep_alive_timeout => 2500};
opts(cr_and_lf_in_their_own_reads_wait_for_the_next_request) ->
    #{keep_alive_timeout => 2500};
opts(body_read_from_a_spawned_process) ->
    #{body_buffering => manual};
opts(slow_body_above_the_rate_is_served) ->
    #{min_bytes_per_second => 5};
opts(body_sent_with_the_head_counts) ->
    #{min_bytes_per_second => 4000};
opts(body_sent_with_the_head_counts_for_a_spawned_reader) ->
    #{min_bytes_per_second => 4000, body_buffering => manual};
opts(shared_port_partial_head_behind_a_proxy_header) ->
    #{protocols => [http1, http2], proxy_protocol => true};
opts(_Case) ->
    #{}.

head_silence_passive(Config) ->
    head_then_silence(Config).

head_silence_armed(Config) ->
    head_then_silence(Config).

head_silence_hibernating(Config) ->
    %% The connection hibernates 50 ms into the silence; the timer it arms
    %% wakes it when the rate fails, not at the deadline.
    head_then_silence(Config).

auto_body_silence_passive(Config) ->
    body_then_silence(Config).

auto_body_silence_armed(Config) ->
    body_then_silence(Config).

manual_body_silence(Config) ->
    manual_body_then_silence(Config, ~"/report").

manual_body_silence_without_deadline(Config) ->
    %% The handler gave its reads no deadline, so only the rate ends them.
    manual_body_then_silence(Config, ~"/unbounded").

pipelined_partial_head_silence(Config) ->
    %% A whole request with the start of the next one behind it in the same
    %% segment, then nothing: the leftover is the next request's first
    %% bytes, so the rate holds it, not only the keep-alive deadline.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, [
        ~"GET /read HTTP/1.1\r\nHost: x\r\n\r\n",
        ~"GET /read HTTP/1.1\r\nHo"
    ]),
    {ok, <<"HTTP/1.1 200", _/binary>>} = gen_tcp:recv(Sock, 0, 5000),
    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 5000)),
    ?assertEqual(slow_client, conn_close_reason(Config)).

crlf_after_a_body_waits_for_the_next_request(Config) ->
    %% A client may follow a body with a CRLF (RFC 9112 §2.2). Left over
    %% after the request, it is not the next request's first bytes: the
    %% connection waits idle for that request until `keep_alive_timeout`,
    %% well past the point where the rate would have closed it.
    body_then_idle(Config, ~"\r\n", []).

cr_after_a_body_waits_for_the_next_request(Config) ->
    %% The same with only the CRLF's first byte in yet.
    body_then_idle(Config, ~"\r", []).

crlf_in_its_own_read_waits_for_the_next_request(Config) ->
    %% The CRLF comes in a read of its own, after the response.
    body_then_idle(Config, <<>>, [~"\r\n"]).

cr_and_lf_in_their_own_reads_wait_for_the_next_request(Config) ->
    %% The CR comes with the body, the LF in a read of its own.
    body_then_idle(Config, ~"\r", [~"\n"]).

crlf_in_its_own_read_then_a_request_is_served(Config) ->
    Sock = ?config(sock, Config),
    Request = ~"GET /read HTTP/1.1\r\nHost: x\r\n\r\n",
    ok = gen_tcp:send(Sock, Request),
    {ok, <<"HTTP/1.1 200", _/binary>>} = gen_tcp:recv(Sock, 0, 5000),
    ok = gen_tcp:send(Sock, ~"\r\n"),
    ?assertEqual({error, timeout}, gen_tcp:recv(Sock, 0, 100)),
    ok = gen_tcp:send(Sock, Request),
    ?assertMatch({ok, <<"HTTP/1.1 200", _/binary>>}, gen_tcp:recv(Sock, 0, 5000)).

%% A POST whose body ends with `Trailer`, then, after its response, each of
%% `Later` in a read of its own, then nothing: the connection is still
%% open well past the 1 s grace and closes at `keep_alive_timeout`.
body_then_idle(Config, Trailer, Later) ->
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, [
        ~"POST /read HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc", Trailer
    ]),
    {ok, <<"HTTP/1.1 200", _/binary>>} = gen_tcp:recv(Sock, 0, 5000),
    lists:foreach(
        fun(Bytes) ->
            ok = gen_tcp:send(Sock, Bytes),
            {error, timeout} = gen_tcp:recv(Sock, 0, 100)
        end,
        Later
    ),
    ?assertEqual({error, timeout}, gen_tcp:recv(Sock, 0, 1800)),
    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 5000)),
    ?assertEqual(keep_alive_timeout, conn_close_reason(Config)).

body_read_from_a_spawned_process(Config) ->
    %% The handler hands the request to a process of its own, which reads
    %% the body as it arrives, after the head.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, ~"POST /spawned HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n"),
    ?assertEqual({error, timeout}, gen_tcp:recv(Sock, 0, 100)),
    ok = gen_tcp:send(Sock, binary:copy(~"a", 10)),
    receive
        {read_result, Result} -> ?assertEqual({ok, 10}, Result)
    after 5000 -> ct:fail(no_read_result)
    end.

slow_body_above_the_rate_is_served(Config) ->
    %% About 6.7 bytes a second over 2.9 s against a 5 byte minimum. Every
    %% gap is longer than the 100 ms silence tick, so the rate is checked
    %% in each one, and each time it holds.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, ~"POST /read HTTP/1.1\r\nHost: x\r\nContent-Length: 20\r\n\r\n"),
    ok = trickle(Sock, binary:copy(~"a", 20), 150),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 5000),
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Reply),
    [_, Body] = binary:split(Reply, ~"\r\n\r\n"),
    ?assertEqual(~"20", Body).

body_sent_with_the_head_counts(Config) ->
    %% 8000 of the body's 20000 bytes come with the head, then a pause
    %% past the 1 s grace, then the rest: about 18 KB a second against a
    %% 4000 byte minimum. The silence check in the pause sees only what
    %% has come so far, so the bytes that came with the head must count
    %% (the head's read may take only part of them; the reads take the
    %% rest, which alone stay under the minimum).
    ok = head_with_part_of_the_body_then_pause(Config, ~"/read"),
    {ok, Reply} = gen_tcp:recv(?config(sock, Config), 0, 5000),
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Reply),
    [_, Body] = binary:split(Reply, ~"\r\n\r\n"),
    ?assertEqual(~"20000", Body).

body_sent_with_the_head_counts_for_a_spawned_reader(Config) ->
    %% The same, read by a process the handler spawns: the bytes that came
    %% with the head count there too.
    ok = head_with_part_of_the_body_then_pause(Config, ~"/spawned"),
    receive
        {read_result, Result} -> ?assertEqual({ok, 20000}, Result)
    after 5000 -> ct:fail(no_read_result)
    end.

shared_port_partial_head_behind_a_proxy_header(Config) ->
    %% On a port that also serves HTTP/2, the start of a request that came
    %% in behind the PROXY header is the request's first bytes: silence
    %% after it is held to the rate, not left to `request_timeout`.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, ~"PROXY TCP4 192.168.0.7 10.0.0.1 5000 80\r\nGET /read HTTP/1.1\r\nHo"),
    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 5000)),
    ?assertEqual(slow_client, conn_close_reason(Config)).

%% --- helpers ---

%% A POST to `Path` with 8000 of its 20000 body bytes in the head's send,
%% a pause past the 1 s grace, then the rest.
head_with_part_of_the_body_then_pause(Config, Path) ->
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, [
        ~"POST ",
        Path,
        ~" HTTP/1.1\r\nHost: x\r\nContent-Length: 20000\r\n\r\n",
        binary:copy(~"a", 8000)
    ]),
    {error, timeout} = gen_tcp:recv(Sock, 0, 1100),
    gen_tcp:send(Sock, binary:copy(~"a", 12000)).

%% Half a request head, then nothing: closed with no response.
head_then_silence(Config) ->
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, ~"GET /read HTTP/1.1\r\nHo"),
    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 5000)),
    ?assertEqual(slow_client, conn_close_reason(Config)).

%% A whole head promising 100 bytes of body, 10 of them, then nothing.
body_then_silence(Config) ->
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, [
        ~"POST /read HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n",
        binary:copy(~"a", 10)
    ]),
    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 5000)),
    ?assertEqual(slow_client, conn_close_reason(Config)).

%% The handler reads the body and reports how the read ended.
manual_body_then_silence(Config, Path) ->
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, [
        ~"POST ",
        Path,
        ~" HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n",
        binary:copy(~"a", 10)
    ]),
    receive
        {read_result, Result} -> ?assertEqual({error, slow_client}, Result)
    after 5000 -> ct:fail(no_read_result)
    end.

%% Send `Bin` one byte at a time, `Gap` ms apart.
trickle(Sock, <<B>>, _Gap) ->
    gen_tcp:send(Sock, <<B>>);
trickle(Sock, <<B, Rest/binary>>, Gap) ->
    ok = gen_tcp:send(Sock, <<B>>),
    {error, timeout} = gen_tcp:recv(Sock, 0, Gap),
    trickle(Sock, Rest, Gap).

%% Waits for this testcase's listener only.
conn_close_reason(Config) ->
    Listener = ?config(listener, Config),
    receive
        {conn_close, #{listener_name := Listener, reason := Reason}} -> Reason
    after 5000 -> ct:fail(no_conn_close)
    end.
