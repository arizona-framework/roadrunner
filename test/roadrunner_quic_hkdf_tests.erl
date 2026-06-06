-module(roadrunner_quic_hkdf_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_hkdf).
%% The `quic` dep, kept as a test-profile differential oracle.
-define(DEP, quic_hkdf).

%% =============================================================================
%% RFC 5869 Appendix A SHA-256 test vectors — the authority.
%%
%% Each case fixes the HKDF-Extract PRK and the HKDF-Expand OKM. Cases 1
%% and 2 exercise multi-block expansion (L=42 -> 2 blocks, L=82 -> 3); case
%% 3 exercises the absent-salt default (a string of HashLen zero bytes).
%% =============================================================================

rfc5869_a1_basic_test() ->
    IKM = binary:copy(<<16#0b>>, 22),
    Salt = hex(~"000102030405060708090a0b0c"),
    Info = hex(~"f0f1f2f3f4f5f6f7f8f9"),
    PRK = hex(~"077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"),
    OKM = hex(
        ~"3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
    ),
    ?assertEqual(PRK, ?M:extract(Salt, IKM)),
    ?assertEqual(OKM, ?M:expand(PRK, Info, 42)).

rfc5869_a2_longer_inputs_test() ->
    IKM = list_to_binary(lists:seq(16#00, 16#4f)),
    Salt = list_to_binary(lists:seq(16#60, 16#af)),
    Info = list_to_binary(lists:seq(16#b0, 16#ff)),
    PRK = hex(~"06a6b88c5853361a06104c9ceb35b45cef760014904671014a193f40c15fc244"),
    OKM = hex(
        ~"b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87"
    ),
    ?assertEqual(PRK, ?M:extract(Salt, IKM)),
    ?assertEqual(OKM, ?M:expand(PRK, Info, 82)).

rfc5869_a3_empty_salt_test() ->
    IKM = binary:copy(<<16#0b>>, 22),
    PRK = hex(~"19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04"),
    OKM = hex(
        ~"8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"
    ),
    %% An empty salt defaults to HashLen zero bytes (RFC 5869 §2.2).
    ?assertEqual(PRK, ?M:extract(<<>>, IKM)),
    ?assertEqual(OKM, ?M:expand(PRK, <<>>, 42)).

%% =============================================================================
%% HKDF-Expand-Label (RFC 8446 §7.1) against RFC 9001 Appendix A.1, where
%% the client/server Initial secrets are Expand-Label outputs over the
%% Initial secret with the "tls13 " prefix.
%% =============================================================================

expand_label_rfc9001_test() ->
    InitialSecret = hex(~"7db5df06e7a69e432496adedb00851923595221596ae2ae9fb8115c1e9ed0a44"),
    ClientSecret = hex(~"c00cf151ca5be075ed0ebfb5c80323c42d6b7db67881289af4008f1f6c357aea"),
    ServerSecret = hex(~"3c199828fd139efd216c155ad844cc81fb82fa8d7446fa7d78be803acdda951b"),
    ?assertEqual(ClientSecret, ?M:expand_label(InitialSecret, ~"client in", <<>>, 32)),
    ?assertEqual(ServerSecret, ?M:expand_label(InitialSecret, ~"server in", <<>>, 32)).

%% =============================================================================
%% Differential equivalence vs the dep oracle, across varied inputs
%% (empty salt, non-empty salt, several lengths, a non-empty context).
%% =============================================================================

oracle_matches_dep_test() ->
    Inputs = [
        {<<>>, ~"ikm", <<>>, ~"quic key", <<>>, 16},
        {~"salt", ~"keying material", ~"info", ~"quic iv", <<>>, 12},
        {~"the-salt", ~"the-ikm", ~"the-info", ~"quic hp", <<>>, 16},
        {~"s", ~"i", ~"n", ~"derived", ~"context-bytes", 48},
        {~"abc", ~"def", ~"ghi", ~"key", <<>>, 32}
    ],
    [
        begin
            PRK = ?M:extract(Salt, IKM),
            ?assertEqual(?DEP:extract(Salt, IKM), PRK),
            ?assertEqual(?DEP:expand(PRK, Info, Len), ?M:expand(PRK, Info, Len)),
            ?assertEqual(
                ?DEP:expand_label(PRK, Label, Ctx, Len),
                ?M:expand_label(PRK, Label, Ctx, Len)
            )
        end
     || {Salt, IKM, Info, Label, Ctx, Len} <- Inputs
    ].

%% A zero-length expansion yields the empty binary (RFC 5869 §2.3, N=0),
%% pinned here independently of the differential property.
expand_zero_length_test() ->
    PRK = ?M:extract(~"salt", ~"ikm"),
    ?assertEqual(<<>>, ?M:expand(PRK, ~"info", 0)),
    ?assertEqual(<<>>, ?M:expand_label(PRK, ~"label", <<>>, 0)).

%% Uppercase before decoding so the literals are portable across OTP
%% versions regardless of `binary:decode_hex/1`'s lowercase handling.
hex(Hex) -> binary:decode_hex(string:uppercase(Hex)).
