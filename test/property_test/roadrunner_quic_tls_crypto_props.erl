-module(roadrunner_quic_tls_crypto_props).
-moduledoc """
Property-based tests for `roadrunner_quic_tls_crypto`.

Differential invariant over random inputs: the transcript hash,
Derive-Secret, and the early/handshake/master secret chain are
byte-for-byte identical to the `quic` dep (the oracle), which implements
the same RFC 8446 §7.1 key schedule.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

prop_matches_dep() ->
    ?FORALL(
        {Secret, Label, Hash, Shared, Messages},
        {binary(32), non_empty(binary()), binary(32), binary(32), binary()},
        begin
            FinishedKey = roadrunner_quic_tls_crypto:finished_key(Secret),
            roadrunner_quic_tls_crypto:transcript_hash(Messages) =:=
                quic_crypto:transcript_hash(Messages) andalso
                roadrunner_quic_tls_crypto:derive_secret(Secret, Label, Hash) =:=
                    quic_crypto:derive_secret(Secret, Label, Hash) andalso
                roadrunner_quic_tls_crypto:handshake_secret(Secret, Shared) =:=
                    quic_crypto:derive_handshake_secret(Secret, Shared) andalso
                roadrunner_quic_tls_crypto:master_secret(Secret) =:=
                    quic_crypto:derive_master_secret(Secret) andalso
                roadrunner_quic_tls_crypto:traffic_secret(client, handshake, Secret, Hash) =:=
                    quic_crypto:derive_client_handshake_secret(Secret, Hash) andalso
                roadrunner_quic_tls_crypto:traffic_secret(server, handshake, Secret, Hash) =:=
                    quic_crypto:derive_server_handshake_secret(Secret, Hash) andalso
                roadrunner_quic_tls_crypto:traffic_secret(client, application, Secret, Hash) =:=
                    quic_crypto:derive_client_app_secret(Secret, Hash) andalso
                roadrunner_quic_tls_crypto:traffic_secret(server, application, Secret, Hash) =:=
                    quic_crypto:derive_server_app_secret(Secret, Hash) andalso
                FinishedKey =:= quic_crypto:derive_finished_key(Secret) andalso
                roadrunner_quic_tls_crypto:verify_data(FinishedKey, Hash) =:=
                    quic_crypto:compute_finished_verify(FinishedKey, Hash)
        end
    ).
