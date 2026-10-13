-module(roadrunner_real_ip_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_real_ip).
-define(PROXY, {10, 0, 0, 5}).

%% =============================================================================
%% compile/1
%% =============================================================================

compile_off_test() ->
    ?assertEqual(undefined, ?M:compile(undefined)).

compile_rejects_test_() ->
    [
        ?_assertError({invalid_listener_opt, real_ip, Opts}, ?M:compile(Opts))
     || Opts <- [
            true,
            #{},
            #{trusted_proxies => []},
            #{trusted_proxies => [~"10.0.0.1"], trusted_hops => 1},
            #{trusted_hops => 0},
            #{trusted_hops => one},
            #{trusted_hops => 1, header => ~"x-real-ip"},
            #{trusted_hops => 1, bogus => 1},
            %% `/0` would trust hops a client writes.
            #{trusted_proxies => [~"0.0.0.0/0"]},
            #{trusted_proxies => [~"::/0"]},
            %% A mapped `/96` is all of IPv4, as `0.0.0.0/0` is.
            #{trusted_proxies => [~"::ffff:0.0.0.0/96"]},
            %% Loose forms that `inet:parse_address/1` would accept.
            #{trusted_proxies => [~"010.0.0.0/8"]},
            #{trusted_proxies => [~"10/8"]},
            %% Bad prefix lengths and entries.
            #{trusted_proxies => [~"10.0.0.0/33"]},
            #{trusted_proxies => [~"2001:db8::/129"]},
            #{trusted_proxies => [~"10.0.0.0/x"]},
            #{trusted_proxies => [~"10.0.0.0/1a"]},
            #{trusted_proxies => [~"10.0.0.0/"]},
            #{trusted_proxies => [~"10.0.0.0/0008"]},
            #{trusted_proxies => [~"not-an-ip"]},
            #{trusted_proxies => [binary:copy(~"1", 64)]},
            #{trusted_proxies => ["10.0.0.0/8"]}
        ]
    ].

compile_accepts_test() ->
    ?assertMatch({hops, x_forwarded_for, 2}, ?M:compile(#{trusted_hops => 2})),
    ?assertMatch(
        {cidrs, forwarded, {[_], [_]}},
        ?M:compile(#{trusted_proxies => [~"10.0.0.0/8", ~"2001:db8::/32"], header => forwarded})
    ),
    %% IPv4-mapped IPv6 covers the IPv4 range it maps (peers and hops are
    %% unmapped), as a host or as a prefix past the 96 mapping bits.
    ?assertMatch(
        {cidrs, x_forwarded_for, {[_, _], []}},
        ?M:compile(#{trusted_proxies => [~"::ffff:10.0.0.1", ~"::ffff:192.168.0.0/112"]})
    ),
    %% A shorter mapped prefix reaches past the mapped range, so it stays an
    %% IPv6 range.
    ?assertMatch(
        {cidrs, x_forwarded_for, {[], [_]}},
        ?M:compile(#{trusted_proxies => [~"::ffff:0.0.0.0/95"]})
    ).

%% A bare IPv6 address is one host; a prefix ending inside a 16-bit word
%% checks only that word's leading bits.
ipv6_prefixes_test() ->
    Host = ?M:compile(#{trusted_proxies => [~"2001:db8::1"]}),
    ?assertEqual(Host, ?M:peer_trust(Host, {{8193, 3512, 0, 0, 0, 0, 0, 1}, 1})),
    ?assertEqual(undefined, ?M:peer_trust(Host, {{8193, 3512, 0, 0, 0, 0, 0, 2}, 1})),
    Slash33 = ?M:compile(#{trusted_proxies => [~"2001:db8::/33"]}),
    ?assertEqual(Slash33, ?M:peer_trust(Slash33, {{8193, 3512, 16#7FFF, 0, 0, 0, 0, 1}, 1})),
    ?assertEqual(undefined, ?M:peer_trust(Slash33, {{8193, 3512, 16#8000, 0, 0, 0, 0, 1}, 1})).

%% =============================================================================
%% peer_trust/2
%% =============================================================================

peer_trust_test() ->
    Cidrs = ?M:compile(#{trusted_proxies => [~"10.0.0.0/8", ~"2001:db8::/32"]}),
    ?assertEqual(Cidrs, ?M:peer_trust(Cidrs, {?PROXY, 1})),
    ?assertEqual(Cidrs, ?M:peer_trust(Cidrs, {{8193, 3512, 1, 0, 0, 0, 0, 1}, 1})),
    %% A mapped peer is matched as the IPv4 address it carries.
    ?assertEqual(Cidrs, ?M:peer_trust(Cidrs, {{0, 0, 0, 0, 0, 16#FFFF, 16#0A00, 5}, 1})),
    ?assertEqual(undefined, ?M:peer_trust(Cidrs, {{8, 8, 8, 8}, 1})),
    ?assertEqual(undefined, ?M:peer_trust(Cidrs, {{8193, 3513, 0, 0, 0, 0, 0, 1}, 1})),
    ?assertEqual(undefined, ?M:peer_trust(Cidrs, undefined)),
    ?assertEqual(undefined, ?M:peer_trust(undefined, {?PROXY, 1})),
    Hops = ?M:compile(#{trusted_hops => 1}),
    ?assertEqual(Hops, ?M:peer_trust(Hops, {{8, 8, 8, 8}, 1})).

%% =============================================================================
%% resolve/3: X-Forwarded-For
%% =============================================================================

xff_test_() ->
    Config = ?M:compile(#{trusted_proxies => [~"10.0.0.0/8", ~"2001:db8::/32"]}),
    Resolve = fun(Value) -> ?M:resolve(Config, ?PROXY, [{~"x-forwarded-for", Value}]) end,
    [
        ?_assertEqual({203, 0, 113, 7}, Resolve(~"203.0.113.7")),
        %% Trusted hops are skipped; the first untrusted one is the client,
        %% and everything left of it (client-written) is never read.
        ?_assertEqual({203, 0, 113, 7}, Resolve(~"6.6.6.6, 203.0.113.7, 10.0.0.9")),
        ?_assertEqual({203, 0, 113, 7}, Resolve(~"  203.0.113.7  ,10.1.2.3")),
        %% Only trusted hops: the leftmost.
        ?_assertEqual({10, 0, 0, 1}, Resolve(~"10.0.0.1, 10.0.0.2")),
        %% Ports, brackets, bare and mapped IPv6.
        ?_assertEqual({203, 0, 113, 7}, Resolve(~"203.0.113.7:5678")),
        ?_assertEqual({8193, 3513, 0, 0, 0, 0, 0, 1}, Resolve(~"[2001:db9::1]:443")),
        ?_assertEqual({8193, 3513, 0, 0, 0, 0, 0, 1}, Resolve(~"[2001:db9::1]")),
        ?_assertEqual({8193, 3513, 0, 0, 0, 0, 0, 1}, Resolve(~"2001:db9::1")),
        ?_assertEqual({203, 0, 113, 7}, Resolve(~"::ffff:203.0.113.7")),
        %% A hop that is not an address ends the walk with the trusted hop to
        %% its right, or the peer when it is the first.
        ?_assertEqual({10, 0, 0, 9}, Resolve(~"203.0.113.7, junk, 10.0.0.9")),
        ?_assertEqual(?PROXY, Resolve(~"")),
        ?_assertEqual(?PROXY, Resolve(~"203.0.113.7,")),
        ?_assertEqual(?PROXY, Resolve(~"010.0.0.1")),
        ?_assertEqual(?PROXY, Resolve(~"256.0.0.1")),
        ?_assertEqual(?PROXY, Resolve(~"1.2.3.4.5")),
        ?_assertEqual(?PROXY, Resolve(~"1.2.3.4:")),
        ?_assertEqual(?PROXY, Resolve(~"1.2.3.4:123456")),
        ?_assertEqual(?PROXY, Resolve(~"1.2.3.4:12a")),
        ?_assertEqual(?PROXY, Resolve(~"1.2.3.4x")),
        ?_assertEqual(?PROXY, Resolve(~"[2001:db9::1")),
        ?_assertEqual(?PROXY, Resolve(~"[2001:db9::1]x")),
        ?_assertEqual(?PROXY, Resolve(~"[2001:db9::1]:x")),
        ?_assertEqual(?PROXY, Resolve(~"[1.2.3.4]")),
        ?_assertEqual(?PROXY, Resolve(binary:copy(~"a", 60))),
        %% A client cannot make the walk read what it stuffs to the left.
        ?_assertEqual(
            {203, 0, 113, 7}, Resolve(<<(binary:copy(~",", 8000))/binary, "203.0.113.7">>)
        )
    ].

%% Repeated lines are one comma-joined value (RFC 9110 §5.3), the last line
%% holding the nearest hops.
xff_lines_test() ->
    Config = ?M:compile(#{trusted_proxies => [~"10.0.0.0/8"]}),
    Headers = [
        {~"x-forwarded-for", ~"6.6.6.6"},
        {~"accept", ~"*/*"},
        {~"x-forwarded-for", ~"203.0.113.7, 10.0.0.9"},
        {~"x-forwarded-for", ~"10.0.0.8"}
    ],
    ?assertEqual({203, 0, 113, 7}, ?M:resolve(Config, ?PROXY, Headers)),
    ?assertEqual(
        {6, 6, 6, 6},
        ?M:resolve(Config, ?PROXY, [
            {~"x-forwarded-for", ~"6.6.6.6"}, {~"x-forwarded-for", ~"10.0.0.9"}
        ])
    ),
    %% No header: the peer.
    ?assertEqual(?PROXY, ?M:resolve(Config, ?PROXY, [{~"accept", ~"*/*"}])).

%% `trusted_hops => N` trusts the peer and the N-1 nearest header hops.
hops_test() ->
    One = ?M:compile(#{trusted_hops => 1}),
    Two = ?M:compile(#{trusted_hops => 2}),
    Chain = [{~"x-forwarded-for", ~"1.1.1.1, 2.2.2.2, 3.3.3.3"}],
    ?assertEqual({3, 3, 3, 3}, ?M:resolve(One, {9, 9, 9, 9}, Chain)),
    ?assertEqual({2, 2, 2, 2}, ?M:resolve(Two, {9, 9, 9, 9}, Chain)),
    %% A chain shorter than the trusted hops: its leftmost.
    ?assertEqual(
        {3, 3, 3, 3}, ?M:resolve(Two, {9, 9, 9, 9}, [{~"x-forwarded-for", ~"3.3.3.3"}])
    ),
    ?assertEqual({9, 9, 9, 9}, ?M:resolve(Two, {9, 9, 9, 9}, [])).

%% =============================================================================
%% resolve/3: Forwarded (RFC 7239)
%% =============================================================================

forwarded_test_() ->
    Config = ?M:compile(#{trusted_proxies => [~"10.0.0.0/8"], header => forwarded}),
    Resolve = fun(Value) -> ?M:resolve(Config, ?PROXY, [{~"forwarded", Value}]) end,
    [
        ?_assertEqual({203, 0, 113, 7}, Resolve(~"for=203.0.113.7")),
        ?_assertEqual({203, 0, 113, 7}, Resolve(~"proto=https;For=203.0.113.7;by=10.0.0.5")),
        ?_assertEqual({203, 0, 113, 7}, Resolve(~"for=\"203.0.113.7:8080\"")),
        ?_assertEqual({8193, 3512, 0, 0, 0, 0, 0, 7}, Resolve(~"for=\"[2001:db8::7]:4711\"")),
        ?_assertEqual({203, 0, 113, 7}, Resolve(~"for=6.6.6.6, for=203.0.113.7, for=10.0.0.3")),
        %% `unknown`, obfuscated identifiers, a missing `for`, a parameter
        %% without a value and an unterminated quote are not addresses.
        ?_assertEqual(?PROXY, Resolve(~"for=unknown")),
        ?_assertEqual(?PROXY, Resolve(~"for=_hidden")),
        ?_assertEqual(?PROXY, Resolve(~"proto=https;by=10.0.0.5")),
        ?_assertEqual(?PROXY, Resolve(~"secret;proto=https")),
        ?_assertEqual(?PROXY, Resolve(~"for=\"203.0.113.7"))
    ].
