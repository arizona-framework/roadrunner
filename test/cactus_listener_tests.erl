-module(cactus_listener_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% start_link/2 + stop/1 + port/1
%% =============================================================================

listener_lifecycle_test_() ->
    {setup,
        fun() ->
            Name = listener_test_one,
            {ok, Pid} = cactus_listener:start_link(Name, #{port => 0}),
            {Name, Pid}
        end,
        fun({Name, _Pid}) ->
            ok = cactus_listener:stop(Name)
        end,
        fun({Name, Pid}) ->
            [
                {"start_link returns alive pid",
                    ?_assert(is_pid(Pid) andalso is_process_alive(Pid))},
                {"port/1 returns a non-zero ephemeral port",
                    ?_assert(cactus_listener:port(Name) > 0)},
                {"two consecutive port/1 calls return the same value",
                    ?_assertEqual(cactus_listener:port(Name), cactus_listener:port(Name))}
            ]
        end}.

listener_accepts_tcp_handshake_test_() ->
    {setup,
        fun() ->
            Name = listener_test_handshake,
            {ok, _} = cactus_listener:start_link(Name, #{port => 0}),
            cactus_listener:port(Name)
        end,
        fun(_Port) ->
            ok = cactus_listener:stop(listener_test_handshake)
        end,
        fun(Port) ->
            {"client can complete TCP handshake to the bound port", fun() ->
                {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
                ok = gen_tcp:close(Sock)
            end}
        end}.

listener_stops_releases_port_test_() ->
    {setup,
        fun() ->
            Name = listener_test_release,
            {ok, _} = cactus_listener:start_link(Name, #{port => 0}),
            Port = cactus_listener:port(Name),
            ok = cactus_listener:stop(Name),
            Port
        end,
        fun(_) -> ok end, fun(Port) ->
            {"connecting to a stopped listener fails", fun() ->
                Result = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 200
                ),
                ?assertMatch({error, _}, Result)
            end}
        end}.

listener_listen_failure_returns_error_test() ->
    %% Bind listener A to an ephemeral port, then try to bind B to the
    %% same port — second listen() must fail with eaddrinuse.
    {ok, _} = cactus_listener:start_link(listener_test_busy_a, #{port => 0}),
    Port = cactus_listener:port(listener_test_busy_a),
    process_flag(trap_exit, true),
    Result = cactus_listener:start_link(listener_test_busy_b, #{port => Port}),
    ?assertMatch({error, _}, Result),
    ok = cactus_listener:stop(listener_test_busy_a).

listener_ignores_unknown_cast_test() ->
    {ok, _} = cactus_listener:start_link(listener_test_cast, #{port => 0}),
    gen_server:cast(listener_test_cast, surprise),
    %% Process must still answer call/1 — proves it survived the cast.
    ?assert(cactus_listener:port(listener_test_cast) > 0),
    ok = cactus_listener:stop(listener_test_cast).

listener_honors_num_acceptors_opt_test() ->
    %% Explicit override exercises the opt path (default is exercised by
    %% every other listener test).
    {ok, _} = cactus_listener:start_link(listener_test_pool, #{
        port => 0, num_acceptors => 3
    }),
    ?assert(cactus_listener:port(listener_test_pool) > 0),
    ok = cactus_listener:stop(listener_test_pool).

%% =============================================================================
%% info/1
%% =============================================================================

listener_info_initial_zero_test() ->
    Name = listener_test_info_init,
    {ok, _} = cactus_listener:start_link(Name, #{port => 0, max_clients => 42}),
    Info = cactus_listener:info(Name),
    ?assertEqual(0, maps:get(active_clients, Info)),
    ?assertEqual(42, maps:get(max_clients, Info)),
    ?assertEqual(0, maps:get(requests_served, Info)),
    ok = cactus_listener:stop(Name).

listener_info_counts_served_requests_test_() ->
    {setup,
        fun() ->
            Name = listener_test_info_count,
            {ok, _} = cactus_listener:start_link(Name, #{
                port => 0, handler => cactus_hello_handler
            }),
            {Name, cactus_listener:port(Name)}
        end,
        fun({Name, _Port}) -> ok = cactus_listener:stop(Name) end, fun({Name, Port}) ->
            {"requests_served increments after each request", fun() ->
                send_request(Port),
                send_request(Port),
                send_request(Port),
                ?assertEqual(3, maps:get(requests_served, cactus_listener:info(Name)))
            end}
        end}.

send_request(Port) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
    %% Drain to EOF so the conn process completes (and bumps the counter)
    %% before we read it.
    drain(Sock),
    ok = gen_tcp:close(Sock).

drain(Sock) ->
    case gen_tcp:recv(Sock, 0, 1000) of
        {ok, _} -> drain(Sock);
        {error, _} -> ok
    end.

%% =============================================================================
%% Per-request `logger` metadata + `cactus_req:request_id/1` correlation.
%% =============================================================================

logger_metadata_set_for_each_request_test_() ->
    {setup,
        fun() ->
            Name = listener_test_logger_md,
            {ok, _} = cactus_listener:start_link(Name, #{
                port => 0, handler => cactus_logger_probe_handler
            }),
            {Name, cactus_listener:port(Name)}
        end,
        fun({Name, _Port}) -> ok = cactus_listener:stop(Name) end, fun({_Name, Port}) ->
            [
                {"handler sees request_id + logger metadata populated", fun() ->
                    {Md, Id} = probe_one(Port),
                    ?assertMatch(<<_:16/binary>>, Id),
                    ?assert(is_hex_lowercase(Id)),
                    ?assertEqual(Id, maps:get(request_id, Md)),
                    ?assertEqual(~"GET", maps:get(method, Md)),
                    ?assertEqual(~"/", maps:get(path, Md)),
                    ?assertMatch({{127, 0, 0, 1}, _}, maps:get(peer, Md))
                end},
                {"keep-alive requests get distinct request_ids", fun() ->
                    {ok, Sock} = gen_tcp:connect(
                        {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                    ),
                    Id1 = probe_via_sock(Sock),
                    Id2 = probe_via_sock(Sock),
                    ok = gen_tcp:close(Sock),
                    ?assertNotEqual(Id1, Id2)
                end}
            ]
        end}.

probe_one(Port) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
    Reply = drain_to_binary(Sock),
    ok = gen_tcp:close(Sock),
    Body = http_body(Reply),
    Probe = binary_to_term(Body, [safe]),
    {maps:get(logger_metadata, Probe), maps:get(request_id, Probe)}.

probe_via_sock(Sock) ->
    ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
    Reply = drain_one_response(Sock),
    Probe = binary_to_term(http_body(Reply), [safe]),
    maps:get(request_id, Probe).

drain_to_binary(Sock) -> drain_to_binary(Sock, <<>>).
drain_to_binary(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 1000) of
        {ok, Data} -> drain_to_binary(Sock, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.

%% Read until the body of one fixed-content-length response is buffered.
drain_one_response(Sock) ->
    drain_one_response(Sock, <<>>).
drain_one_response(Sock, Acc) ->
    case binary:split(Acc, ~"\r\n\r\n") of
        [Head, Rest] ->
            CL = parse_content_length(Head),
            case Rest of
                <<Body:CL/binary, _/binary>> -> <<Head/binary, "\r\n\r\n", Body/binary>>;
                _ -> drain_one_response(Sock, recv_more(Sock, Acc))
            end;
        [_] ->
            drain_one_response(Sock, recv_more(Sock, Acc))
    end.

recv_more(Sock, Acc) ->
    {ok, Data} = gen_tcp:recv(Sock, 0, 1000),
    <<Acc/binary, Data/binary>>.

http_body(Reply) ->
    [_Head, Body] = binary:split(Reply, ~"\r\n\r\n"),
    Body.

parse_content_length(Head) ->
    {match, [Cl]} = re:run(Head, ~"(?i)content-length:\\s*(\\d+)", [{capture, [1], binary}]),
    binary_to_integer(Cl).

is_hex_lowercase(Bin) ->
    lists:all(
        fun(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end,
        binary_to_list(Bin)
    ).
