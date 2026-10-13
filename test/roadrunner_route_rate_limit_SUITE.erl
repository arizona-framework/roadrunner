-module(roadrunner_route_rate_limit_SUITE).
-moduledoc """
A route's own `rate_limit` over HTTP/1.1 and HTTP/2 (h2c), on top of the
listener's: refusals, per-client buckets, stacking with the listener's limit,
the bucket store across `reload_routes/2`, and the sweep of full buckets. The
HTTP/3 case lives in `roadrunner_http3_SUITE`.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    suite/0,
    all/0,
    groups/0,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    refuses_past_the_burst/1,
    buckets_are_per_client/1,
    stacks_on_the_listener_limit/1,
    refusals_are_counted/1,
    refusal_is_reported_as_a_request/1,
    refusal_keeps_the_connection/1,
    reload_keeps_unchanged_buckets/1,
    reload_adds_the_first_route_limit/1,
    stale_bucket_store_is_not_reused/1,
    sweep_drops_only_full_buckets/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [{group, http1}, {group, http2}].

groups() ->
    Shared = [
        refuses_past_the_burst,
        buckets_are_per_client,
        stacks_on_the_listener_limit,
        refusals_are_counted,
        refusal_is_reported_as_a_request
    ],
    [
        {http1, [],
            Shared ++
                [
                    refusal_keeps_the_connection,
                    reload_keeps_unchanged_buckets,
                    reload_adds_the_first_route_limit,
                    stale_bucket_store_is_not_reused,
                    sweep_drops_only_full_buckets
                ]},
        {http2, [], Shared}
    ].

init_per_group(Group, Config) ->
    [{protocol, Group} | Config].

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    {ok, _} = application:ensure_all_started(telemetry),
    Config.

end_per_testcase(_Case, _Config) ->
    case whereis(?MODULE) of
        undefined -> ok;
        _ -> roadrunner_listener:stop(?MODULE)
    end.

%% =============================================================================
%% Cases
%% =============================================================================

refuses_past_the_burst(Config) ->
    Port = start(Config, #{}, routes()),
    ?assertMatch({200, _}, request(Config, Port, ~"/login")),
    ?assertEqual({429, ~"60"}, request(Config, Port, ~"/login")),
    %% Other routes keep only the listener's limit (none here).
    [?assertMatch({200, _}, request(Config, Port, ~"/open")) || _ <- [1, 2, 3]].

buckets_are_per_client(Config) ->
    %% Behind a trusted proxy each client has its own bucket.
    Port = start(Config, #{real_ip => #{trusted_proxies => [~"127.0.0.1"]}}, routes()),
    ?assertEqual({200, ~"1.1.1.1"}, request(Config, Port, ~"/login", ~"1.1.1.1")),
    ?assertEqual({200, ~"2.2.2.2"}, request(Config, Port, ~"/login", ~"2.2.2.2")),
    ?assertEqual({429, ~"60"}, request(Config, Port, ~"/login", ~"1.1.1.1")).

stacks_on_the_listener_limit(Config) ->
    %% The listener allows 3 requests a minute: the route's refusal still
    %% spent one of them, and the route's allowance never lifts the
    %% listener's limit.
    Listener = #{rate_limit => #{rate => 1, burst => 3, period => 60}},
    Port = start(Config, Listener, routes()),
    ?assertMatch({200, _}, request(Config, Port, ~"/login")),
    ?assertEqual({429, ~"60"}, request(Config, Port, ~"/login")),
    ?assertMatch({200, _}, request(Config, Port, ~"/open")),
    ?assertEqual({429, ~"60"}, request(Config, Port, ~"/open")).

refusals_are_counted(Config) ->
    Port = start(Config, #{}, routes()),
    _ = [request(Config, Port, ~"/login") || _ <- [1, 2, 3]],
    ?assertMatch(#{rate_limited := 2}, roadrunner_listener:info(?MODULE)).

refusal_is_reported_as_a_request(Config) ->
    %% The refusal is the route's response, so it is a request like any other
    %% on every protocol: `[roadrunner, request, stop]` with its 429.
    Self = self(),
    HandlerId = {?MODULE, refusal_is_reported_as_a_request},
    ok = telemetry:attach(
        HandlerId,
        [roadrunner, request, stop],
        fun(_Event, _Measurements, #{listener_name := ?MODULE, status := Status}, _) ->
            Self ! {request_stop, Status}
        end,
        undefined
    ),
    try
        Port = start(Config, #{}, routes()),
        ?assertMatch({200, _}, request(Config, Port, ~"/login")),
        ?assertEqual({429, ~"60"}, request(Config, Port, ~"/login")),
        ?assertEqual([200, 429], [receive_stop() || _ <- [1, 2]])
    after
        telemetry:detach(HandlerId)
    end.

refusal_keeps_the_connection(Config) ->
    %% A route's refusal ends only that request: the client can go on using
    %% the connection, for another route or after its wait.
    Port = start(Config, #{}, routes()),
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    ?assertEqual(200, keep_alive_get(Sock, ~"/login")),
    ?assertEqual(429, keep_alive_get(Sock, ~"/login")),
    ?assertEqual(200, keep_alive_get(Sock, ~"/open")),
    ok = gen_tcp:close(Sock).

reload_keeps_unchanged_buckets(Config) ->
    Port = start(Config, #{}, routes()),
    ?assertMatch({200, _}, request(Config, Port, ~"/login")),
    %% The same route with the same limit keeps its buckets.
    ok = roadrunner_listener:reload_routes(?MODULE, routes()),
    ?assertEqual({429, ~"60"}, request(Config, Port, ~"/login")),
    %% A changed limit starts new ones.
    ok = roadrunner_listener:reload_routes(?MODULE, routes(#{rate => 2, period => 60})),
    ?assertMatch({200, _}, request(Config, Port, ~"/login")).

reload_adds_the_first_route_limit(Config) ->
    Port = start(Config, #{}, [{~"/login", roadrunner_client_ip_handler}]),
    ?assertMatch({200, _}, request(Config, Port, ~"/login")),
    ?assertMatch({200, _}, request(Config, Port, ~"/login")),
    ok = roadrunner_listener:reload_routes(?MODULE, routes()),
    ?assertMatch({200, _}, request(Config, Port, ~"/login")),
    ?assertEqual({429, ~"60"}, request(Config, Port, ~"/login")).

stale_bucket_store_is_not_reused(Config) ->
    %% A listener of this name that failed to start skipped `terminate/2`, so
    %% its store is still published, its table gone. A new listener drops it,
    %% and makes its own once a route needs one.
    Dead = ets:new(dead, []),
    true = ets:delete(Dead),
    Key = {roadrunner_route_rate_limit, ?MODULE},
    persistent_term:put(Key, {Dead, atomics:new(1, [])}),
    Port = start(Config, #{}, [{~"/login", roadrunner_client_ip_handler}]),
    ?assertEqual(undefined, persistent_term:get(Key, undefined)),
    ok = roadrunner_listener:reload_routes(?MODULE, routes()),
    ?assertMatch({200, _}, request(Config, Port, ~"/login")),
    ?assertEqual({429, ~"60"}, request(Config, Port, ~"/login")).

sweep_drops_only_full_buckets(Config) ->
    %% `/fast` is full again a millisecond after a request, `/login` a minute.
    Fast = #{
        path => ~"/fast",
        handler => roadrunner_client_ip_handler,
        rate_limit => #{rate => 1000, burst => 1}
    },
    Port = start(Config, #{}, [Fast | routes()]),
    ?assertMatch({200, _}, request(Config, Port, ~"/fast")),
    ?assertMatch({200, _}, request(Config, Port, ~"/login")),
    {Table, _Counter} = persistent_term:get({roadrunner_route_rate_limit, ?MODULE}),
    ?assertEqual(2, ets:info(Table, size)),
    ok = sweep_until(Table, 1, erlang:monotonic_time(millisecond) + 5000),
    ?assertMatch([{{{~"/login", _, _, _, _}, _}, _, _}], ets:tab2list(Table)).

%% =============================================================================
%% Helpers
%% =============================================================================

%% `/login` allows one request a minute per client; `/open` sets no limit.
routes() ->
    routes(#{rate => 1, period => 60}).

routes(RateLimit) ->
    [
        #{path => ~"/login", handler => roadrunner_client_ip_handler, rate_limit => RateLimit},
        {~"/open", roadrunner_client_ip_handler}
    ].

start(Config, Extra, Routes) ->
    {ok, _} = roadrunner_listener:start_link(
        ?MODULE,
        maps:merge(
            #{port => 0, protocols => [?config(protocol, Config)], routes => Routes}, Extra
        )
    ),
    roadrunner_listener:port(?MODULE).

%% Run the sweep (the listener's timer message) until the store holds
%% `Size` buckets, syncing on a call after each so the sweep has run.
sweep_until(Table, Size, Deadline) ->
    ?MODULE ! route_rate_limit_sweep,
    _ = roadrunner_listener:port(?MODULE),
    case ets:info(Table, size) of
        Size ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> sweep_until(Table, Size, Deadline);
                false -> ct:fail({buckets_left, ets:tab2list(Table)})
            end
    end.

request(Config, Port, Path) ->
    request(Config, Port, Path, undefined).

receive_stop() ->
    receive
        {request_stop, Status} -> Status
    after 5000 -> ct:fail(no_request_stop)
    end.

%% One GET on a kept-alive HTTP/1.1 connection; its status. Reads exactly the
%% response's `content-length` bytes of body, so the next one starts clean.
keep_alive_get(Sock, Path) ->
    ok = gen_tcp:send(Sock, [~"GET ", Path, ~" HTTP/1.1\r\nHost: x\r\n\r\n"]),
    {Head, Rest} = recv_head(Sock, <<>>),
    <<"HTTP/1.1 ", Code:3/binary, _/binary>> = Head,
    {match, [Length]} = re:run(
        Head, "(?i)\r\ncontent-length: ([0-9]+)", [{capture, all_but_first, binary}]
    ),
    ok = recv_exactly(Sock, binary_to_integer(Length) - byte_size(Rest)),
    binary_to_integer(Code).

recv_head(Sock, Acc) ->
    case binary:split(Acc, ~"\r\n\r\n") of
        [Head, Rest] ->
            {Head, Rest};
        [_] ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            recv_head(Sock, <<Acc/binary, Data/binary>>)
    end.

recv_exactly(_Sock, 0) ->
    ok;
recv_exactly(Sock, N) ->
    {ok, _} = gen_tcp:recv(Sock, N, 5000),
    ok.

%% One GET on its own connection: `{200, ClientIp}` or `{429, RetryAfter}`.
request(Config, Port, Path, Forwarded) ->
    case ?config(protocol, Config) of
        http1 -> h1_get(Port, Path, Forwarded);
        http2 -> h2_get(Port, Path, Forwarded)
    end.

h1_get(Port, Path, Forwarded) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    ok = gen_tcp:send(Sock, [
        ~"GET ",
        Path,
        ~" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n",
        forwarded_line(Forwarded),
        ~"\r\n"
    ]),
    <<"HTTP/1.1 ", Code:3/binary, _/binary>> = Reply = recv_until_closed(Sock, <<>>),
    [Head, Body] = binary:split(Reply, ~"\r\n\r\n"),
    case Code of
        ~"200" ->
            {200, Body};
        ~"429" ->
            {match, [RetryAfter]} = re:run(
                Head, "(?i)\r\nretry-after: ([0-9]+)", [{capture, all_but_first, binary}]
            ),
            {429, RetryAfter}
    end.

forwarded_line(undefined) -> ~"";
forwarded_line(IP) -> [~"X-Forwarded-For: ", IP, ~"\r\n"].

recv_until_closed(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} ->
            recv_until_closed(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} ->
            ok = gen_tcp:close(Sock),
            Acc
    end.

h2_get(Port, Path, Forwarded) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    Extra =
        case Forwarded of
            undefined -> [];
            IP -> [{~"x-forwarded-for", IP}]
        end,
    {Block, _Enc} = roadrunner_http2_hpack:encode(
        [{~":method", ~"GET"}, {~":scheme", ~"http"}, {~":authority", ~"x"}, {~":path", Path}] ++
            Extra,
        roadrunner_http2_hpack:new_encoder(4096)
    ),
    ok = gen_tcp:send(Sock, [
        ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",
        roadrunner_http2_frame:encode({settings, 0, []}),
        roadrunner_http2_frame:encode({headers, 1, 16#05, undefined, Block})
    ]),
    Response = h2_recv(Sock, <<>>, roadrunner_http2_hpack:new_decoder(4096), {undefined, <<>>}),
    ok = gen_tcp:close(Sock),
    Response.

%% Stream 1's final status and its body (`200`) or `Retry-After` (`429`).
h2_recv(Sock, Buf, Dec, {Status, Body} = Acc) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {ok, {headers, 1, Flags, _Priority, Block}, Rest} ->
            {ok, Headers, Dec1} = roadrunner_http2_hpack:decode(Block, Dec),
            case lists:keyfind(~":status", 1, Headers) of
                {_, ~"429"} ->
                    {_, RetryAfter} = lists:keyfind(~"retry-after", 1, Headers),
                    {429, RetryAfter};
                {_, ~"200"} when Flags band 16#01 =:= 0 ->
                    h2_recv(Sock, Rest, Dec1, {200, Body})
            end;
        {ok, {data, 1, Flags, Data, _FlowLen}, Rest} ->
            Acc1 = {Status, <<Body/binary, Data/binary>>},
            case Flags band 16#01 of
                0 -> h2_recv(Sock, Rest, Dec, Acc1);
                _ -> Acc1
            end;
        {ok, _Other, Rest} ->
            h2_recv(Sock, Rest, Dec, Acc);
        _More ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            h2_recv(Sock, <<Buf/binary, Data/binary>>, Dec, Acc)
    end.
