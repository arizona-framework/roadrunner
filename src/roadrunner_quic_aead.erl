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

-export_type([aead_key/0, hp/0]).

%% A packet-protection key: the raw 16-byte AES-128-GCM key, or (OTP 28+)
%% the sealing or opening state a connection builds from it once
%% (`roadrunner_quic_keys:for_connection/2`).
-type aead_key() :: binary() | crypto:crypto_state().

%% A header-protection key: the raw 16-byte key, or the AES-128-ECB state
%% a connection builds from it once (`roadrunner_quic_keys:for_connection/2`).
-type hp() :: binary() | crypto:crypto_state().

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
-spec seal(aead_key(), binary(), non_neg_integer(), binary(), binary()) -> binary().
seal(Key, IV, PN, AAD, Plaintext) ->
    aead_seal(Key, nonce(IV, PN), Plaintext, AAD).

-doc """
Open a sealed payload (ciphertext with its tag appended). Returns
`{ok, Plaintext}`, or `error` if authentication fails or the input is
too short to hold a tag, so the receive path drops the packet.
""".
-spec open(aead_key(), binary(), non_neg_integer(), binary(), binary()) ->
    {ok, binary()} | error.
open(Key, IV, PN, AAD, Sealed) when byte_size(Sealed) >= ?TAG_LEN ->
    case aead_open(Key, nonce(IV, PN), Sealed, AAD) of
        Plaintext when is_binary(Plaintext) -> {ok, Plaintext};
        error -> error
    end;
open(_Key, _IV, _PN, _AAD, _Sealed) ->
    error.

%% A raw key takes the one-shot call. From OTP 28 a connection seals and
%% opens through a state built once per key with
%% `crypto_one_time_aead_init/4` (`roadrunner_quic_keys:for_connection/2`),
%% which skips the per-packet key setup and hands back the ciphertext
%% with its tag already appended: 432 ns -> 278 ns to seal 64 bytes, 327
%% ns -> 201 ns to open them. Only the clauses the running OTP can use
%% are compiled.
-if(?OTP_RELEASE >= 28).
-spec aead_seal(aead_key(), binary(), binary(), binary()) -> binary().
aead_seal(Key, Nonce, Plaintext, AAD) when is_binary(Key) ->
    seal_one_time(Key, Nonce, Plaintext, AAD);
aead_seal(State, Nonce, Plaintext, AAD) ->
    crypto:crypto_one_time_aead(State, Nonce, Plaintext, AAD).

-spec aead_open(aead_key(), binary(), binary(), binary()) -> binary() | error.
aead_open(Key, Nonce, Sealed, AAD) when is_binary(Key) ->
    open_one_time(Key, Nonce, Sealed, AAD);
aead_open(State, Nonce, Sealed, AAD) ->
    crypto:crypto_one_time_aead(State, Nonce, Sealed, AAD).
-else.
-spec aead_seal(aead_key(), binary(), binary(), binary()) -> binary().
aead_seal(Key, Nonce, Plaintext, AAD) ->
    seal_one_time(Key, Nonce, Plaintext, AAD).

-spec aead_open(aead_key(), binary(), binary(), binary()) -> binary() | error.
aead_open(Key, Nonce, Sealed, AAD) ->
    open_one_time(Key, Nonce, Sealed, AAD).
-endif.

-spec seal_one_time(binary(), binary(), binary(), binary()) -> binary().
seal_one_time(Key, Nonce, Plaintext, AAD) ->
    {Ciphertext, Tag} = crypto:crypto_one_time_aead(
        aes_128_gcm, Key, Nonce, Plaintext, AAD, ?TAG_LEN, true
    ),
    <<Ciphertext/binary, Tag/binary>>.

-spec open_one_time(binary(), binary(), binary(), binary()) -> binary() | error.
open_one_time(Key, Nonce, Sealed, AAD) ->
    CipherLen = byte_size(Sealed) - ?TAG_LEN,
    <<Ciphertext:CipherLen/binary, Tag:?TAG_LEN/binary>> = Sealed,
    crypto:crypto_one_time_aead(aes_128_gcm, Key, Nonce, Ciphertext, AAD, Tag, false).

-doc """
Apply header protection (RFC 9001 §5.4). `Header` is the unprotected
header through the packet number (it doubles as the AEAD associated
data), `Ciphertext` is the sealed payload, and `PNOffset` is the byte
offset of the packet number within `Header`. Returns the protected
header; the wire packet is that followed by `Ciphertext`.
""".
-spec protect_header(hp(), binary(), binary(), non_neg_integer()) -> binary().
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
-spec unprotect_header(hp(), binary(), non_neg_integer()) ->
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
%% the packet number. ECB carries nothing between blocks, so a connection
%% reuses one cipher state for every packet: 391 ns -> 122 ns per mask
%% against setting the key up again with `crypto_one_time/4`. A raw key
%% (test vectors, one-off use) takes the one-shot call.
-spec hp_mask(hp(), binary()) -> binary().
hp_mask(HPKey, Sample) when is_binary(HPKey) ->
    crypto:crypto_one_time(aes_128_ecb, HPKey, Sample, true);
hp_mask(HPState, Sample) ->
    crypto:crypto_update(HPState, Sample).

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
