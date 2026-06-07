-module(roadrunner_quic_packet).
-moduledoc false.

%% QUIC packet header codec (RFC 9000 §17), pure wire syntax.
%%
%% Long header (Initial / Handshake / 0-RTT) and short header (1-RTT)
%% parse and build, the truncated packet-number coding (§17.1), and the
%% two helpers the receive path needs before header protection is removed
%% (RFC 9001 §5.4):
%%
%% - `dcid/2` extracts the Destination Connection ID so the listener can
%%   route a datagram to its connection, and
%% - `pn_offset/2` locates the Packet Number field so the AEAD layer can
%%   take its header-protection sample (16 bytes at `pn_offset + 4`).
%%
%% Both read only header-protection-independent bytes, so they work on a
%% still-protected packet. `decode/2` reads the packet number and slices
%% the payload, so it runs only after header protection has been removed.
%% Packet/header protection itself lives in `roadrunner_quic_aead`; this
%% module is the header layout alone, and it never crashes on a malformed
%% datagram (every short read returns `{error, truncated}`).
%%
%% Encoders return an iolist (the payload, already AEAD-sealed by the
%% caller, is kept by reference); the leading element is the header that
%% doubles as the AEAD associated data.

-export([
    encode_long/5,
    encode_short/4,
    encode_short/5,
    encode_version_negotiation/3,
    decode/2,
    dcid/2,
    coalesced_split/1,
    pn_offset/2,
    encode_pn/2,
    decode_pn/2,
    pn_length/1,
    key_phase/1
]).

-export_type([packet/0, long_type/0]).

%% RFC 9000 §17.2: a Connection ID is at most 20 bytes.
-define(MAX_CID, 20).
%% A defensive cap on an address-validation token (RFC 9000 §8.1).
-define(MAX_TOKEN, 512).

-type long_type() :: initial | handshake | zero_rtt.

-type packet() ::
    #{
        type := initial | handshake | zero_rtt | one_rtt,
        version => non_neg_integer(),
        dcid := binary(),
        scid => binary(),
        token => binary(),
        pn := non_neg_integer(),
        payload := binary()
    }.

-type long_opts() :: #{
    token => binary(),
    pn => non_neg_integer(),
    payload => iodata()
}.

%% =============================================================================
%% Packet building
%% =============================================================================

-doc """
Build a long-header packet (RFC 9000 §17.2). `payload` is the already
AEAD-sealed ciphertext; the returned iolist's first element is the
unprotected header (through the packet number), which the caller uses as
the AEAD associated data and then header-protects.
""".
-spec encode_long(long_type(), non_neg_integer(), binary(), binary(), long_opts()) -> iolist().
encode_long(Type, Version, DCID, SCID, Opts) ->
    PN = maps:get(pn, Opts, 0),
    Payload = maps:get(payload, Opts, <<>>),
    PNLen = pn_length(PN),
    %% First byte: 1 (long) 1 (fixed) TT (type) RR (reserved 0) PP (pnlen-1).
    FirstByte = 2#11000000 bor (type_bits(Type) bsl 4) bor (PNLen - 1),
    Length = PNLen + iolist_size(Payload),
    Header = <<
        FirstByte,
        Version:32,
        (byte_size(DCID)):8,
        DCID/binary,
        (byte_size(SCID)):8,
        SCID/binary,
        (long_prefix(Type, Opts))/binary,
        (roadrunner_quic_varint:encode(Length))/binary,
        (encode_pn(PN, PNLen))/binary
    >>,
    [Header, Payload].

%% Initial packets carry a token (RFC 9000 §17.2.2); the other long types
%% have nothing between the connection IDs and the Length field.
-spec long_prefix(long_type(), long_opts()) -> binary().
long_prefix(initial, Opts) ->
    Token = maps:get(token, Opts, <<>>),
    <<(roadrunner_quic_varint:encode(byte_size(Token)))/binary, Token/binary>>;
long_prefix(_Type, _Opts) ->
    <<>>.

-doc "Build a 1-RTT short-header packet (RFC 9000 §17.3) with key phase 0.".
-spec encode_short(binary(), non_neg_integer(), iodata(), boolean()) -> iolist().
encode_short(DCID, PN, Payload, SpinBit) ->
    encode_short(DCID, PN, Payload, SpinBit, 0).

-doc "Build a 1-RTT short-header packet (RFC 9000 §17.3) with an explicit key phase.".
-spec encode_short(binary(), non_neg_integer(), iodata(), boolean(), 0 | 1) -> iolist().
encode_short(DCID, PN, Payload, SpinBit, KeyPhase) ->
    PNLen = pn_length(PN),
    %% First byte: 0 (short) 1 (fixed) S (spin) RR (reserved 0) K (key phase) PP.
    FirstByte =
        2#01000000 bor (bool_bit(SpinBit) bsl 5) bor ((KeyPhase band 1) bsl 2) bor (PNLen - 1),
    [<<FirstByte, DCID/binary, (encode_pn(PN, PNLen))/binary>>, Payload].

-doc """
Build a Version Negotiation packet (RFC 9000 §17.2.1). The unused bits of
the first byte are arbitrary; a fixed value is used so captures are
stable. `DCID`/`SCID` are the received SCID/DCID (swapped).
""".
-spec encode_version_negotiation(binary(), binary(), [non_neg_integer()]) -> iolist().
encode_version_negotiation(DCID, SCID, Versions) ->
    [
        <<
            16#C0,
            %% Version 0 marks a Version Negotiation packet.
            0:32,
            (byte_size(DCID)):8,
            DCID/binary,
            (byte_size(SCID)):8,
            SCID/binary
        >>
        | [<<V:32>> || V <- Versions]
    ].

%% =============================================================================
%% Receive-side helpers (header-protection independent)
%% =============================================================================

-doc """
Extract the Destination Connection ID so a datagram can be routed to its
connection. Reads only header-protection-independent bytes, so it works
on a still-protected packet. `DCIDLen` is the server's fixed connection-ID
length, used for short headers (which omit the length).
""".
-spec dcid(binary(), non_neg_integer()) -> {ok, binary()} | {error, term()}.
dcid(<<1:1, _:7, _Version:32, DCIDLen, Rest/binary>>, _DCIDLen) when DCIDLen =< ?MAX_CID ->
    case Rest of
        <<DCID:DCIDLen/binary, _/binary>> -> {ok, DCID};
        _ -> {error, truncated}
    end;
dcid(<<0:1, _:7, Rest/binary>>, DCIDLen) ->
    case Rest of
        <<DCID:DCIDLen/binary, _/binary>> -> {ok, DCID};
        _ -> {error, truncated}
    end;
dcid(_, _) ->
    {error, invalid_packet}.

-doc """
Split the first packet of a (possibly coalesced) datagram (RFC 9000
§12.2), reading only header-protection-independent bytes so it works on a
still-protected datagram. A long-header packet is bounded by its Length
field; a short-header packet carries no length and so runs to the end of
the datagram (it can only be the last packet). Returns `{ok, Packet, Rest}`
(`Rest` being the following coalesced packets), or `done` at the end of
the datagram or on trailing padding (a zero first byte / cleared fixed
bit), which the receive loop treats as a clean stop. A server never
receives Retry or Version Negotiation, so their lengthless layout is not
special-cased (such a packet mis-slices and is dropped downstream).
""".
-spec coalesced_split(binary()) -> {ok, binary(), binary()} | done | {error, term()}.
coalesced_split(<<>>) ->
    done;
coalesced_split(<<FirstByte, _/binary>>) when (FirstByte band 16#40) =:= 0 ->
    %% Fixed bit clear (includes a zero padding byte): no more packets.
    done;
coalesced_split(<<1:1, _:7, _Version:32, DCIDLen, Rest/binary>> = Bin) when DCIDLen =< ?MAX_CID ->
    <<FirstByte, _/binary>> = Bin,
    maybe
        {ok, AfterCids} ?= skip_scid(DCIDLen, Rest),
        {ok, AfterPrefix} ?= skip_token(bits_to_type((FirstByte bsr 4) band 2#11), AfterCids),
        {ok, Length, AfterLength} ?= take_varint(AfterPrefix),
        split_at(Bin, byte_size(Bin) - byte_size(AfterLength) + Length)
    end;
coalesced_split(<<0:1, _:7, _/binary>> = Bin) ->
    %% Short header: the packet runs to the end of the datagram.
    {ok, Bin, <<>>};
coalesced_split(_) ->
    {error, invalid_packet}.

-spec split_at(binary(), non_neg_integer()) -> {ok, binary(), binary()} | {error, truncated}.
split_at(Bin, PacketLen) ->
    case Bin of
        <<Packet:PacketLen/binary, Rest/binary>> -> {ok, Packet, Rest};
        _ -> {error, truncated}
    end.

-doc """
Locate the Packet Number field's byte offset, so the AEAD layer can take
the header-protection sample (16 bytes starting `pn_offset + 4`,
RFC 9001 §5.4.2). Reads only header-protection-independent bytes.
""".
-spec pn_offset(binary(), non_neg_integer()) -> {ok, non_neg_integer()} | {error, term()}.
pn_offset(<<0:1, _:7, _/binary>>, DCIDLen) ->
    %% Short header: first byte + the (implicit-length) DCID.
    {ok, 1 + DCIDLen};
pn_offset(<<FirstByte, _Version:32, DCIDLen, Rest/binary>> = Bin, _DCIDLen) when
    (FirstByte band 16#80) =:= 16#80, DCIDLen =< ?MAX_CID
->
    maybe
        {ok, AfterCids} ?= skip_scid(DCIDLen, Rest),
        {ok, AfterPrefix} ?= skip_token(bits_to_type((FirstByte bsr 4) band 2#11), AfterCids),
        %% After the Length varint comes the packet number.
        {ok, _Length, AfterLength} ?= take_varint(AfterPrefix),
        {ok, byte_size(Bin) - byte_size(AfterLength)}
    end;
pn_offset(_, _) ->
    {error, invalid_packet}.

%% Skip the DCID, the SCID length, and the SCID, given that `Bin` starts
%% at the DCID and the DCID is `DCIDLen` bytes.
-spec skip_scid(non_neg_integer(), binary()) -> {ok, binary()} | {error, truncated}.
skip_scid(DCIDLen, Bin) ->
    case Bin of
        <<_DCID:DCIDLen/binary, SCIDLen, Rest/binary>> when SCIDLen =< ?MAX_CID ->
            case Rest of
                <<_SCID:SCIDLen/binary, AfterCids/binary>> -> {ok, AfterCids};
                _ -> {error, truncated}
            end;
        _ ->
            {error, truncated}
    end.

%% Skip an Initial packet's token (length varint + token); the other long
%% types have no token.
-spec skip_token(long_type() | retry, binary()) -> {ok, binary()} | {error, truncated}.
skip_token(initial, Bin) ->
    maybe
        {ok, TokenLen, AfterTokenLen} ?= take_varint(Bin),
        case AfterTokenLen of
            <<_Token:TokenLen/binary, Rest/binary>> -> {ok, Rest};
            _ -> {error, truncated}
        end
    end;
skip_token(_Type, Bin) ->
    {ok, Bin}.

%% =============================================================================
%% Full decode (after header protection has been removed)
%% =============================================================================

-doc """
Decode a packet whose header protection has already been removed, into a
map plus any following coalesced-packet bytes. `DCIDLen` is the server's
fixed connection-ID length, used for short headers.
""".
-spec decode(binary(), non_neg_integer()) -> {ok, packet(), binary()} | {error, term()}.
decode(<<1:1, _:7, _/binary>> = Bin, _DCIDLen) ->
    decode_long(Bin);
decode(<<0:1, _:7, _/binary>> = Bin, DCIDLen) ->
    decode_short(Bin, DCIDLen);
decode(_, _) ->
    {error, invalid_packet}.

-spec decode_long(binary()) -> {ok, packet(), binary()} | {error, term()}.
decode_long(<<_FirstByte, 0:32, _/binary>>) ->
    %% Version 0 is a Version Negotiation packet, which a server never
    %% receives; reject rather than parse.
    {error, unexpected_version_negotiation};
decode_long(<<FirstByte, Version:32, DCIDLen, Rest/binary>>) when DCIDLen =< ?MAX_CID ->
    maybe
        {ok, DCID, SCID, AfterCids} ?= split_cids(DCIDLen, Rest),
        Type = bits_to_type((FirstByte bsr 4) band 2#11),
        PNLen = (FirstByte band 2#11) + 1,
        decode_long_body(Type, Version, DCID, SCID, PNLen, AfterCids)
    end;
decode_long(_) ->
    {error, invalid_packet}.

-spec split_cids(non_neg_integer(), binary()) ->
    {ok, binary(), binary(), binary()} | {error, term()}.
split_cids(DCIDLen, Bin) ->
    case Bin of
        <<DCID:DCIDLen/binary, SCIDLen, Rest/binary>> when SCIDLen =< ?MAX_CID ->
            case Rest of
                <<SCID:SCIDLen/binary, AfterCids/binary>> -> {ok, DCID, SCID, AfterCids};
                _ -> {error, truncated}
            end;
        _ ->
            {error, invalid_cid_length}
    end.

-spec decode_long_body(long_type() | retry, non_neg_integer(), binary(), binary(), 1..4, binary()) ->
    {ok, packet(), binary()} | {error, term()}.
decode_long_body(initial, Version, DCID, SCID, PNLen, Bin) ->
    maybe
        {ok, TokenLen, AfterTokenLen} ?= take_varint(Bin),
        {ok, Token, AfterToken} ?= take_token(TokenLen, AfterTokenLen),
        Base = #{type => initial, version => Version, dcid => DCID, scid => SCID, token => Token},
        decode_long_pn_payload(Base, PNLen, AfterToken)
    end;
decode_long_body(retry, _Version, _DCID, _SCID, _PNLen, _Bin) ->
    %% Retry is a client-only inbound packet; a server never receives one.
    {error, unexpected_retry};
decode_long_body(Type, Version, DCID, SCID, PNLen, Bin) ->
    Base = #{type => Type, version => Version, dcid => DCID, scid => SCID},
    decode_long_pn_payload(Base, PNLen, Bin).

-spec take_token(non_neg_integer(), binary()) -> {ok, binary(), binary()} | {error, term()}.
take_token(TokenLen, _Bin) when TokenLen > ?MAX_TOKEN ->
    {error, token_too_large};
take_token(TokenLen, Bin) ->
    case Bin of
        <<Token:TokenLen/binary, Rest/binary>> -> {ok, Token, Rest};
        _ -> {error, truncated}
    end.

-spec decode_long_pn_payload(map(), 1..4, binary()) -> {ok, packet(), binary()} | {error, term()}.
decode_long_pn_payload(Base, PNLen, Bin) ->
    maybe
        {ok, Length, AfterLength} ?= take_varint(Bin),
        decode_long_slice(Base, PNLen, Length - PNLen, AfterLength)
    end.

-spec decode_long_slice(map(), 1..4, integer(), binary()) ->
    {ok, packet(), binary()} | {error, term()}.
decode_long_slice(Base, PNLen, PayloadSize, Bin) when PayloadSize >= 0 ->
    case Bin of
        <<PNBin:PNLen/binary, Payload:PayloadSize/binary, Rest/binary>> ->
            {PN, <<>>} = decode_pn(PNBin, PNLen),
            {ok, Base#{pn => PN, payload => Payload}, Rest};
        _ ->
            {error, truncated}
    end;
decode_long_slice(_Base, _PNLen, _PayloadSize, _Bin) ->
    {error, invalid_length}.

-spec decode_short(binary(), non_neg_integer()) -> {ok, packet(), binary()} | {error, term()}.
decode_short(<<FirstByte, Rest/binary>>, DCIDLen) ->
    case Rest of
        <<DCID:DCIDLen/binary, AfterDCID/binary>> ->
            PNLen = (FirstByte band 2#11) + 1,
            case AfterDCID of
                <<PNBin:PNLen/binary, Payload/binary>> ->
                    {PN, <<>>} = decode_pn(PNBin, PNLen),
                    %% A short-header packet runs to the end of the datagram.
                    {ok, #{type => one_rtt, dcid => DCID, pn => PN, payload => Payload}, <<>>};
                _ ->
                    {error, truncated}
            end;
        _ ->
            {error, truncated}
    end.

%% =============================================================================
%% Packet number coding (RFC 9000 §17.1, §A)
%% =============================================================================

-doc "Encode a packet number in its minimal-width truncated form.".
-spec encode_pn(non_neg_integer(), 1..4) -> binary().
encode_pn(PN, 1) -> <<PN:8>>;
encode_pn(PN, 2) -> <<PN:16>>;
encode_pn(PN, 3) -> <<PN:24>>;
encode_pn(PN, 4) -> <<PN:32>>.

-doc "Decode a truncated packet number of the given byte width.".
-spec decode_pn(binary(), 1..4) -> {non_neg_integer(), binary()}.
decode_pn(<<PN:8, Rest/binary>>, 1) -> {PN, Rest};
decode_pn(<<PN:16, Rest/binary>>, 2) -> {PN, Rest};
decode_pn(<<PN:24, Rest/binary>>, 3) -> {PN, Rest};
decode_pn(<<PN:32, Rest/binary>>, 4) -> {PN, Rest}.

-doc "Minimal number of bytes needed to encode a packet number.".
-spec pn_length(non_neg_integer()) -> 1..4.
pn_length(PN) when PN < 16#100 -> 1;
pn_length(PN) when PN < 16#10000 -> 2;
pn_length(PN) when PN < 16#1000000 -> 3;
pn_length(_PN) -> 4.

-doc "Extract the key-phase bit from an unprotected short-header first byte.".
-spec key_phase(byte()) -> 0 | 1.
key_phase(FirstByte) ->
    (FirstByte bsr 2) band 1.

%% =============================================================================
%% Internal
%% =============================================================================

-spec type_bits(long_type()) -> 0..2.
type_bits(initial) -> 0;
type_bits(zero_rtt) -> 1;
type_bits(handshake) -> 2.

-spec bits_to_type(0..3) -> long_type() | retry.
bits_to_type(0) -> initial;
bits_to_type(1) -> zero_rtt;
bits_to_type(2) -> handshake;
bits_to_type(3) -> retry.

-spec bool_bit(boolean()) -> 0 | 1.
bool_bit(true) -> 1;
bool_bit(false) -> 0.

%% `roadrunner_quic_varint:decode/1` yields `{ok, V, Rest} | {more, _}`;
%% normalise an incomplete varint to `{error, truncated}` so the header
%% parsers never crash on a short datagram.
-spec take_varint(binary()) -> {ok, non_neg_integer(), binary()} | {error, truncated}.
take_varint(Bin) ->
    case roadrunner_quic_varint:decode(Bin) of
        {ok, _Value, _Rest} = Ok -> Ok;
        {more, _Need} -> {error, truncated}
    end.
