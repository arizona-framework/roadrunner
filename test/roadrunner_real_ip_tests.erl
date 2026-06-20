-module(roadrunner_real_ip_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_real_ip).

%% A config trusting loopback, the RFC1918 10/8 block, and IPv6 loopback,
%% reading the default `x-forwarded-for` header.
cfg() ->
    ?M:compile(#{trusted_proxies => [~"127.0.0.1/32", ~"10.0.0.0/8", ~"::1/128"]}).

xff(Value) ->
    [{~"host", ~"example.com"}, {~"x-forwarded-for", Value}].

%% --- compile/1: validation ---

compile_undefined_test() ->
    ?assertEqual(undefined, ?M:compile(undefined)).

compile_ok_default_header_test() ->
    Cfg = ?M:compile(#{trusted_proxies => [~"10.0.0.0/8"]}),
    ?assertMatch(#{header := ~"x-forwarded-for", trusted := [_]}, Cfg).

compile_ok_custom_header_lowercased_test() ->
    Cfg = ?M:compile(#{trusted_proxies => [~"10.0.0.0/8"], header => ~"X-Real-IP"}),
    ?assertMatch(#{header := ~"x-real-ip"}, Cfg).

compile_bare_address_is_full_prefix_test() ->
    %% A bare address (no `/prefix`) trusts only that exact host (full /32).
    Cfg = ?M:compile(#{trusted_proxies => [~"192.0.2.1"]}),
    %% A neighbor is untrusted, so its header is ignored and it keys on itself.
    ?assertEqual({192, 0, 2, 2}, ?M:resolve(Cfg, {{192, 0, 2, 2}, 1}, xff(~"203.0.113.5"))),
    ?assertEqual(
        {203, 0, 113, 5},
        ?M:resolve(Cfg, {{192, 0, 2, 1}, 1}, xff(~"203.0.113.5"))
    ).

compile_v6_cidr_test() ->
    Cfg = ?M:compile(#{trusted_proxies => [~"2001:db8::/32"]}),
    ?assertMatch(#{trusted := [{8, _, _}]}, Cfg).

compile_missing_trusted_proxies_test() ->
    ?assertError(
        {invalid_listener_opt, real_ip, trusted_proxies_required},
        ?M:compile(#{header => ~"x-real-ip"})
    ).

compile_empty_trusted_proxies_test() ->
    ?assertError(
        {invalid_listener_opt, real_ip, empty_trusted_proxies},
        ?M:compile(#{trusted_proxies => []})
    ).

compile_trusted_proxies_not_a_list_test() ->
    ?assertError(
        {invalid_listener_opt, real_ip, {trusted_proxies, ~"10.0.0.0/8"}},
        ?M:compile(#{trusted_proxies => ~"10.0.0.0/8"})
    ).

compile_non_binary_cidr_test() ->
    ?assertError(
        {invalid_listener_opt, real_ip, {trusted_proxy, {10, 0, 0, 0}}},
        ?M:compile(#{trusted_proxies => [{10, 0, 0, 0}]})
    ).

compile_bad_address_test() ->
    ?assertError(
        {invalid_listener_opt, real_ip, {trusted_proxy, ~"999.1.1.1"}},
        ?M:compile(#{trusted_proxies => [~"999.1.1.1/8"]})
    ).

compile_prefix_too_large_test() ->
    ?assertError(
        {invalid_listener_opt, real_ip, {prefix, ~"33"}},
        ?M:compile(#{trusted_proxies => [~"10.0.0.0/33"]})
    ).

compile_prefix_not_integer_test() ->
    ?assertError(
        {invalid_listener_opt, real_ip, {prefix, ~"8x"}},
        ?M:compile(#{trusted_proxies => [~"10.0.0.0/8x"]})
    ).

compile_v6_prefix_too_large_test() ->
    ?assertError(
        {invalid_listener_opt, real_ip, {prefix, ~"129"}},
        ?M:compile(#{trusted_proxies => [~"2001:db8::/129"]})
    ).

compile_bad_header_type_test() ->
    ?assertError(
        {invalid_listener_opt, real_ip, {header, not_a_binary}},
        ?M:compile(#{trusted_proxies => [~"10.0.0.0/8"], header => not_a_binary})
    ).

compile_empty_header_test() ->
    ?assertError(
        {invalid_listener_opt, real_ip, {header, ~""}},
        ?M:compile(#{trusted_proxies => [~"10.0.0.0/8"], header => ~""})
    ).

compile_unknown_keys_test() ->
    ?assertError(
        {invalid_listener_opt, real_ip, {unknown_keys, [recursive]}},
        ?M:compile(#{trusted_proxies => [~"10.0.0.0/8"], recursive => true})
    ).

compile_non_map_test() ->
    ?assertError(
        {invalid_listener_opt, real_ip, true},
        ?M:compile(true)
    ).

%% --- resolve/3 ---

resolve_undefined_peer_test() ->
    ?assertEqual(undefined, ?M:resolve(cfg(), undefined, xff(~"203.0.113.7"))).

resolve_untrusted_peer_ignores_header_test() ->
    %% A direct (untrusted) client cannot spoof its IP via the header.
    ?assertEqual(
        {198, 51, 100, 9},
        ?M:resolve(cfg(), {{198, 51, 100, 9}, 4321}, xff(~"203.0.113.7"))
    ).

resolve_trusted_peer_no_header_test() ->
    ?assertEqual(
        {10, 0, 0, 1},
        ?M:resolve(cfg(), {{10, 0, 0, 1}, 80}, [{~"host", ~"example.com"}])
    ).

resolve_single_client_test() ->
    ?assertEqual(
        {203, 0, 113, 7},
        ?M:resolve(cfg(), {{127, 0, 0, 1}, 80}, xff(~"203.0.113.7"))
    ).

resolve_spoofed_leftmost_ignored_test() ->
    %% Client sent `X-Forwarded-For: 1.2.3.4`; the trusted proxy appended the
    %% real socket address. The rightmost untrusted entry wins.
    ?assertEqual(
        {203, 0, 113, 7},
        ?M:resolve(cfg(), {{127, 0, 0, 1}, 80}, xff(~"1.2.3.4, 203.0.113.7"))
    ).

resolve_recursive_skips_trusted_chain_test() ->
    %% client -> trusted CDN (10.1.2.3) -> us. Walk past the trusted hop.
    ?assertEqual(
        {203, 0, 113, 7},
        ?M:resolve(cfg(), {{127, 0, 0, 1}, 80}, xff(~"203.0.113.7, 10.1.2.3"))
    ).

resolve_all_trusted_returns_leftmost_test() ->
    ?assertEqual(
        {10, 9, 9, 9},
        ?M:resolve(cfg(), {{127, 0, 0, 1}, 80}, xff(~"10.9.9.9, 10.1.2.3"))
    ).

resolve_leading_ows_trimmed_test() ->
    ?assertEqual(
        {203, 0, 113, 7},
        ?M:resolve(cfg(), {{127, 0, 0, 1}, 80}, xff(~"   203.0.113.7   "))
    ).

resolve_empty_header_value_falls_back_to_peer_test() ->
    ?assertEqual(
        {10, 0, 0, 1},
        ?M:resolve(cfg(), {{10, 0, 0, 1}, 80}, xff(~""))
    ).

resolve_bad_nearest_hop_falls_back_to_peer_test() ->
    %% Malformed rightmost entry: stop, key on the peer.
    ?assertEqual(
        {10, 0, 0, 1},
        ?M:resolve(cfg(), {{10, 0, 0, 1}, 80}, xff(~"203.0.113.7, garbage"))
    ).

resolve_bad_entry_behind_trusted_falls_back_to_trusted_test() ->
    %% client(bad) -> trusted hop -> us: the trusted hop is the last good.
    ?assertEqual(
        {10, 1, 2, 3},
        ?M:resolve(cfg(), {{127, 0, 0, 1}, 80}, xff(~"garbage, 10.1.2.3"))
    ).

resolve_joins_repeated_headers_in_order_test() ->
    %% Two X-Forwarded-For lines are equivalent to one comma-joined value
    %% (RFC 9110 §5.3): client -> trusted hop, split across lines.
    Headers = [
        {~"x-forwarded-for", ~"203.0.113.7"},
        {~"x-forwarded-for", ~"10.1.2.3"}
    ],
    ?assertEqual({203, 0, 113, 7}, ?M:resolve(cfg(), {{127, 0, 0, 1}, 80}, Headers)).

resolve_repeated_headers_ignore_spoofed_leftmost_test() ->
    %% A proxy that forwards the client's header as a separate line before
    %% appending the real client: the rightmost untrusted entry still wins, so
    %% the spoofed first line is ignored (keyfind-first would have trusted it).
    Headers = [
        {~"x-forwarded-for", ~"1.2.3.4"},
        {~"x-forwarded-for", ~"203.0.113.7"}
    ],
    ?assertEqual({203, 0, 113, 7}, ?M:resolve(cfg(), {{127, 0, 0, 1}, 80}, Headers)).

resolve_custom_header_test() ->
    Cfg = ?M:compile(#{trusted_proxies => [~"10.0.0.0/8"], header => ~"x-real-ip"}),
    Headers = [{~"x-real-ip", ~"203.0.113.42"}],
    ?assertEqual({203, 0, 113, 42}, ?M:resolve(Cfg, {{10, 0, 0, 5}, 80}, Headers)).

resolve_ipv6_peer_and_client_test() ->
    Cfg = ?M:compile(#{trusted_proxies => [~"2001:db8::/32"]}),
    Peer = {{16#2001, 16#db8, 0, 0, 0, 0, 0, 1}, 80},
    ?assertEqual(
        {16#2606, 16#4700, 0, 0, 0, 0, 0, 16#1111},
        ?M:resolve(Cfg, Peer, xff(~"2606:4700::1111"))
    ).

resolve_v4_mapped_peer_matches_v4_cidr_test() ->
    %% A dual-stack proxy reports `::ffff:10.0.0.1`; it must match `10.0.0.0/8`.
    Mapped = {0, 0, 0, 0, 0, 16#ffff, 16#0a00, 16#0001},
    ?assertEqual(
        {203, 0, 113, 7},
        ?M:resolve(cfg(), {Mapped, 80}, xff(~"203.0.113.7"))
    ).

resolve_v4_mapped_chain_entry_unwrapped_test() ->
    ?assertEqual(
        {203, 0, 113, 7},
        ?M:resolve(cfg(), {{127, 0, 0, 1}, 80}, xff(~"::ffff:203.0.113.7"))
    ).

resolve_family_mismatch_not_trusted_test() ->
    %% An IPv6 client against a v4-only trust list is untrusted (returned as-is
    %% only if it were the peer); here the v6 entry is the rightmost untrusted.
    ?assertEqual(
        {16#2001, 16#db8, 0, 0, 0, 0, 0, 16#99},
        ?M:resolve(cfg(), {{127, 0, 0, 1}, 80}, xff(~"2001:db8::99"))
    ).

resolve_prefix_zero_trusts_all_v4_test() ->
    Cfg = ?M:compile(#{trusted_proxies => [~"0.0.0.0/0"]}),
    %% Every v4 peer is trusted, so the header is always honored.
    ?assertEqual(
        {203, 0, 113, 7},
        ?M:resolve(Cfg, {{198, 51, 100, 9}, 80}, xff(~"203.0.113.7"))
    ).
