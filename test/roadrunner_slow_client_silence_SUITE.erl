-module(roadrunner_slow_client_silence_SUITE).
-moduledoc """
Silence counts toward `min_bytes_per_second` on HTTP/1.1.

A client that starts a request and then stops sending is closed once
the bytes it sent average below the minimum, after the 1 s grace, not
left until `request_timeout`. That holds for the request head (passive,
armed and hibernating reads), for a body the server reads before
dispatch (passive and armed), and for a body a manual-mode handler
reads, including one whose reads have no deadline. A body's rate is
measured over the time spent waiting on the client for it, with one 1 s
grace for the whole body, so the time a manual-mode handler takes before
or between its reads, or before the drain of a body it never reads, does
not count against the client. Every listener here
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
    shared_port_partial_head_behind_a_proxy_header/1,
    think_time_before_the_first_read_is_not_counted/1,
    slow_body_after_think_time_is_closed/1,
    body_sent_with_the_head_counts_after_think_time/1,
    continue_after_think_time_is_served/1,
    unread_body_drain_after_think_time_keeps_alive/1,
    silent_unread_body_drain_is_closed_by_the_rate/1,
    think_time_between_reads_is_not_counted/1,
    silence_after_a_read_is_closed_after_a_grace_of_waiting/1,
    small_reads_share_one_grace/1
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
        shared_port_partial_head_behind_a_proxy_header,
        think_time_before_the_first_read_is_not_counted,
        slow_body_after_think_time_is_closed,
        body_sent_with_the_head_counts_after_think_time,
        continue_after_think_time_is_served,
        unread_body_drain_after_think_time_keeps_alive,
        silent_unread_body_drain_is_closed_by_the_rate,
        think_time_between_reads_is_not_counted,
        silence_after_a_read_is_closed_after_a_grace_of_waiting,
        small_reads_share_one_grace
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
                {~"/spawned", ?H, {spawned_report, self()}},
                {~"/held", ?H, {held_report, self()}},
                {~"/held_unread", ?H, {held_unread, self()}},
                {~"/piece_then_held", ?H, {piece_then_held_report, self()}},
                {~"/pieces", ?H, {pieces_report, self()}}
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
opts(think_time_before_the_first_read_is_not_counted) ->
    #{body_buffering => manual};
opts(slow_body_after_think_time_is_closed) ->
    #{body_buffering => manual};
opts(body_sent_with_the_head_counts_after_think_time) ->
    #{min_bytes_per_second => 4000, body_buffering => manual};
opts(continue_after_think_time_is_served) ->
    #{body_buffering => manual};
opts(unread_body_drain_after_think_time_keeps_alive) ->
    #{body_buffering => manual};
opts(silent_unread_body_drain_is_closed_by_the_rate) ->
    #{body_buffering => manual};
opts(think_time_between_reads_is_not_counted) ->
    #{body_buffering => manual};
opts(silence_after_a_read_is_closed_after_a_grace_of_waiting) ->
    #{body_buffering => manual};
opts(small_reads_share_one_grace) ->
    #{body_buffering => manual};
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
    %% 4000 byte minimum. The silence checks past 1 s of the pause see
    %% only the bytes that have come so far, which without the ones that
    %% came with the head may be none (the head's read may take all of
    %% them), so those must count.
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

think_time_before_the_first_read_is_not_counted(Config) ->
    %% The whole body is in before the handler reads it, 1.5 s later:
    %% 1200 bytes average below the 1000 byte minimum over the handler's
    %% wait, but the window starts at the read, which takes them at once.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, ~"POST /held HTTP/1.1\r\nHost: x\r\nContent-Length: 1200\r\n\r\n"),
    Handler = held(),
    ok = gen_tcp:send(Sock, binary:copy(~"a", 1200)),
    ok = think(Sock, Handler),
    ?assertEqual({ok, 1200}, read_result()),
    ?assertMatch({ok, <<"HTTP/1.1 200", _/binary>>}, gen_tcp:recv(Sock, 0, 5000)).

slow_body_after_think_time_is_closed(Config) ->
    %% 10 of 100 bytes, then nothing: from the handler's first read on the
    %% client falls below the minimum once the grace is over.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, [
        ~"POST /held HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n",
        binary:copy(~"a", 10)
    ]),
    ok = think(Sock, held()),
    ?assertEqual({error, slow_client}, read_result()).

body_sent_with_the_head_counts_after_think_time(Config) ->
    %% 8000 of the body's 20000 bytes come with the head; the handler reads
    %% 1.5 s later, and the client pauses 1.3 s past that read before the
    %% rest. The silence checks past 1 s of the pause hold only with the
    %% bytes that came with the head counted.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, [
        ~"POST /held HTTP/1.1\r\nHost: x\r\nContent-Length: 20000\r\n\r\n",
        binary:copy(~"a", 8000)
    ]),
    ok = think(Sock, held()),
    {error, timeout} = gen_tcp:recv(Sock, 0, 1300),
    ok = gen_tcp:send(Sock, binary:copy(~"a", 12000)),
    ?assertEqual({ok, 20000}, read_result()).

continue_after_think_time_is_served(Config) ->
    %% A client holding its body back for a 100 Continue: the window starts
    %% with the 100, which the handler's first read sends.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(
        Sock,
        ~"POST /held HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 1200\r\n\r\n"
    ),
    ok = think(Sock, held()),
    {ok, <<"HTTP/1.1 100 Continue\r\n\r\n">>} = gen_tcp:recv(Sock, 0, 5000),
    ok = gen_tcp:send(Sock, binary:copy(~"a", 1200)),
    ?assertEqual({ok, 1200}, read_result()).

unread_body_drain_after_think_time_keeps_alive(Config) ->
    %% The whole body is in before a handler that answers 1.5 s later
    %% without reading it: the drain's window starts with the drain, which
    %% takes the body at once, so the connection serves the next request.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(
        Sock, ~"POST /held_unread HTTP/1.1\r\nHost: x\r\nContent-Length: 1200\r\n\r\n"
    ),
    Handler = held(),
    ok = gen_tcp:send(Sock, binary:copy(~"a", 1200)),
    ok = think(Sock, Handler),
    {ok, <<"HTTP/1.1 200", _/binary>>} = gen_tcp:recv(Sock, 0, 5000),
    ok = gen_tcp:send(Sock, ~"GET /read HTTP/1.1\r\nHost: x\r\n\r\n"),
    ?assertMatch({ok, <<"HTTP/1.1 200", _/binary>>}, gen_tcp:recv(Sock, 0, 5000)).

silent_unread_body_drain_is_closed_by_the_rate(Config) ->
    %% 10 of 100 bytes, then nothing, and a handler that answers 1.5 s
    %% later without reading them: the drain after the response holds the
    %% client to the rate from the drain's start, so the connection closes
    %% once the grace from then is over, not at once.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, [
        ~"POST /held_unread HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n",
        binary:copy(~"a", 10)
    ]),
    ok = think(Sock, held()),
    {ok, <<"HTTP/1.1 200", _/binary>>} = gen_tcp:recv(Sock, 0, 5000),
    ?assertEqual({error, timeout}, gen_tcp:recv(Sock, 0, 500)),
    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 5000)).

think_time_between_reads_is_not_counted(Config) ->
    %% The handler reads 10 bytes, then waits 1.5 s before reading the
    %% other 1190, which are in by then: the second read takes them at
    %% once, and the wait between the reads does not count.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, [
        ~"POST /piece_then_held HTTP/1.1\r\nHost: x\r\nContent-Length: 1200\r\n\r\n",
        binary:copy(~"a", 10)
    ]),
    Handler = held(),
    ok = gen_tcp:send(Sock, binary:copy(~"a", 1190)),
    ok = think(Sock, Handler),
    ?assertEqual({ok, 1190}, read_result()),
    ?assertMatch({ok, <<"HTTP/1.1 200", _/binary>>}, gen_tcp:recv(Sock, 0, 5000)).

silence_after_a_read_is_closed_after_a_grace_of_waiting(Config) ->
    %% The handler reads 10 of 100 bytes, waits 1.5 s, then reads on while
    %% the client sends nothing: the read fails once it has waited past
    %% the 1 s grace, not at once.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, [
        ~"POST /piece_then_held HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n",
        binary:copy(~"a", 10)
    ]),
    ok = think(Sock, held()),
    Go = erlang:monotonic_time(millisecond),
    ?assertEqual({error, slow_client}, read_result()),
    ?assert(erlang:monotonic_time(millisecond) - Go >= 900).

small_reads_share_one_grace(Config) ->
    %% The handler reads a byte at a time and the client sends one every
    %% 150 ms, about 7 bytes a second against a 1000 byte minimum. No
    %% single read waits 1 s, so only a grace for the whole body closes
    %% it, once the reads have waited past 1 s between them.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, ~"POST /pieces HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n"),
    ?assertEqual({error, slow_client}, trickle_until_read_result(Sock, 40)).

%% Send a byte every 150 ms, at most `Left` of them, until the handler
%% reports how its read ended.
trickle_until_read_result(_Sock, 0) ->
    ct:fail(no_read_result);
trickle_until_read_result(Sock, Left) ->
    _ = gen_tcp:send(Sock, ~"a"),
    receive
        {read_result, Result} -> Result
    after 150 -> trickle_until_read_result(Sock, Left - 1)
    end.

%% --- helpers ---

%% The handler process, once it holds before touching the body.
held() ->
    receive
        {held, Handler} -> Handler
    after 5000 -> ct:fail(not_held)
    end.

%% 1.5 s with no answer from the server, then let the handler go on.
think(Sock, Handler) ->
    {error, timeout} = gen_tcp:recv(Sock, 0, 1500),
    Handler ! go,
    ok.

read_result() ->
    receive
        {read_result, Result} -> Result
    after 5000 -> ct:fail(no_read_result)
    end.

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
