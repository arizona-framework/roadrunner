-module(roadrunner_quic_hkdf).
-moduledoc false.

%% HKDF over HMAC-SHA-256 (RFC 5869) plus the TLS 1.3 HKDF-Expand-Label
%% wrapper (RFC 8446 §7.1), the key-derivation primitive QUIC packet
%% protection is built on (RFC 9001 §5).
%%
%% QUIC v1 negotiates `TLS_AES_128_GCM_SHA256` only, so the hash is fixed
%% to SHA-256 (a 32-byte output); a wider cipher suite would carry the
%% hash as a parameter. The Extract/Expand pair is kept RFC-complete (the
%% multi-block expansion and the absent-salt default) so the RFC 5869
%% vectors validate it, even though QUIC itself only ever expands to at
%% most 32 bytes.

-export([extract/2, expand/3, expand_label/4]).

%% SHA-256 output length (RFC 5869 `HashLen`).
-define(HASH_LEN, 32).
%% RFC 5869 §2.3: HKDF-Expand emits at most 255 * HashLen octets.
-define(MAX_EXPAND, 255 * ?HASH_LEN).

-doc "HKDF-Extract (RFC 5869 §2.2): salt + input keying material to a pseudorandom key.".
-spec extract(binary(), binary()) -> binary().
extract(<<>>, IKM) ->
    %% RFC 5869 §2.2: an absent salt defaults to HashLen zero bytes.
    crypto:mac(hmac, sha256, binary:copy(<<0>>, ?HASH_LEN), IKM);
extract(Salt, IKM) ->
    crypto:mac(hmac, sha256, Salt, IKM).

-doc "HKDF-Expand (RFC 5869 §2.3): a pseudorandom key to `Length` output octets.".
-spec expand(binary(), binary(), non_neg_integer()) -> binary().
expand(PRK, Info, Length) when Length =< ?MAX_EXPAND ->
    N = (Length + ?HASH_LEN - 1) div ?HASH_LEN,
    binary:part(iolist_to_binary(expand_blocks(PRK, Info, N, 1, <<>>)), 0, Length).

-doc "HKDF-Expand-Label (RFC 8446 §7.1) with the `tls13 ` prefix QUIC reuses (RFC 9001 §5.1).".
-spec expand_label(binary(), binary(), binary(), non_neg_integer()) -> binary().
expand_label(Secret, Label, Context, Length) ->
    FullLabel = <<"tls13 ", Label/binary>>,
    Info =
        <<Length:16, (byte_size(FullLabel)):8, FullLabel/binary, (byte_size(Context)):8,
            Context/binary>>,
    expand(Secret, Info, Length).

%% =============================================================================
%% Internal
%% =============================================================================

%% T(i) = HMAC(PRK, T(i-1) | Info | i), RFC 5869 §2.3; cons each block on
%% the way out so the output is built without a growing accumulator.
-spec expand_blocks(binary(), binary(), non_neg_integer(), pos_integer(), binary()) -> iolist().
expand_blocks(_PRK, _Info, N, I, _Prev) when I > N ->
    [];
expand_blocks(PRK, Info, N, I, Prev) ->
    T = crypto:mac(hmac, sha256, PRK, <<Prev/binary, Info/binary, I>>),
    [T | expand_blocks(PRK, Info, N, I + 1, T)].
