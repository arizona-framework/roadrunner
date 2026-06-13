-module(roadrunner_rate_limit_listener_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Opt validation (trap_exit so the bad start surfaces as `{error, _}`).
%% =============================================================================

valid_rate_limit_starts_test() ->
    with_listener([http1], #{rate => 5}, fun(_Port, Name) ->
        ?assert(is_integer(roadrunner_listener:port(Name)))
    end).

valid_full_rate_limit_starts_test() ->
    Cfg = #{rate => 5, period => 60, burst => 10, idle_ttl => 1000, sweep_interval => 500},
    with_listener([http1], Cfg, fun(_Port, Name) ->
        ?assert(is_integer(roadrunner_listener:port(Name)))
    end).

rejects_missing_rate_test() ->
    ?assertMatch(
        {error, {{invalid_listener_opt, rate_limit, #{burst := 5}}, _}},
        start(rl_missing_rate, [http1], #{burst => 5})
    ).

rejects_unknown_key_test() ->
    ?assertMatch(
        {error, {{invalid_listener_opt, rate_limit, _}, _}},
        start(rl_unknown_key, [http1], #{rate => 5, bogus => 1})
    ).

rejects_non_positive_test() ->
    ?assertMatch(
        {error, {{invalid_listener_opt, rate_limit, _}, _}},
        start(rl_non_positive, [http1], #{rate => 0})
    ).

rejects_non_integer_test() ->
    ?assertMatch(
        {error, {{invalid_listener_opt, rate_limit, _}, _}},
        start(rl_non_integer, [http1], #{rate => fast})
    ).

rejects_non_map_test() ->
    process_flag(trap_exit, true),
    R = roadrunner_listener:start_link(rl_non_map, #{
        port => 0, protocols => [http1], rate_limit => true, routes => roadrunner_hello_handler
    }),
    ?assertMatch({error, {{invalid_listener_opt, rate_limit, true}, _}}, R).

%% =============================================================================
%% info/1 surfaces the counter; the sweep tick runs without crashing.
%% =============================================================================

info_surfaces_rate_limited_test() ->
    with_listener([http1], #{rate => 5}, fun(_Port, Name) ->
        ?assertEqual(0, maps:get(rate_limited, roadrunner_listener:info(Name)))
    end).

sweep_tick_runs_test() ->
    %% Drive the `rate_limit_sweep` handle_info directly; the listener keeps
    %% running (reschedules) and stays answerable.
    Name = unique(rl_sweep),
    {ok, Pid} = roadrunner_listener:start_link(Name, #{
        port => 0,
        protocols => [http1],
        rate_limit => #{rate => 5, sweep_interval => 50, idle_ttl => 1},
        routes => roadrunner_hello_handler
    }),
    try
        Pid ! rate_limit_sweep,
        ?assertEqual(0, maps:get(rate_limited, roadrunner_listener:info(Name)))
    after
        ok = roadrunner_listener:stop(Name)
    end.

%% =============================================================================
%% End-to-end 429 over HTTP/1.
%% =============================================================================

h1_second_request_is_rate_limited_test() ->
    with_listener([http1], #{rate => 1, burst => 1}, fun(Port, _Name) ->
        %% First request (full bucket) reaches the handler.
        R1 = h1_request(Port),
        ?assertMatch(<<"HTTP/1.1 200", _/binary>>, R1),
        %% Second request from the same IP (bucket now empty) is refused.
        R2 = h1_request(Port),
        ?assertMatch(<<"HTTP/1.1 429 Too Many Requests", _/binary>>, R2),
        {match, _} = re:run(R2, ~"retry-after: 1", [caseless])
    end).

h1_period_sets_longer_retry_after_test() ->
    %% `period => 60` (1 request/minute): the refused request's Retry-After
    %% reflects the window, not a flat 1 second.
    with_listener([http1], #{rate => 1, burst => 1, period => 60}, fun(Port, _Name) ->
        ?assertMatch(<<"HTTP/1.1 200", _/binary>>, h1_request(Port)),
        R2 = h1_request(Port),
        ?assertMatch(<<"HTTP/1.1 429 Too Many Requests", _/binary>>, R2),
        {match, _} = re:run(R2, ~"retry-after: 60", [caseless])
    end).

%% =============================================================================
%% End-to-end 429 over HTTP/2 (h2c) — proves the multiplexed deny path emits a
%% 429 response (not REFUSED_STREAM).
%% =============================================================================

h2c_second_stream_is_rate_limited_test() ->
    with_listener([http2], #{rate => 1, burst => 1}, fun(Port, _Name) ->
        {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
        Preface = ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",
        EmptySettings = <<0:24, 4, 0, 0:32>>,
        ok = gen_tcp:send(Sock, [Preface, EmptySettings | h2_request_frames()]),
        Reply = recv_for(Sock, <<>>, 800),
        ok = gen_tcp:close(Sock),
        Statuses = collect_statuses(Reply, roadrunner_http2_hpack:new_decoder(4096)),
        %% One stream served (200), the other refused with 429.
        ?assert(lists:member(~"200", Statuses)),
        ?assert(lists:member(~"429", Statuses))
    end).

%% --- helpers ---

start(Name, Protocols, RateLimit) ->
    process_flag(trap_exit, true),
    roadrunner_listener:start_link(Name, #{
        port => 0,
        protocols => Protocols,
        rate_limit => RateLimit,
        routes => roadrunner_hello_handler
    }).

with_listener(Protocols, RateLimit, Fun) ->
    Name = unique(rl_it),
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0,
        protocols => Protocols,
        rate_limit => RateLimit,
        routes => roadrunner_hello_handler
    }),
    Port = roadrunner_listener:port(Name),
    try
        Fun(Port, Name)
    after
        ok = roadrunner_listener:stop(Name)
    end.

unique(Prefix) ->
    list_to_atom(atom_to_list(Prefix) ++ "_" ++ integer_to_list(erlang:unique_integer([positive]))).

h1_request(Port) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
    Reply = recv_for(Sock, <<>>, 1000),
    ok = gen_tcp:close(Sock),
    Reply.

recv_for(Sock, Acc, Timeout) ->
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, Data} -> recv_for(Sock, <<Acc/binary, Data/binary>>, Timeout);
        {error, _} -> Acc
    end.

h2_request_frames() ->
    Enc0 = roadrunner_http2_hpack:new_encoder(4096),
    {Block1, Enc1} = encode_req(Enc0),
    {Block3, _Enc2} = encode_req(Enc1),
    [
        roadrunner_http2_frame:encode({headers, 1, 16#04 bor 16#01, undefined, Block1}),
        roadrunner_http2_frame:encode({headers, 3, 16#04 bor 16#01, undefined, Block3})
    ].

encode_req(Enc) ->
    {Block, Enc1} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"http"},
            {~":authority", ~"x"},
            {~":path", ~"/"}
        ],
        Enc
    ),
    {iolist_to_binary(Block), Enc1}.

%% Walk the response frames in order, decoding each HEADERS block (the HPACK
%% decoder is per-connection, so it must be threaded), collecting `:status`.
collect_statuses(<<>>, _Dec) ->
    [];
collect_statuses(Bin, Dec) ->
    case roadrunner_http2_frame:parse(Bin, 16384) of
        {ok, {headers, _Stream, _Flags, _Priority, Hpack}, Rest} ->
            {ok, Headers, Dec1} = roadrunner_http2_hpack:decode(Hpack, Dec),
            [proplists:get_value(~":status", Headers) | collect_statuses(Rest, Dec1)];
        {ok, _Other, Rest} ->
            collect_statuses(Rest, Dec);
        _ ->
            []
    end.
