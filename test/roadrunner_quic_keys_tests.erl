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
%% Key update (RFC 9001 §6.1): the next secret is
%% Expand-Label(current, "quic ku", "", 32), and the AEAD key and IV follow
%% from it; the header-protection key is not updated.
%% =============================================================================

%% RFC 9001 Appendix A.5 publishes the "quic ku" secret for its 1-RTT
%% secret. The vector's AEAD is ChaCha20-Poly1305, but the update secret
%% depends only on the secret and SHA-256, which AES-128-GCM shares.
rfc9001_a5_key_update_secret_test() ->
    Secret = hex(~"9ac312a7f877468ebe69422748ad00a15443f18203a07d6060f688f30f21632b"),
    {UpdatedSecret, _PacketKeys} = ?M:update(Secret),
    ?assertEqual(
        hex(~"1223504755036d556342ee9361d253421a826c9ecdf3c7148684b36b714881f9"),
        UpdatedSecret
    ).

%% The updated generation's AEAD key and IV are the "quic key" and
%% "quic iv" expansions of the updated secret, and nothing else.
key_update_derives_packet_keys_test() ->
    Secret = binary:copy(<<16#2a>>, 32),
    {UpdatedSecret, PacketKeys} = ?M:update(Secret),
    ?assertEqual(
        hex(~"c8dd004d0adc90d90ef286b8debce48f65a3ea342932fc5f4891207e96f8e862"),
        UpdatedSecret
    ),
    ?assertEqual(
        #{
            key => hex(~"d77beffa17a12a7697276ab00c5faa0b"),
            iv => hex(~"535303b03a85a983f4311f64")
        },
        PacketKeys
    ),
    ?assertEqual(maps:with([key, iv], ?M:traffic_keys(UpdatedSecret)), PacketKeys).

%% =============================================================================
%% Helpers
%% =============================================================================

a1_dcid() -> hex(~"8394c8f03e515708").

%% Uppercase before decoding so the literals are portable across OTP
%% versions regardless of `binary:decode_hex/1`'s lowercase handling.
hex(Hex) -> binary:decode_hex(string:uppercase(Hex)).

for_connection_protects_like_the_raw_key_test() ->
    %% The connection's cipher state must mask exactly like the raw
    %% 16-byte header-protection key it was built from, packet after
    %% packet (ECB keeps no state between blocks).
    #{hp := Raw} = Keys = roadrunner_quic_keys:initial_server(<<16#8394c8f03e515708:64>>),
    #{hp := State} = roadrunner_quic_keys:for_connection(Keys, seal),
    Header = <<16#c3, 1:32, 8, 0:64, 0, 16#4499:16, 2:32>>,
    [
        ?assertEqual(
            roadrunner_quic_aead:protect_header(Raw, Header, Cipher, byte_size(Header) - 4),
            roadrunner_quic_aead:protect_header(State, Header, Cipher, byte_size(Header) - 4)
        )
     || Cipher <- [crypto:strong_rand_bytes(32) || _ <- lists:seq(1, 20)]
    ].

for_connection_seals_and_opens_like_the_raw_key_test() ->
    %% The connection's sealing state must produce the raw key's bytes,
    %% and its opening state must open them, packet after packet.
    Keys = roadrunner_quic_keys:initial_server(<<16#8394c8f03e515708:64>>),
    #{key := Raw, iv := IV} = Keys,
    #{key := SealKey} = roadrunner_quic_keys:for_connection(Keys, seal),
    #{key := OpenKey} = roadrunner_quic_keys:for_connection(Keys, open),
    [
        begin
            Plaintext = crypto:strong_rand_bytes(Size),
            AAD = crypto:strong_rand_bytes(20),
            Sealed = roadrunner_quic_aead:seal(Raw, IV, PN, AAD, Plaintext),
            ?assertEqual(Sealed, roadrunner_quic_aead:seal(SealKey, IV, PN, AAD, Plaintext)),
            ?assertEqual({ok, Plaintext}, roadrunner_quic_aead:open(OpenKey, IV, PN, AAD, Sealed)),
            <<Flip, Rest/binary>> = Sealed,
            ?assertEqual(
                error,
                roadrunner_quic_aead:open(OpenKey, IV, PN, AAD, <<(Flip bxor 1), Rest/binary>>)
            )
        end
     || {PN, Size} <- [{0, 1}, {1, 64}, {2, 1200}, {16#FFFF, 300}]
    ].

for_connection_prepares_update_packet_keys_test() ->
    %% A key update's packet keys carry no header-protection key; only the
    %% AEAD key is prepared, and it seals and opens like the raw key.
    {_UpdatedSecret, #{key := Raw, iv := IV} = PacketKeys} = ?M:update(binary:copy(<<7>>, 32)),
    #{key := SealKey, iv := IV} = Sealing = ?M:for_connection(PacketKeys, seal),
    #{key := OpenKey} = ?M:for_connection(PacketKeys, open),
    ?assertEqual([iv, key], lists:sort(maps:keys(Sealing))),
    Sealed = roadrunner_quic_aead:seal(Raw, IV, 5, ~"aad", ~"payload"),
    ?assertEqual(Sealed, roadrunner_quic_aead:seal(SealKey, IV, 5, ~"aad", ~"payload")),
    ?assertEqual({ok, ~"payload"}, roadrunner_quic_aead:open(OpenKey, IV, 5, ~"aad", Sealed)).
