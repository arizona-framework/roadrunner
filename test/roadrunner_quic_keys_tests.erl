-module(roadrunner_quic_keys_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_keys).

%% =============================================================================
%% RFC 9001 Appendix A.1 — the authority.
%%
%% The worked example derives Initial keys for both directions from the
%% client's DCID 0x8394c8f03e515708.
%% =============================================================================

rfc9001_a1_initial_secret_test() ->
    ?assertEqual(
        hex(~"7db5df06e7a69e432496adedb00851923595221596ae2ae9fb8115c1e9ed0a44"),
        ?M:initial_secret(a1_dcid())
    ).

rfc9001_a1_server_keys_test() ->
    ?assertEqual(
        #{
            key => hex(~"cf3a5331653c364c88f0f379b6067e37"),
            iv => hex(~"0ac1493ca1905853b0bba03e"),
            hp => hex(~"c206b8d9b9f0f37644430b490eeaa314")
        },
        ?M:initial_server(a1_dcid())
    ).

rfc9001_a1_client_keys_test() ->
    ?assertEqual(
        #{
            key => hex(~"1f369613dd76d5467730efcbe3b1a22d"),
            iv => hex(~"fa044b2f42a3fd3b46fb255c"),
            hp => hex(~"9f50449e04a0e810283a1e9933adedd2")
        },
        ?M:initial_client(a1_dcid())
    ).

%% The server Initial keys derive straight from the server Initial secret
%% (RFC 9001 A.1), so `traffic_keys/1` over that secret reproduces them.
traffic_keys_test() ->
    ServerSecret = hex(~"3c199828fd139efd216c155ad844cc81fb82fa8d7446fa7d78be803acdda951b"),
    ?assertEqual(
        #{
            key => hex(~"cf3a5331653c364c88f0f379b6067e37"),
            iv => hex(~"0ac1493ca1905853b0bba03e"),
            hp => hex(~"c206b8d9b9f0f37644430b490eeaa314")
        },
        ?M:traffic_keys(ServerSecret)
    ).

%% =============================================================================
%% Key update (RFC 9001 §6.1), AES-128-GCM: the next secret is
%% Expand-Label(current, "quic ku", "", 32), and the keys follow from it.
%% =============================================================================

key_update_test() ->
    Secret = binary:copy(<<16#2a>>, 32),
    {UpdatedSecret, Keys} = ?M:update(Secret),
    ?assertEqual(
        hex(~"c8dd004d0adc90d90ef286b8debce48f65a3ea342932fc5f4891207e96f8e862"),
        UpdatedSecret
    ),
    ?assertEqual(
        #{
            key => hex(~"d77beffa17a12a7697276ab00c5faa0b"),
            iv => hex(~"535303b03a85a983f4311f64"),
            hp => hex(~"c77ac07f35beb8c618d0956b341206b5")
        },
        Keys
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

a1_dcid() -> hex(~"8394c8f03e515708").

%% Uppercase before decoding so the literals are portable across OTP
%% versions regardless of `binary:decode_hex/1`'s lowercase handling.
hex(Hex) -> binary:decode_hex(string:uppercase(Hex)).
