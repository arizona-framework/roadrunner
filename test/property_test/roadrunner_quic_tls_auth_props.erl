-module(roadrunner_quic_tls_auth_props).
-moduledoc """
Property-based tests for `roadrunner_quic_tls_auth`.

Round-trip invariant: a CertificateVerify built for any 32-byte
transcript hash, under each supported signature scheme (rsa_pss_rsae_sha256,
ecdsa_secp256r1_sha256, ed25519), carries a signature that verifies
against the matching public key.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("public_key/include/public_key.hrl").
-include_lib("common_test/include/ct_property_test.hrl").

prop_certificate_verify_roundtrips() ->
    Keys = signing_keys(),
    ?FORALL(
        {Index, TranscriptHash},
        {integer(1, length(Keys)), binary(32)},
        begin
            {Scheme, Private, Public, {SigAlg, HashAlg, Options}} = lists:nth(Index, Keys),
            CV = iolist_to_binary(
                roadrunner_quic_tls_auth:build_certificate_verify(Scheme, Private, TranscriptHash)
            ),
            {ok, {15, Body}, <<>>} = roadrunner_quic_tls_handshake:decode(CV),
            <<Scheme:16, SigLen:16, Signature:SigLen/binary>> = Body,
            Content =
                <<(binary:copy(<<16#20>>, 64))/binary, "TLS 1.3, server CertificateVerify", 0,
                    TranscriptHash/binary>>,
            crypto:verify(SigAlg, HashAlg, Content, Signature, Public, Options)
        end
    ).

%% One key pair per supported scheme, generated once for the whole run.
signing_keys() ->
    Rsa =
        #'RSAPrivateKey'{publicExponent = E, modulus = N} =
        public_key:generate_key({rsa, 2048, 65537}),
    Ec = #'ECPrivateKey'{publicKey = EcPub} = public_key:generate_key({namedCurve, secp256r1}),
    Ed = #'ECPrivateKey'{publicKey = EdPub} = public_key:generate_key({namedCurve, ed25519}),
    [
        {16#0804, Rsa, [E, N], {rsa, sha256, [{rsa_padding, rsa_pkcs1_pss_padding}, {rsa_pss_saltlen, -1}]}},
        {16#0403, Ec, [EcPub, secp256r1], {ecdsa, sha256, []}},
        {16#0807, Ed, [EdPub, ed25519], {eddsa, none, []}}
    ].
