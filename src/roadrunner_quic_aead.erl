-module(roadrunner_quic_aead).
-moduledoc false.

%% QUIC v1 packet protection (RFC 9001 §5): AEAD payload seal/open plus
%% header protection.
%%
%% v1 negotiates `TLS_AES_128_GCM_SHA256`, so the AEAD is AES-128-GCM (a
%% 16-byte key, a 12-byte IV, a 16-byte tag) and header protection is
%% AES-128-ECB. The nonce is the IV with the packet number XORed into its
%% low 64 bits (§5.3). Header protection masks the low bits of the first
%% byte and the packet-number bytes with a mask derived from a 16-byte
%% ciphertext sample taken 4 bytes past the start of the packet number
%% (§5.4.1). On receive the protection MUST be removed before the
%% packet-number length or the key-phase bit can be trusted, so
%% `unprotect_header/3` reports those only after unmasking.
%%
%% The packet number is carried truncated on the wire; reconstructing the
%% full number from the largest received (RFC 9000 §A) is the receive
%% path's job, so `seal/5` and `open/5` take the full number directly.

-export([seal/5, open/5, protect_header/4, unprotect_header/3]).

%% AEAD authentication tag length (RFC 9001 §5.3).
-define(TAG_LEN, 16).
%% Header-protection sample: 16 bytes, 4 past the packet-number start
%% (RFC 9001 §5.4.2).
-define(SAMPLE_OFFSET, 4).
-define(SAMPLE_LEN, 16).

-doc """
Seal a packet payload with AES-128-GCM. `AAD` is the unprotected header,
`PN` the full packet number; the 16-byte authentication tag is appended
to the returned ciphertext.
""".
-spec seal(binary(), binary(), non_neg_integer(), binary(), binary()) -> binary().
seal(Key, IV, PN, AAD, Plaintext) ->
    {Ciphertext, Tag} = crypto:crypto_one_time_aead(
        aes_128_gcm, Key, nonce(IV, PN), Plaintext, AAD, ?TAG_LEN, true
    ),
    <<Ciphertext/binary, Tag/binary>>.

-doc """
Open a sealed payload (ciphertext with its tag appended). Returns
`{ok, Plaintext}`, or `error` if authentication fails or the input is
too short to hold a tag, so the receive path drops the packet.
""".
-spec open(binary(), binary(), non_neg_integer(), binary(), binary()) -> {ok, binary()} | error.
open(Key, IV, PN, AAD, Sealed) when byte_size(Sealed) >= ?TAG_LEN ->
    CipherLen = byte_size(Sealed) - ?TAG_LEN,
    <<Ciphertext:CipherLen/binary, Tag:?TAG_LEN/binary>> = Sealed,
    case
        crypto:crypto_one_time_aead(aes_128_gcm, Key, nonce(IV, PN), Ciphertext, AAD, Tag, false)
    of
        Plaintext when is_binary(Plaintext) -> {ok, Plaintext};
        error -> error
    end;
open(_Key, _IV, _PN, _AAD, _Sealed) ->
    error.

-doc """
Apply header protection (RFC 9001 §5.4). `Header` is the unprotected
header through the packet number (it doubles as the AEAD associated
data), `Ciphertext` is the sealed payload, and `PNOffset` is the byte
offset of the packet number within `Header`. Returns the protected
header; the wire packet is that followed by `Ciphertext`.
""".
-spec protect_header(binary(), binary(), binary(), non_neg_integer()) -> binary().
protect_header(HPKey, Header, Ciphertext, PNOffset) ->
    <<FirstByte, _/binary>> = Header,
    PNLen = pn_len(FirstByte),
    %% The sample is at PNOffset + 4 in the packet; the ciphertext begins
    %% at PNOffset + PNLen, so within it the sample starts here.
    Sample = binary:part(Ciphertext, ?SAMPLE_OFFSET - PNLen, ?SAMPLE_LEN),
    <<M0, _/binary>> = Mask = hp_mask(HPKey, Sample),
    MiddleLen = PNOffset - 1,
    <<_FB, Middle:MiddleLen/binary, PN:PNLen/binary>> = Header,
    MaskPN = binary:part(Mask, 1, PNLen),
    <<
        (FirstByte bxor first_byte_mask(FirstByte, M0)),
        Middle/binary,
        (xor_bytes(PN, MaskPN))/binary
    >>.

-doc """
Remove header protection (RFC 9001 §5.4) from a received packet.
`PNOffset` is the byte offset of the packet number, located on the
still-protected packet via `roadrunner_quic_packet:pn_offset/2`. Returns
the unprotected header (the AEAD associated data), the packet-number
length, the truncated packet number, and the trailing ciphertext, or
`{error, sample_too_short}` if the packet is too small to sample.
""".
-spec unprotect_header(binary(), binary(), non_neg_integer()) ->
    {ok, binary(), 1..4, non_neg_integer(), binary()} | {error, sample_too_short}.
unprotect_header(HPKey, Packet, PNOffset) ->
    case Packet of
        <<Header:PNOffset/binary, AfterHeader/binary>> when
            byte_size(AfterHeader) >= ?SAMPLE_OFFSET + ?SAMPLE_LEN
        ->
            Sample = binary:part(AfterHeader, ?SAMPLE_OFFSET, ?SAMPLE_LEN),
            <<M0, _/binary>> = Mask = hp_mask(HPKey, Sample),
            <<ProtFirstByte, Middle/binary>> = Header,
            FirstByte = ProtFirstByte bxor first_byte_mask(ProtFirstByte, M0),
            PNLen = pn_len(FirstByte),
            <<ProtPN:PNLen/binary, Ciphertext/binary>> = AfterHeader,
            PN = xor_bytes(ProtPN, binary:part(Mask, 1, PNLen)),
            {ok, <<FirstByte, Middle/binary, PN/binary>>, PNLen, binary:decode_unsigned(PN),
                Ciphertext};
        _ ->
            {error, sample_too_short}
    end.

%% =============================================================================
%% Internal
%% =============================================================================

%% AEAD nonce (RFC 9001 §5.3): the 12-byte IV with the packet number
%% XORed into its low 64 bits.
-spec nonce(binary(), non_neg_integer()) -> binary().
nonce(<<Prefix:32, Low:64>>, PN) ->
    <<Prefix:32, (Low bxor PN):64>>.

%% Header-protection mask (RFC 9001 §5.4.1): AES-128-ECB of the 16-byte
%% sample. The first byte masks the first header byte; the next bytes mask
%% the packet number.
-spec hp_mask(binary(), binary()) -> binary().
hp_mask(HPKey, Sample) ->
    crypto:crypto_one_time(aes_128_ecb, HPKey, Sample, true).

%% The low bits of the first byte that header protection masks: 4 for a
%% long header, 5 for a short header (RFC 9001 §5.4.1). Bit 7 (the form
%% bit) is never masked, so it reads the same protected or not.
-spec first_byte_mask(byte(), byte()) -> byte().
first_byte_mask(FirstByte, M0) when (FirstByte band 16#80) =:= 16#80 -> M0 band 16#0F;
first_byte_mask(_FirstByte, M0) -> M0 band 16#1F.

%% Packet-number length encoded in the low 2 bits of the first byte
%% (RFC 9000 §17.2/§17.3).
-spec pn_len(byte()) -> 1..4.
pn_len(FirstByte) -> (FirstByte band 2#11) + 1.

%% XOR two equal-length byte strings (the 1-4 byte packet number against
%% its mask); body recursion, no `crypto:exor/2` NIF call for so few
%% bytes.
-spec xor_bytes(binary(), binary()) -> binary().
xor_bytes(<<>>, <<>>) -> <<>>;
xor_bytes(<<A, As/binary>>, <<B, Bs/binary>>) -> <<(A bxor B), (xor_bytes(As, Bs))/binary>>.
