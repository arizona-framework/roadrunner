-module(roadrunner_quic_hkdf).
-moduledoc false.

%% HKDF (RFC 5869) plus the TLS 1.3 HKDF-Expand-Label wrapper (RFC 8446
%% §7.1), the key-derivation primitive QUIC packet protection is built on
%% (RFC 9001 §5).
%%
%% The hash is the negotiated cipher suite's (RFC 8446 §7.1): SHA-256 for
%% `TLS_AES_128_GCM_SHA256` and `TLS_CHACHA20_POLY1305_SHA256` (and for the
%% Initial keys, RFC 9001 §5.2), SHA-384 for `TLS_AES_256_GCM_SHA384`, so
%% every function takes it first. The Extract/Expand pair is kept
%% RFC-complete (the multi-block expansion and the absent-salt default) so
%% the RFC 5869 vectors validate it, even though QUIC itself only ever
%% expands to at most one hash length.

-export([extract/3, expand/4, expand_label/5, hash_len/1]).

-export_type([hash/0]).

%% The hashes of the supported TLS 1.3 cipher suites (RFC 8446 Appendix
%% B.4), named as `crypto` names them.
-type hash() :: sha256 | sha384.

-doc "HKDF-Extract (RFC 5869 §2.2): salt + input keying material to a pseudorandom key.".
-spec extract(hash(), binary(), binary()) -> binary().
extract(Hash, <<>>, IKM) ->
    %% RFC 5869 §2.2: an absent salt defaults to HashLen zero bytes.
    crypto:mac(hmac, Hash, <<0:(hash_len(Hash) * 8)>>, IKM);
extract(Hash, Salt, IKM) ->
    crypto:mac(hmac, Hash, Salt, IKM).

-doc "HKDF-Expand (RFC 5869 §2.3): a pseudorandom key to `Length` output octets.".
-spec expand(hash(), binary(), binary(), non_neg_integer()) -> binary().
expand(Hash, PRK, Info, Length) ->
    HashLen = hash_len(Hash),
    %% RFC 5869 §2.3: HKDF-Expand emits at most 255 * HashLen octets.
    true = Length =< 255 * HashLen,
    N = (Length + HashLen - 1) div HashLen,
    binary:part(iolist_to_binary(expand_blocks(Hash, PRK, Info, N, 1, <<>>)), 0, Length).

-doc "HKDF-Expand-Label (RFC 8446 §7.1) with the `tls13 ` prefix QUIC reuses (RFC 9001 §5.1).".
-spec expand_label(hash(), binary(), binary(), binary(), non_neg_integer()) -> binary().
expand_label(Hash, Secret, Label, Context, Length) ->
    FullLabel = <<"tls13 ", Label/binary>>,
    Info =
        <<Length:16, (byte_size(FullLabel)):8, FullLabel/binary, (byte_size(Context)):8,
            Context/binary>>,
    expand(Hash, Secret, Info, Length).

-doc "The hash output length (RFC 5869 `HashLen`): 32 bytes for SHA-256, 48 for SHA-384.".
-spec hash_len(hash()) -> 32 | 48.
hash_len(sha256) -> 32;
hash_len(sha384) -> 48.

%% =============================================================================
%% Internal
%% =============================================================================

%% T(i) = HMAC(PRK, T(i-1) | Info | i), RFC 5869 §2.3; cons each block on
%% the way out so the output is built without a growing accumulator.
-spec expand_blocks(hash(), binary(), binary(), non_neg_integer(), pos_integer(), binary()) ->
    iolist().
expand_blocks(_Hash, _PRK, _Info, N, I, _Prev) when I > N ->
    [];
expand_blocks(Hash, PRK, Info, N, I, Prev) ->
    T = crypto:mac(hmac, Hash, PRK, <<Prev/binary, Info/binary, I>>),
    [T | expand_blocks(Hash, PRK, Info, N, I + 1, T)].
