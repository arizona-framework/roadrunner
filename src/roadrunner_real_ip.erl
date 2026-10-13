-module(roadrunner_real_ip).
-moduledoc false.

%% Real client IP behind trusted reverse proxies (the `real_ip` listener
%% option). Behind an HTTP proxy the socket peer is the proxy, so the client
%% address has to come from the forwarding header the proxies append to.
%% Only a trusted proxy's header is believed, and only the part of it that
%% trusted proxies wrote: the chain is read right to left (each proxy appends
%% the address it received the request from), trusted hops are skipped, and
%% the first untrusted address is the client. Everything left of that is
%% client-supplied and never read.
%%
%% Cost model. `compile/1` validates and pre-computes at listener init.
%% `peer_trust/2` decides once per connection whether the peer is a trusted
%% proxy; when it is not (or the option is off) the connection resolves
%% nothing per request. `resolve/3` runs per request on trusted connections
%% only: it scans the header backwards from its end and stops at the first
%% untrusted hop, so its cost is bounded by the hops it reads, not by how
%% much a client stuffs to the left. IPv4 is parsed with bit syntax and
%% matched as one integer; IPv6 is matched word by word on the address
%% tuple, never as a bignum.

-on_load(init_patterns/0).

-export([compile/1, peer_trust/2, resolve/3]).

-export_type([config/0]).

-define(SEMI_CP_KEY, {?MODULE, semi_cp}).
-define(EQ_CP_KEY, {?MODULE, eq_cp}).
%% Longest IPv6 text form (with an embedded IPv4 tail) is 45 bytes; anything
%% longer is not an address and is rejected before any list conversion.
-define(MAX_IP6_TEXT, 45).

-type header() :: x_forwarded_for | forwarded.
%% An IPv4 CIDR as {Net, Shift}: an address Int is inside when
%% Int bsr Shift =:= Net.
-type cidr4() :: {non_neg_integer(), 0..31}.
%% An IPv6 CIDR as the {Index, Mask, Value} checks its prefix makes on the
%% 16-bit words of the address tuple.
-type cidr6() :: [{1..8, 1..16#FFFF, 0..16#FFFF}, ...].
-type config() ::
    {cidrs, header(), {[cidr4()], [cidr6()]}}
    | {hops, header(), pos_integer()}.

%% Compile the `real_ip` listener option: `undefined` (off) or a map with
%% exactly one of `trusted_proxies` (CIDR binaries) and `trusted_hops`, and an
%% optional `header` (`x_forwarded_for`, the default, or `forwarded`). Raises
%% `{invalid_listener_opt, real_ip, Opts}` on anything else.
-doc false.
-spec compile(term()) -> undefined | config().
compile(undefined) ->
    undefined;
compile(Opts) when is_map(Opts) ->
    case compile_map(Opts) of
        {ok, Config} -> Config;
        error -> error({invalid_listener_opt, real_ip, Opts})
    end;
compile(Other) ->
    error({invalid_listener_opt, real_ip, Other}).

-spec compile_map(map()) -> {ok, config()} | error.
compile_map(Opts) ->
    maybe
        [] ?= maps:keys(maps:without([trusted_proxies, trusted_hops, header], Opts)),
        {ok, Header} ?= header(maps:get(header, Opts, x_forwarded_for)),
        trust(Opts, Header)
    else
        _ -> error
    end.

-spec header(term()) -> {ok, header()} | error.
header(x_forwarded_for) -> {ok, x_forwarded_for};
header(forwarded) -> {ok, forwarded};
header(_) -> error.

-spec trust(map(), header()) -> {ok, config()} | error.
trust(#{trusted_proxies := _, trusted_hops := _}, _Header) ->
    error;
trust(#{trusted_proxies := [_ | _] = Cidrs}, Header) ->
    case cidrs(Cidrs, [], []) of
        {ok, V4, V6} -> {ok, {cidrs, Header, {V4, V6}}};
        error -> error
    end;
trust(#{trusted_hops := Hops}, Header) when is_integer(Hops), Hops > 0 ->
    {ok, {hops, Header, Hops}};
trust(_Opts, _Header) ->
    error.

-spec cidrs([term()], [cidr4()], [cidr6()]) -> {ok, [cidr4()], [cidr6()]} | error.
cidrs([], V4, V6) ->
    {ok, V4, V6};
cidrs([Cidr | Rest], V4, V6) ->
    case cidr(Cidr) of
        {v4, C} -> cidrs(Rest, [C | V4], V6);
        {v6, C} -> cidrs(Rest, V4, [C | V6]);
        error -> error
    end.

%% One `trusted_proxies` entry: an address with an optional `/Len` prefix
%% length (a bare address is one host). The address must be in strict
%% notation, so `010.0.0.0` or `10/8` cannot quietly trust some other range.
%% A `/0` prefix is refused: it would trust every hop, including the ones a
%% client writes itself, which is what `trusted_hops` is for. An IPv4-mapped
%% IPv6 range covers the IPv4 range it maps, since peers and hops are
%% unmapped before matching, so a mapped `/96`, all of IPv4, is refused as
%% `0.0.0.0/0` is.
-spec cidr(term()) -> {v4, cidr4()} | {v6, cidr6()} | error.
cidr(Cidr) when is_binary(Cidr) ->
    {Addr, Len} =
        case split_at($/, Cidr) of
            {A, L} -> {A, prefix_len(L)};
            nomatch -> {Cidr, host}
        end,
    case byte_size(Addr) =< ?MAX_IP6_TEXT andalso inet:parse_strict_address(binary_to_list(Addr)) of
        {ok, {_, _, _, _} = IP} ->
            cidr4(IP, Len);
        {ok, {0, 0, 0, 0, 0, 16#FFFF, _, _} = IP} when Len =:= host -> cidr4(unmap(IP), host);
        {ok, {0, 0, 0, 0, 0, 16#FFFF, _, _} = IP} when is_integer(Len), Len >= 96 ->
            cidr4(unmap(IP), Len - 96);
        {ok, IP} ->
            cidr6(IP, Len);
        _ ->
            error
    end;
cidr(_Other) ->
    error.

-spec prefix_len(binary()) -> non_neg_integer() | error.
prefix_len(<<D, _/binary>> = L) when D >= $0, D =< $9, byte_size(L) =< 3 ->
    case roadrunner_bin:digits_to_integer(L) of
        {ok, N} -> N;
        error -> error
    end;
prefix_len(_) ->
    error.

-spec cidr4(inet:ip4_address(), host | non_neg_integer() | error) -> {v4, cidr4()} | error.
cidr4(IP, host) ->
    cidr4(IP, 32);
cidr4(IP, Len) when is_integer(Len), Len >= 1, Len =< 32 ->
    Shift = 32 - Len,
    {v4, {ip4_int(IP) bsr Shift, Shift}};
cidr4(_IP, _Len) ->
    error.

-spec cidr6(inet:ip6_address(), host | non_neg_integer() | error) -> {v6, cidr6()} | error.
cidr6(IP, host) ->
    cidr6(IP, 128);
cidr6(IP, Len) when is_integer(Len), Len >= 1, Len =< 128 ->
    {v6, word_checks(IP, Len, 1)};
cidr6(_IP, _Len) ->
    error.

%% The word checks a `/Len` prefix makes: whole 16-bit words first, then the
%% leading bits of the word the prefix ends in. Body recursion keeps them in
%% word order, so a mismatch on a leading word is found first.
-spec word_checks(inet:ip6_address(), non_neg_integer(), 1..9) -> [{1..8, 1..16#FFFF, 0..16#FFFF}].
word_checks(_IP, 0, _Index) ->
    [];
word_checks(IP, Len, Index) when Len >= 16 ->
    [{Index, 16#FFFF, element(Index, IP)} | word_checks(IP, Len - 16, Index + 1)];
word_checks(IP, Len, Index) ->
    Mask = (16#FFFF bsl (16 - Len)) band 16#FFFF,
    [{Index, Mask, element(Index, IP) band Mask}].

%% Whether a connection's requests resolve a client address: the trust
%% config when the peer is a trusted proxy (every peer counts as the first
%% hop in `trusted_hops` mode), `undefined` when the option is off, the peer
%% is not trusted, or there is no peer. Called once per connection, so an
%% untrusted connection pays nothing per request.
-doc false.
-spec peer_trust(undefined | config(), {inet:ip_address(), inet:port_number()} | undefined) ->
    undefined | config().
peer_trust({hops, _Header, _N} = Config, {_IP, _Port}) ->
    Config;
peer_trust({cidrs, _Header, {V4, V6}} = Config, {IP, _Port}) ->
    case in_cidrs(unmap(IP), V4, V6) of
        true -> Config;
        false -> undefined
    end;
peer_trust(_Config, _Peer) ->
    undefined.

%% The client address of one request on a trusted connection: walk the
%% forwarding header right to left from the peer (hop 0), skip trusted hops,
%% and return the first untrusted one. A hop that is not an address ends the
%% walk with the last trusted hop to its right (the peer if it is the first);
%% a chain of only trusted hops gives its leftmost. Repeated header lines are
%% one comma-joined value (RFC 9110 §5.3), read from the last line back.
-doc false.
-spec resolve(config(), inet:ip_address(), roadrunner_http:headers()) -> inet:ip_address().
resolve({_Mode, Header, _Trust} = Config, PeerIP, Headers) ->
    walk_lines(lines(header_name(Header), Headers, []), Config, unmap(PeerIP), 1).

-spec header_name(header()) -> binary().
header_name(x_forwarded_for) -> ~"x-forwarded-for";
header_name(forwarded) -> ~"forwarded".

%% The header's lines, last first.
-spec lines(binary(), roadrunner_http:headers(), [binary()]) -> [binary()].
lines(Name, [{Name, Value} | Rest], Acc) -> lines(Name, Rest, [Value | Acc]);
lines(Name, [_ | Rest], Acc) -> lines(Name, Rest, Acc);
lines(_Name, [], Acc) -> Acc.

-spec walk_lines([binary()], config(), inet:ip_address(), pos_integer()) -> inet:ip_address().
walk_lines([], _Config, Fallback, _Hop) ->
    Fallback;
walk_lines([Line | Lines], Config, Fallback, Hop) ->
    walk_line(Line, byte_size(Line), Lines, Config, Fallback, Hop).

%% Read the entry ending at byte `End` of `Line` (the bytes after the last
%% comma before `End`), then the one before it, until an untrusted hop.
-spec walk_line(
    binary(), non_neg_integer(), [binary()], config(), inet:ip_address(), pos_integer()
) -> inet:ip_address().
walk_line(Line, End, Lines, {_Mode, Header, _Trust} = Config, Fallback, Hop) ->
    Start = entry_start(Line, End - 1),
    Len = End - Start,
    <<_:Start/binary, Entry:Len/binary, _/binary>> = Line,
    case hop_address(Header, Entry) of
        bad ->
            Fallback;
        IP ->
            case trusted(Config, IP, Hop) of
                false -> IP;
                true when Start =:= 0 -> walk_lines(Lines, Config, IP, Hop + 1);
                true -> walk_line(Line, Start - 1, Lines, Config, IP, Hop + 1)
            end
    end.

%% Index of the first byte of the entry ending before byte `I + 1`: one past
%% the nearest comma at or before `I`, or 0.
-spec entry_start(binary(), integer()) -> non_neg_integer().
entry_start(_Line, -1) ->
    0;
entry_start(Line, I) ->
    case Line of
        <<_:I/binary, $,, _/binary>> -> I + 1;
        _ -> entry_start(Line, I - 1)
    end.

-spec trusted(config(), inet:ip_address(), pos_integer()) -> boolean().
trusted({cidrs, _Header, {V4, V6}}, IP, _Hop) -> in_cidrs(IP, V4, V6);
trusted({hops, _Header, Hops}, _IP, Hop) -> Hop < Hops.

%% The address one header entry names, or `bad`.
-spec hop_address(header(), binary()) -> inet:ip_address() | bad.
hop_address(x_forwarded_for, Entry) ->
    node_address(roadrunner_bin:trim_ows(Entry));
hop_address(forwarded, Element) ->
    for_param(binary:split(Element, persistent_term:get(?SEMI_CP_KEY), [global])).

%% The `for=` parameter of one `Forwarded` element (RFC 7239 §4): parameter
%% names are case-insensitive and a value may be a quoted string, as an IPv6
%% node with a port has to be. `unknown` and obfuscated identifiers are not
%% addresses, so they end the walk like any other non-address hop.
-spec for_param([binary()]) -> inet:ip_address() | bad.
for_param([]) ->
    bad;
for_param([Pair | Rest]) ->
    case binary:split(Pair, persistent_term:get(?EQ_CP_KEY)) of
        [Key, Value] ->
            case roadrunner_bin:ascii_lowercase(roadrunner_bin:trim_ows(Key)) of
                ~"for" -> node_address(unquote(roadrunner_bin:trim_ows(Value)));
                _ -> for_param(Rest)
            end;
        [_] ->
            for_param(Rest)
    end.

-spec unquote(binary()) -> binary().
unquote(<<$", Rest/binary>> = Quoted) ->
    Len = byte_size(Rest) - 1,
    case Rest of
        <<Inner:Len/binary, $">> -> Inner;
        _ -> Quoted
    end;
unquote(Value) ->
    Value.

%% A node: IPv4, IPv4 with `:port`, bare IPv6, or bracketed IPv6 with an
%% optional `:port` (RFC 7239 §6; proxies such as Azure Application Gateway
%% and IIS ARR also send ports in `X-Forwarded-For`). Mapped IPv6 is
%% unmapped, so it compares equal to the IPv4 address it carries.
-spec node_address(binary()) -> inet:ip_address() | bad.
node_address(<<$[, Rest/binary>>) ->
    case split_at($], Rest) of
        {IP6, <<>>} -> ip6(IP6);
        {IP6, <<$:, Port/binary>>} -> with_port(Port, ip6(IP6));
        _ -> bad
    end;
node_address(Node) ->
    case ip4(Node) of
        bad -> ip6(Node);
        IP -> IP
    end.

-spec with_port(binary(), inet:ip_address() | bad) -> inet:ip_address() | bad.
with_port(Port, IP) ->
    case port(Port) of
        true -> IP;
        false -> bad
    end.

%% Strict dotted-quad IPv4 with an optional `:port`: four decimal octets,
%% 0-255, no leading zeros.
-spec ip4(binary()) -> inet:ip4_address() | bad.
ip4(Node) ->
    maybe
        {A, <<$., R1/binary>>} ?= octet(Node),
        {B, <<$., R2/binary>>} ?= octet(R1),
        {C, <<$., R3/binary>>} ?= octet(R2),
        {D, Tail} ?= octet(R3),
        true ?= tail_port(Tail),
        {A, B, C, D}
    else
        _ -> bad
    end.

-spec octet(binary()) -> {0..255, binary()} | bad.
octet(<<$0, Rest/binary>>) ->
    {0, Rest};
octet(<<D, Rest/binary>>) when D >= $1, D =< $9 ->
    octet(Rest, D - $0, 1);
octet(_) ->
    bad.

-spec octet(binary(), non_neg_integer(), 1..3) -> {0..255, binary()} | bad.
octet(<<D, Rest/binary>>, Value, Digits) when D >= $0, D =< $9, Digits < 3 ->
    octet(Rest, Value * 10 + D - $0, Digits + 1);
octet(Rest, Value, _Digits) when Value =< 255 ->
    {Value, Rest};
octet(_Rest, _Value, _Digits) ->
    bad.

-spec tail_port(binary()) -> boolean().
tail_port(<<>>) -> true;
tail_port(<<$:, Port/binary>>) -> port(Port);
tail_port(_) -> false.

%% One to five decimal digits.
-spec port(binary()) -> boolean().
port(<<D, Rest/binary>>) when D >= $0, D =< $9, byte_size(Rest) < 5 -> digits(Rest);
port(_) -> false.

-spec digits(binary()) -> boolean().
digits(<<D, Rest/binary>>) when D >= $0, D =< $9 -> digits(Rest);
digits(<<>>) -> true;
digits(_) -> false.

%% IPv6 in strict notation, unmapped when it carries IPv4.
-spec ip6(binary()) -> inet:ip_address() | bad.
ip6(Text) when byte_size(Text) =< ?MAX_IP6_TEXT ->
    case inet:parse_strict_address(binary_to_list(Text)) of
        {ok, {_, _, _, _, _, _, _, _} = IP} -> unmap(IP);
        _ -> bad
    end;
ip6(_Text) ->
    bad.

%% `Bin` split around its first `Char`, or `nomatch`. The inputs are one
%% short header entry or one config string, so a byte walk beats setting up a
%% `binary:split/2` pattern.
-spec split_at(byte(), binary()) -> {binary(), binary()} | nomatch.
split_at(Char, Bin) ->
    split_at(Char, Bin, 0).

-spec split_at(byte(), binary(), non_neg_integer()) -> {binary(), binary()} | nomatch.
split_at(Char, Bin, I) ->
    case Bin of
        <<Before:I/binary, Char, After/binary>> -> {Before, After};
        <<_:I/binary, _, _/binary>> -> split_at(Char, Bin, I + 1);
        _ -> nomatch
    end.

-spec unmap(inet:ip_address()) -> inet:ip_address().
unmap({0, 0, 0, 0, 0, 16#FFFF, AB, CD}) -> {AB bsr 8, AB band 16#FF, CD bsr 8, CD band 16#FF};
unmap(IP) -> IP.

-spec in_cidrs(inet:ip_address(), [cidr4()], [cidr6()]) -> boolean().
in_cidrs({_, _, _, _} = IP, V4, _V6) -> in4(ip4_int(IP), V4);
in_cidrs(IP, _V4, V6) -> in6(IP, V6).

-spec in4(non_neg_integer(), [cidr4()]) -> boolean().
in4(_Int, []) ->
    false;
in4(Int, [{Net, Shift} | Rest]) ->
    case Int bsr Shift of
        Net -> true;
        _ -> in4(Int, Rest)
    end.

-spec in6(inet:ip6_address(), [cidr6()]) -> boolean().
in6(_IP, []) -> false;
in6(IP, [Checks | Rest]) -> words_match(IP, Checks) orelse in6(IP, Rest).

-spec words_match(inet:ip6_address(), [{1..8, 1..16#FFFF, 0..16#FFFF}]) -> boolean().
words_match(_IP, []) ->
    true;
words_match(IP, [{Index, Mask, Value} | Rest]) ->
    case element(Index, IP) band Mask of
        Value -> words_match(IP, Rest);
        _ -> false
    end.

-spec ip4_int(inet:ip4_address()) -> non_neg_integer().
ip4_int({A, B, C, D}) -> (A bsl 24) bor (B bsl 16) bor (C bsl 8) bor D.

%% `-on_load` callback: compile the `Forwarded` element separators once.
-spec init_patterns() -> ok.
init_patterns() ->
    persistent_term:put(?SEMI_CP_KEY, binary:compile_pattern(~";")),
    persistent_term:put(?EQ_CP_KEY, binary:compile_pattern(~"=")),
    ok.
