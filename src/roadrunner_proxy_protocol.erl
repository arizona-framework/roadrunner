-module(roadrunner_proxy_protocol).
-moduledoc false.

%% The HAProxy PROXY protocol header parser (v1 text and v2 binary), used by
%% the connection loop when a listener sets `proxy_protocol => true`. An L4
%% (TCP) load balancer prepends this header before the first application byte
%% so the server learns the real client address instead of the balancer's.
%%
%% Pure and socket-free: the conn loop reads bytes off the (passive) socket
%% and feeds them here; `parse/1` returns one of
%%
%% - `{ok, {Ip, Port}, Rest}` — a PROXY command carrying the real client
%%   address; `Rest` is the bytes after the header (the start of the first
%%   request / the h2 preface, which a coalesced segment can carry).
%% - `{local, Rest}` — a LOCAL command (v2) or `UNKNOWN` transport (v1): the
%%   sender is the balancer's own health check, so keep the OS peer.
%% - `more` — the buffer holds a valid prefix of a header but not the whole
%%   thing yet; read more bytes and call again with the accumulated buffer.
%% - `{error, Reason}` — not a PROXY header, or a malformed one. The caller
%%   closes the connection (the opt is only set behind a trusted balancer
%%   that ALWAYS prepends the header, so a missing/bad one is a hard error).
%%
%% v1: RFC-less HAProxy spec §2.1 — `PROXY TCP4 <src> <dst> <sport> <dport>\r\n`
%% (or `TCP6`, or `UNKNOWN`), at most 107 bytes including the CRLF.
%% v2: spec §2.2 — a 12-byte signature, a version/command byte, an
%% address-family/transport byte, a 16-bit address-block length, then the
%% addresses (and optional TLVs, which we skip).

-export([parse/1]).

-on_load(init_patterns/0).

%% Compiled binary:split patterns, stashed in persistent_term at load (the
%% project convention — never inline-compile on the path).
-define(CRLF_CP_KEY, {?MODULE, crlf_cp}).
-define(SPACE_CP_KEY, {?MODULE, space_cp}).

%% v2 signature: the fixed 12 bytes that open every binary header (spec §2.2).
-define(V2_SIG, 16#0D, 16#0A, 16#0D, 16#0A, 16#00, 16#0D, 16#0A, 16#51, 16#55, 16#49, 16#54, 16#0A).
-define(V2_SIG_BIN, <<?V2_SIG>>).
%% A v1 header (including the CRLF) never exceeds 107 bytes.
-define(V1_MAX, 107).

-type peer() :: {inet:ip_address(), inet:port_number()}.

-doc """
Parse a leading PROXY header from `Bin`. See the moduledoc for the result
shapes. `Bin` is the bytes accumulated so far; on `more`, accumulate more and
call again.
""".
-spec parse(binary()) ->
    {ok, peer(), binary()} | {local, binary()} | more | {error, term()}.
parse(<<?V2_SIG, Rest/binary>>) ->
    parse_v2(Rest);
parse(<<"PROXY ", Rest/binary>>) ->
    parse_v1(Rest);
parse(Bin) ->
    %% Not yet a recognizable header. If the bytes are still a prefix of a v1
    %% or v2 signature, more may complete it; otherwise it is not a PROXY
    %% header at all.
    case is_prefix(Bin, ?V2_SIG_BIN) orelse is_prefix(Bin, <<"PROXY ">>) of
        true -> more;
        false -> {error, not_proxy_header}
    end.

%% =============================================================================
%% v1 (text)
%% =============================================================================

%% `Rest` is everything after the `PROXY ` prefix. The line ends at the first
%% CRLF; the whole header (prefix included) must fit in 107 bytes.
-spec parse_v1(binary()) -> {ok, peer(), binary()} | {local, binary()} | more | {error, term()}.
parse_v1(Rest) ->
    case binary:split(Rest, persistent_term:get(?CRLF_CP_KEY)) of
        [Line, After] when byte_size(Line) =< ?V1_MAX - 8 ->
            %% 8 = byte_size("PROXY ") + byte_size("\r\n").
            parse_v1_fields(
                binary:split(Line, persistent_term:get(?SPACE_CP_KEY), [global]), After
            );
        [Line, _After] when byte_size(Line) > ?V1_MAX - 8 ->
            {error, v1_too_long};
        [Partial] when byte_size(Partial) =< ?V1_MAX - 8 ->
            %% No CRLF yet, still within the size budget — wait for more.
            more;
        [_Partial] ->
            {error, v1_too_long}
    end.

-spec parse_v1_fields([binary()], binary()) ->
    {ok, peer(), binary()} | {local, binary()} | {error, term()}.
parse_v1_fields([Proto, SrcIp, _DstIp, SrcPort, _DstPort], After) when
    Proto =:= ~"TCP4"; Proto =:= ~"TCP6"
->
    maybe
        {ok, Ip} ?= parse_ip(SrcIp, Proto),
        {ok, Port} ?= parse_port(SrcPort),
        {ok, {Ip, Port}, After}
    end;
parse_v1_fields([~"UNKNOWN" | _], After) ->
    %% `UNKNOWN`: the sender could not determine the addresses (e.g. a health
    %% check). Keep the OS peer; the remaining fields, if any, are ignored.
    {local, After};
parse_v1_fields(_, _After) ->
    {error, v1_malformed}.

-spec parse_ip(binary(), binary()) -> {ok, inet:ip_address()} | {error, term()}.
parse_ip(Bin, Proto) ->
    case inet:parse_address(binary_to_list(Bin)) of
        {ok, Ip} when Proto =:= ~"TCP4", tuple_size(Ip) =:= 4 -> {ok, Ip};
        {ok, Ip} when Proto =:= ~"TCP6", tuple_size(Ip) =:= 8 -> {ok, Ip};
        _ -> {error, v1_bad_address}
    end.

-spec parse_port(binary()) -> {ok, inet:port_number()} | {error, term()}.
parse_port(Bin) ->
    case string:to_integer(Bin) of
        {Port, <<>>} when is_integer(Port), Port >= 0, Port =< 65535 -> {ok, Port};
        _ -> {error, v1_bad_port}
    end.

%% =============================================================================
%% v2 (binary)
%% =============================================================================

%% `Rest` is everything after the 12-byte signature: the version/command byte,
%% the family/transport byte, a 16-bit address-block length, then that many
%% bytes of address block (and optional TLVs we skip), then the leftover.
-spec parse_v2(binary()) -> {ok, peer(), binary()} | {local, binary()} | more | {error, term()}.
parse_v2(<<Ver:4, Cmd:4, Fam:4, Trans:4, Len:16, Body:Len/binary, After/binary>>) when
    Ver =:= 2
->
    parse_v2_command(Cmd, Fam, Trans, Body, After);
parse_v2(<<Ver:4, _Cmd:4, _/binary>>) when Ver =/= 2 ->
    {error, v2_bad_version};
parse_v2(_Partial) ->
    %% The signature matched but the header (length-declared body included) is
    %% not all here yet.
    more.

-spec parse_v2_command(0..15, 0..15, 0..15, binary(), binary()) ->
    {ok, peer(), binary()} | {local, binary()} | {error, term()}.
parse_v2_command(16#1, Fam, Trans, Body, After) ->
    %% PROXY command (0x1): a real connection. Parse the source address for an
    %% INET/INET6 stream; anything else (AF_UNIX, UNSPEC) keeps the OS peer.
    parse_v2_addr(Fam, Trans, Body, After);
parse_v2_command(16#0, _Fam, _Trans, _Body, After) ->
    %% LOCAL command (0x0): the sender's own connection (a health check). Keep
    %% the OS peer; the address block is present but ignored.
    {local, After};
parse_v2_command(_Cmd, _Fam, _Trans, _Body, _After) ->
    {error, v2_bad_command}.

-spec parse_v2_addr(0..15, 0..15, binary(), binary()) ->
    {ok, peer(), binary()} | {local, binary()} | {error, term()}.
parse_v2_addr(
    16#1, 16#1, <<A, B, C, D, _Dst:4/binary, SrcPort:16, _DstPort:16, _Tlv/binary>>, After
) ->
    %% AF_INET (0x1) + STREAM (0x1).
    {ok, {{A, B, C, D}, SrcPort}, After};
parse_v2_addr(
    16#2,
    16#1,
    <<S1:16, S2:16, S3:16, S4:16, S5:16, S6:16, S7:16, S8:16, _Dst:16/binary, SrcPort:16,
        _DstPort:16, _Tlv/binary>>,
    After
) ->
    %% AF_INET6 (0x2) + STREAM (0x1).
    {ok, {{S1, S2, S3, S4, S5, S6, S7, S8}, SrcPort}, After};
parse_v2_addr(Fam, _Trans, _Body, After) when Fam =:= 16#0; Fam =:= 16#3 ->
    %% AF_UNSPEC (0x0) or AF_UNIX (0x3): no IP peer to report; keep the OS peer.
    {local, After};
parse_v2_addr(_Fam, _Trans, _Body, _After) ->
    {error, v2_bad_address}.

%% =============================================================================
%% Internal
%% =============================================================================

%% Whether `Bin` is a (proper or full) prefix of `Full` — i.e. reading more
%% bytes could still complete `Full`.
-spec is_prefix(binary(), binary()) -> boolean().
is_prefix(Bin, Full) when byte_size(Bin) =< byte_size(Full) ->
    Len = byte_size(Bin),
    case Full of
        <<Bin:Len/binary, _/binary>> -> true;
        _ -> false
    end;
is_prefix(_Bin, _Full) ->
    false.

%% `-on_load` callback: compile the v1 line/field split patterns once.
-spec init_patterns() -> ok.
init_patterns() ->
    persistent_term:put(?CRLF_CP_KEY, binary:compile_pattern(~"\r\n")),
    persistent_term:put(?SPACE_CP_KEY, binary:compile_pattern(~" ")),
    ok.
