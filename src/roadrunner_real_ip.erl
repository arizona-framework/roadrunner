-module(roadrunner_real_ip).
-moduledoc false.

%% Trusted real-client-IP resolution for HTTP-terminating reverse proxies (the
%% `roadrunner_listener` `real_ip` opt). Behind nginx/caddy/ALB the socket peer
%% is the proxy, not the client; the client travels in a forwarded header
%% (`X-Forwarded-For` and friends). This resolves the real client using
%% nginx-`realip`-style recursion: the immediate peer must itself be a trusted
%% proxy before any header is honored, then the forwarded chain is walked
%% right-to-left, skipping trusted proxies, to the first untrusted address (the
%% real client). A direct (untrusted) peer's headers are never trusted, so a
%% client that bypasses the proxy can't spoof its own address.
%%
%% Pure and socket-free: `compile/1` validates + pre-builds the config once at
%% listener init (CIDRs become `{Family, NetPrefix, Shift}` so the per-request
%% check is a shift + compare); `resolve/3` runs on the request hot path, but
%% only when the opt is set — the conn loop gates the call on the cached config.

-export([compile/1, prepare/2, resolve/2]).
-export_type([config/0, prepared/0]).

-on_load(init_patterns/0).

%% Compiled `,` split pattern for the forwarded chain, stashed in
%% persistent_term at load (the project convention — never inline-compile on
%% the path).
-define(COMMA_CP_KEY, {?MODULE, comma_cp}).

%% A trusted-proxy CIDR pre-reduced for matching: the address family as the IP
%% tuple's size (`4` for IPv4, `8` for IPv6), the network's high bits
%% (`ip_to_int(Net) bsr Shift`), and `Shift = TotalBits - PrefixLen`. A
%% candidate matches when its family equals `Family` and `Int bsr Shift` equals
%% `NetPrefix`.
-type cidr() :: {4 | 8, non_neg_integer(), 0..128}.

-doc """
Compiled `real_ip` config: the trusted-proxy CIDRs and the (lowercased)
forwarded header name to read. Built by `compile/1`, carried in
`t:roadrunner_conn:proto_opts/0`, consumed by `resolve/3`.
""".
-type config() :: #{
    trusted := [cidr()],
    header := binary()
}.

-doc """
Validate and pre-build the listener `real_ip` opt, or `undefined` when unset.

`Opts` is `#{trusted_proxies := [binary()], header => binary()}`:
`trusted_proxies` is a non-empty list of CIDR binaries (`~"10.0.0.0/8"`,
`~"::1/128"`) or bare addresses (treated as a full-length prefix); `header`
defaults to `~"x-forwarded-for"` and accepts any single-value, comma-separated
bare-IP header (`~"x-real-ip"`, `~"cf-connecting-ip"`, ...). Raises
`{invalid_listener_opt, real_ip, _}` on bad input (the listener convention).
""".
-spec compile(undefined | map()) -> undefined | config().
compile(undefined) ->
    undefined;
compile(Opts) when is_map(Opts) ->
    Trusted = compile_trusted(maps:get(trusted_proxies, Opts, undefined)),
    Header = compile_header(maps:get(header, Opts, ~"x-forwarded-for")),
    ok = reject_unknown_keys(Opts),
    #{trusted => Trusted, header => Header};
compile(Other) ->
    error({invalid_listener_opt, real_ip, Other}).

-doc """
Per-connection resolution state, built once by `prepare/2`.

`undefined` when the opt is off or the peer is unknown (no per-request work at
all). `{const, IP}` when the immediate peer is not a configured proxy: its
forwarded header is never honored, so every request on the connection resolves
to the same address and `resolve/2` is a field read. `{walk, ...}` when the peer
IS a trusted proxy and the answer therefore varies per request with the
forwarded header.
""".
-type prepared() ::
    undefined
    | {const, inet:ip_address()}
    | {walk, [cidr()], binary(), inet:ip_address()}.

-doc """
Build the per-connection resolution state from the compiled config and the
connection's peer.

The peer is fixed for the life of a connection, so whether it is a trusted proxy
(and its v4-mapped-IPv6 normalization) is decided here, once, instead of on
every request. An untrusted peer collapses to a constant answer; only a trusted
one needs the per-request header walk.
""".
-spec prepare(undefined | config(), Peer) -> prepared() when
    Peer :: {inet:ip_address(), inet:port_number()} | undefined.
prepare(undefined, _Peer) ->
    undefined;
prepare(_Config, undefined) ->
    undefined;
prepare(#{trusted := Trusted, header := HeaderName}, {PeerIP0, _Port}) ->
    PeerIP = unmap(PeerIP0),
    case trusted(PeerIP, Trusted) of
        false ->
            %% The immediate peer is not a configured proxy: never honor its
            %% forwarded header (it could be a direct client spoofing one).
            {const, PeerIP};
        true ->
            {walk, Trusted, HeaderName, PeerIP}
    end.

-doc """
Resolve the real client IP for one request against the prepared state.

`Headers` is the request's header list (names already lowercased on every
protocol path). Falls back to the peer's IP when the forwarded header is absent
or its nearest hop is malformed.
""".
-spec resolve(prepared(), roadrunner_http:headers()) -> inet:ip_address().
resolve({const, IP}, _Headers) ->
    IP;
resolve({walk, Trusted, HeaderName, PeerIP}, Headers) ->
    case header_chain(HeaderName, Headers) of
        [] -> PeerIP;
        Chain -> walk(Chain, Trusted, PeerIP)
    end.

%% --- config compilation (init time) ---

-spec compile_trusted(term()) -> [cidr(), ...].
compile_trusted(undefined) ->
    error({invalid_listener_opt, real_ip, trusted_proxies_required});
compile_trusted([]) ->
    error({invalid_listener_opt, real_ip, empty_trusted_proxies});
compile_trusted(Proxies) when is_list(Proxies) ->
    [compile_cidr(P) || P <- Proxies];
compile_trusted(Other) ->
    error({invalid_listener_opt, real_ip, {trusted_proxies, Other}}).

-spec compile_cidr(term()) -> cidr().
compile_cidr(Bin) when is_binary(Bin) ->
    case binary:split(Bin, ~"/") of
        [AddrBin, PrefixBin] ->
            {Addr, Family, TotalBits} = parse_addr(AddrBin),
            make_cidr(Addr, Family, TotalBits, parse_prefix(PrefixBin, TotalBits));
        [AddrBin] ->
            {Addr, Family, TotalBits} = parse_addr(AddrBin),
            make_cidr(Addr, Family, TotalBits, TotalBits)
    end;
compile_cidr(Other) ->
    error({invalid_listener_opt, real_ip, {trusted_proxy, Other}}).

-spec parse_addr(binary()) -> {inet:ip_address(), 4 | 8, 32 | 128}.
parse_addr(AddrBin) ->
    case inet:parse_address(binary_to_list(AddrBin)) of
        {ok, Addr} when tuple_size(Addr) =:= 4 -> {Addr, 4, 32};
        {ok, Addr} when tuple_size(Addr) =:= 8 -> {Addr, 8, 128};
        _ -> error({invalid_listener_opt, real_ip, {trusted_proxy, AddrBin}})
    end.

-spec parse_prefix(binary(), 32 | 128) -> non_neg_integer().
parse_prefix(PrefixBin, TotalBits) ->
    case string:to_integer(PrefixBin) of
        {N, <<>>} when N >= 0, N =< TotalBits -> N;
        _ -> error({invalid_listener_opt, real_ip, {prefix, PrefixBin}})
    end.

-spec make_cidr(inet:ip_address(), 4 | 8, 32 | 128, non_neg_integer()) -> cidr().
make_cidr(Addr, Family, TotalBits, Prefix) ->
    Shift = TotalBits - Prefix,
    {Family, ip_to_int(Addr) bsr Shift, Shift}.

-spec compile_header(term()) -> binary().
compile_header(H) when is_binary(H), byte_size(H) > 0 ->
    roadrunner_bin:ascii_lowercase(H);
compile_header(Other) ->
    error({invalid_listener_opt, real_ip, {header, Other}}).

-spec reject_unknown_keys(map()) -> ok.
reject_unknown_keys(Opts) ->
    case maps:keys(maps:without([trusted_proxies, header], Opts)) of
        [] -> ok;
        Unknown -> error({invalid_listener_opt, real_ip, {unknown_keys, Unknown}})
    end.

%% --- resolution (hot path, only when configured) ---

%% Collect every instance of the forwarded header, in received order, as one
%% left-to-right list of raw (unparsed) comma-separated segments. RFC 9110 §5.3:
%% repeated field lines are equivalent to the single comma-joined value, so a
%% proxy that emits the chain as separate lines is handled the same as one that
%% combines it — and the right-to-left walk still lands on the nearest untrusted
%% hop.
%%
%% Segments are deliberately left unparsed here. The walk reads the chain
%% right-to-left and stops at the first untrusted hop, which is normally the
%% first or second entry, while everything to the left of the proxy's own append
%% is supplied by the client. Parsing the whole chain up front would spend an
%% `inet:parse_address` call (and its list conversion) on every attacker-chosen
%% entry the walk then never consults.
-spec header_chain(binary(), roadrunner_http:headers()) -> [binary()].
header_chain(HeaderName, Headers) ->
    [
        Part
     || {Name, Value} <- Headers,
        Name =:= HeaderName,
        Part <- binary:split(Value, persistent_term:get(?COMMA_CP_KEY), [global])
    ].

%% Parse one chain segment into `{ok, IP}` (with v4-mapped IPv6 unwrapped) or
%% `bad` when it is not an address.
-spec parse_entry(binary()) -> {ok, inet:ip_address()} | bad.
parse_entry(Part) ->
    case inet:parse_address(binary_to_list(roadrunner_bin:trim_ows(Part))) of
        {ok, IP} -> {ok, unmap(IP)};
        {error, _} -> bad
    end.

%% Walk the chain right-to-left (proxies append, so the rightmost entry is the
%% nearest hop): skip trusted proxies, return the first untrusted address (the
%% real client). All-trusted yields the leftmost entry; an empty chain or a
%% malformed nearest hop yields the carried fallback (the trusted hop to its
%% right, or the peer). Each segment is parsed only when the walk reaches it, so
%% a long client-supplied chain costs one reversal of sub-binaries plus the few
%% parses the walk actually consults.
-spec walk([binary(), ...], [cidr()], inet:ip_address()) -> inet:ip_address().
walk(Entries, Trusted, PeerIP) ->
    %% `binary:split/3` always yields a non-empty list, so `Entries` has at
    %% least one element; an empty chain can't reach here.
    do_walk(lists:reverse(Entries), PeerIP, Trusted).

-spec do_walk([binary()], inet:ip_address(), [cidr()]) -> inet:ip_address().
do_walk([], Fallback, _Trusted) ->
    Fallback;
do_walk([Part | Rest], Fallback, Trusted) ->
    case parse_entry(Part) of
        bad ->
            Fallback;
        {ok, IP} ->
            case trusted(IP, Trusted) of
                true -> do_walk(Rest, IP, Trusted);
                false -> IP
            end
    end.

-spec trusted(inet:ip_address(), [cidr()]) -> boolean().
trusted(IP, Trusted) ->
    is_trusted(ip_to_int(IP), tuple_size(IP), Trusted).

-spec is_trusted(non_neg_integer(), 4 | 8, [cidr()]) -> boolean().
is_trusted(_Int, _Fam, []) ->
    false;
is_trusted(Int, Fam, [{Fam, NetPrefix, Shift} | _]) when (Int bsr Shift) =:= NetPrefix ->
    true;
is_trusted(Int, Fam, [_ | Rest]) ->
    is_trusted(Int, Fam, Rest).

%% Collapse a v4-mapped IPv6 address (`::ffff:a.b.c.d`) to plain IPv4 so a
%% dual-stack proxy's mapped address matches IPv4 CIDRs.
-spec unmap(inet:ip_address()) -> inet:ip_address().
unmap({0, 0, 0, 0, 0, 16#ffff, G, H}) ->
    {G bsr 8, G band 16#ff, H bsr 8, H band 16#ff};
unmap(IP) ->
    IP.

-spec ip_to_int(inet:ip_address()) -> non_neg_integer().
ip_to_int({A, B, C, D}) ->
    (A bsl 24) bor (B bsl 16) bor (C bsl 8) bor D;
ip_to_int({A, B, C, D, E, F, G, H}) ->
    (A bsl 112) bor (B bsl 96) bor (C bsl 80) bor (D bsl 64) bor
        (E bsl 48) bor (F bsl 32) bor (G bsl 16) bor H.

-spec init_patterns() -> ok.
init_patterns() ->
    persistent_term:put(?COMMA_CP_KEY, binary:compile_pattern(~",")),
    ok.
