-module(roadrunner_real_ip_listener_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Opt validation (trap_exit so the bad start surfaces as `{error, _}`).
%% =============================================================================

valid_real_ip_starts_test() ->
    with_listener([http1], #{trusted_proxies => [~"127.0.0.1/32"]}, fun(_Port, Name) ->
        ?assert(is_integer(roadrunner_listener:port(Name)))
    end).

rejects_missing_trusted_proxies_test() ->
    ?assertMatch(
        {error, {{invalid_listener_opt, real_ip, trusted_proxies_required}, _}},
        start(ri_missing, [http1], #{header => ~"x-real-ip"})
    ).

rejects_non_map_real_ip_test() ->
    ?assertMatch(
        {error, {{invalid_listener_opt, real_ip, true}, _}},
        start(ri_non_map, [http1], true)
    ).

rejects_bad_cidr_test() ->
    ?assertMatch(
        {error, {{invalid_listener_opt, real_ip, {trusted_proxy, _}}, _}},
        start(ri_bad_cidr, [http1], #{trusted_proxies => [~"999.0.0.0/8"]})
    ).

%% =============================================================================
%% End-to-end resolution over HTTP/1.
%% =============================================================================

h1_trusted_peer_resolves_xff_test() ->
    %% The loopback test client is a trusted proxy, so its X-Forwarded-For is
    %% honored: the handler sees the forwarded client, not 127.0.0.1.
    with_listener([http1], #{trusted_proxies => [~"127.0.0.1/32"]}, fun(Port, _Name) ->
        ?assertEqual(~"203.0.113.7", h1_client_ip(Port, ~"x-forwarded-for: 203.0.113.7\r\n"))
    end).

h1_untrusted_peer_ignores_xff_test() ->
    %% Loopback is NOT in the trust list, so the forwarded header is ignored and
    %% the request keys on the real socket peer.
    with_listener([http1], #{trusted_proxies => [~"10.0.0.0/8"]}, fun(Port, _Name) ->
        ?assertEqual(~"127.0.0.1", h1_client_ip(Port, ~"x-forwarded-for: 203.0.113.7\r\n"))
    end).

h1_no_header_uses_peer_test() ->
    with_listener([http1], #{trusted_proxies => [~"127.0.0.1/32"]}, fun(Port, _Name) ->
        ?assertEqual(~"127.0.0.1", h1_client_ip(Port, ~""))
    end).

h1_recursive_skips_trusted_chain_test() ->
    %% client -> trusted hop (10.1.2.3) -> us: walk past the trusted hop to the
    %% real client.
    Cfg = #{trusted_proxies => [~"127.0.0.1/32", ~"10.0.0.0/8"]},
    with_listener([http1], Cfg, fun(Port, _Name) ->
        ?assertEqual(
            ~"203.0.113.7",
            h1_client_ip(Port, ~"x-forwarded-for: 203.0.113.7, 10.1.2.3\r\n")
        )
    end).

%% =============================================================================
%% End-to-end resolution over HTTP/2 (h2c) — proves the multiplexed build path
%% stashes the resolved client IP onto the request.
%% =============================================================================

h2c_trusted_peer_resolves_xff_test() ->
    with_listener([http2], #{trusted_proxies => [~"127.0.0.1/32"]}, fun(Port, _Name) ->
        {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
        Preface = ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",
        EmptySettings = <<0:24, 4, 0, 0:32>>,
        ok = gen_tcp:send(Sock, [Preface, EmptySettings | h2_request_frames()]),
        Reply = recv_for(Sock, <<>>, 800),
        ok = gen_tcp:close(Sock),
        %% The handler writes the resolved IP literal as the response body (a
        %% DATA frame payload), so the forwarded client appears verbatim.
        ?assertMatch({match, _}, re:run(Reply, ~"203\\.0\\.113\\.7"))
    end).

%% --- helpers ---

start(Name, Protocols, RealIp) ->
    process_flag(trap_exit, true),
    roadrunner_listener:start_link(Name, #{
        port => 0,
        protocols => Protocols,
        real_ip => RealIp,
        routes => roadrunner_client_ip_handler
    }).

with_listener(Protocols, RealIp, Fun) ->
    Name = unique(ri_it),
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0,
        protocols => Protocols,
        real_ip => RealIp,
        routes => roadrunner_client_ip_handler
    }),
    Port = roadrunner_listener:port(Name),
    try
        Fun(Port, Name)
    after
        ok = roadrunner_listener:stop(Name)
    end.

unique(Prefix) ->
    list_to_atom(atom_to_list(Prefix) ++ "_" ++ integer_to_list(erlang:unique_integer([positive]))).

%% Send a GET with the given extra header lines and return the response body.
h1_client_ip(Port, ExtraHeaders) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    Req = [~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n", ExtraHeaders, ~"\r\n"],
    ok = gen_tcp:send(Sock, Req),
    Reply = recv_for(Sock, <<>>, 1000),
    ok = gen_tcp:close(Sock),
    body(Reply).

body(Reply) ->
    case binary:split(Reply, ~"\r\n\r\n") of
        [_Headers, Body] -> Body;
        _ -> Reply
    end.

recv_for(Sock, Acc, Timeout) ->
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, Data} -> recv_for(Sock, <<Acc/binary, Data/binary>>, Timeout);
        {error, _} -> Acc
    end.

h2_request_frames() ->
    {Block, _Enc} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"http"},
            {~":authority", ~"x"},
            {~":path", ~"/"},
            {~"x-forwarded-for", ~"203.0.113.7"}
        ],
        roadrunner_http2_hpack:new_encoder(4096)
    ),
    [
        roadrunner_http2_frame:encode(
            {headers, 1, 16#04 bor 16#01, undefined, iolist_to_binary(Block)}
        )
    ].
