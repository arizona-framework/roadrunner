-module(roadrunner_real_ip_listener_tests).

-include_lib("eunit/include/eunit.hrl").

%% The `real_ip` listener option end to end. Test clients connect over
%% loopback, so the peer is 127.0.0.1: a listener trusting it plays a
%% deployment behind a proxy, one trusting 10.0.0.0/8 a client that reached
%% the server directly.

%% =============================================================================
%% Option validation (a bad config fails the listener start).
%% =============================================================================

rejects_invalid_real_ip_test() ->
    process_flag(trap_exit, true),
    ?assertMatch(
        {error, {{invalid_listener_opt, real_ip, _}, _}},
        roadrunner_listener:start_link(ri_invalid, #{
            port => 0,
            real_ip => #{trusted_proxies => [~"0.0.0.0/0"]},
            routes => roadrunner_client_ip_handler
        })
    ).

%% =============================================================================
%% HTTP/1.1
%% =============================================================================

h1_trusted_peer_reports_forwarded_client_test() ->
    with_listener([http1], #{trusted_proxies => [~"127.0.0.1"]}, #{}, fun(Port) ->
        ?assertEqual(~"203.0.113.7", h1_client_ip(Port, ~"203.0.113.7"))
    end).

h1_untrusted_peer_reports_itself_test() ->
    %% A client that bypasses the proxy cannot spoof its address.
    with_listener([http1], #{trusted_proxies => [~"10.0.0.0/8"]}, #{}, fun(Port) ->
        ?assertEqual(~"127.0.0.1", h1_client_ip(Port, ~"203.0.113.7"))
    end).

h1_without_real_ip_reports_peer_test() ->
    Name = unique(ri_off),
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0, protocols => [http1], routes => roadrunner_client_ip_handler
    }),
    try
        ?assertEqual(~"127.0.0.1", h1_client_ip(roadrunner_listener:port(Name), ~"203.0.113.7"))
    after
        ok = roadrunner_listener:stop(Name)
    end.

h1_rate_limit_keys_on_client_ip_test() ->
    %% Behind the proxy each client has its own bucket: a second client is
    %% served while the first one, over its rate, is refused.
    RateLimit = #{rate_limit => #{rate => 1, burst => 1, period => 60}},
    with_listener([http1], #{trusted_proxies => [~"127.0.0.1"]}, RateLimit, fun(Port) ->
        ?assertMatch(<<"HTTP/1.1 200", _/binary>>, h1_request(Port, ~"1.1.1.1")),
        ?assertMatch(<<"HTTP/1.1 200", _/binary>>, h1_request(Port, ~"2.2.2.2")),
        ?assertMatch(<<"HTTP/1.1 429", _/binary>>, h1_request(Port, ~"1.1.1.1"))
    end).

%% =============================================================================
%% HTTP/2 (h2c)
%% =============================================================================

h2c_resolves_and_rate_limits_per_client_test() ->
    RateLimit = #{rate_limit => #{rate => 1, burst => 1, period => 60}},
    with_listener([http2], #{trusted_proxies => [~"127.0.0.1"]}, RateLimit, fun(Port) ->
        {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
        Preface = ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",
        Enc0 = roadrunner_http2_hpack:new_encoder(4096),
        {H1, Enc1} = h2_headers(1, ~"1.1.1.1", Enc0),
        {H3, Enc2} = h2_headers(3, ~"2.2.2.2", Enc1),
        {H5, _} = h2_headers(5, ~"1.1.1.1", Enc2),
        ok = gen_tcp:send(Sock, [Preface, <<0:24, 4, 0, 0:32>>, H1, H3, H5]),
        Reply = recv_for(Sock, <<>>, 800),
        ok = gen_tcp:close(Sock),
        Responses = responses(Reply, roadrunner_http2_hpack:new_decoder(4096), #{}),
        %% Two clients, one bucket each; the first client's second request is
        %% over its rate.
        ?assertMatch(#{1 := {~"200", ~"1.1.1.1"}, 3 := {~"200", ~"2.2.2.2"}}, Responses),
        ?assertMatch(#{5 := {~"429", _}}, Responses)
    end).

%% --- helpers ---

with_listener(Protocols, RealIp, Extra, Fun) ->
    Name = unique(ri_it),
    {ok, _} = roadrunner_listener:start_link(
        Name,
        maps:merge(
            #{
                port => 0,
                protocols => Protocols,
                real_ip => RealIp,
                routes => roadrunner_client_ip_handler
            },
            Extra
        )
    ),
    try
        Fun(roadrunner_listener:port(Name))
    after
        ok = roadrunner_listener:stop(Name)
    end.

unique(Prefix) ->
    list_to_atom(atom_to_list(Prefix) ++ "_" ++ integer_to_list(erlang:unique_integer([positive]))).

h1_client_ip(Port, Forwarded) ->
    Reply = h1_request(Port, Forwarded),
    [_, Body] = binary:split(Reply, ~"\r\n\r\n"),
    Body.

h1_request(Port, Forwarded) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Sock, [
        ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\nX-Forwarded-For: ",
        Forwarded,
        ~"\r\n\r\n"
    ]),
    Reply = recv_for(Sock, <<>>, 1000),
    ok = gen_tcp:close(Sock),
    Reply.

recv_for(Sock, Acc, Timeout) ->
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, Data} -> recv_for(Sock, <<Acc/binary, Data/binary>>, Timeout);
        {error, _} -> Acc
    end.

h2_headers(StreamId, Forwarded, Enc) ->
    {Block, Enc1} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"http"},
            {~":authority", ~"x"},
            {~":path", ~"/"},
            {~"x-forwarded-for", Forwarded}
        ],
        Enc
    ),
    Frame = roadrunner_http2_frame:encode(
        {headers, StreamId, 16#04 bor 16#01, undefined, iolist_to_binary(Block)}
    ),
    {iolist_to_binary(Frame), Enc1}.

%% `#{StreamId => {Status, Body}}` from the server's frames, threading the
%% HPACK decoder (it is per connection).
responses(Bin, Dec, Acc) ->
    case roadrunner_http2_frame:parse(Bin, 16384) of
        {ok, {headers, StreamId, _Flags, _Priority, Block}, Rest} ->
            {ok, Headers, Dec1} = roadrunner_http2_hpack:decode(Block, Dec),
            Status = proplists:get_value(~":status", Headers),
            responses(Rest, Dec1, Acc#{StreamId => {Status, <<>>}});
        {ok, {data, StreamId, _Flags, Data, _FlowLen}, Rest} ->
            #{StreamId := {Status, Body}} = Acc,
            responses(Rest, Dec, Acc#{StreamId := {Status, <<Body/binary, Data/binary>>}});
        {ok, _Other, Rest} ->
            responses(Rest, Dec, Acc);
        _ ->
            Acc
    end.
