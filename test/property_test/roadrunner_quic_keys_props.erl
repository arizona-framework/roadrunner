-module(roadrunner_quic_keys_props).
-moduledoc """
Property-based tests for `roadrunner_quic_keys`.

Differential invariant over random inputs: the Initial secret, both
Initial-direction key bundles, the traffic keys, and the key-update
derivation are byte-for-byte identical to the `quic` dep (the oracle) for
an arbitrary Destination Connection ID and traffic secret.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

prop_matches_dep() ->
    ?FORALL(
        {DCID, Secret},
        {binary(), binary(32)},
        begin
            roadrunner_quic_keys:initial_secret(DCID) =:= quic_keys:derive_initial_secret(DCID) andalso
                roadrunner_quic_keys:initial_server(DCID) =:=
                    dep_keys(quic_keys:derive_initial_server(DCID)) andalso
                roadrunner_quic_keys:initial_client(DCID) =:=
                    dep_keys(quic_keys:derive_initial_client(DCID)) andalso
                roadrunner_quic_keys:traffic_keys(Secret) =:=
                    dep_keys(quic_keys:derive_traffic_keys(Secret)) andalso
                roadrunner_quic_keys:update(Secret) =:=
                    dep_update(quic_keys:derive_updated_keys(Secret, aes_128_gcm))
        end
    ).

dep_keys({Key, IV, HP}) -> #{key => Key, iv => IV, hp => HP}.

dep_update({Secret, Keys}) -> {Secret, dep_keys(Keys)}.
