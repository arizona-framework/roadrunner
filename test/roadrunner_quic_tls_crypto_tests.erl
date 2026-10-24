-module(roadrunner_quic_tls_crypto_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_tls_crypto).

%% =============================================================================
%% RFC 8448 §3 (Simple 1-RTT Handshake) key schedule — the authority.
%% =============================================================================

transcript_hash_empty_test() ->
    %% SHA-256 of the empty string, the canonical digest.
    ?assertEqual(
        hex(~"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ?M:transcript_hash(<<>>)
    ).

early_secret_test() ->
    %% The no-PSK Early Secret, HKDF-Extract(0, 0).
    ?assertEqual(
        hex(~"33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a"),
        ?M:early_secret()
    ).

derive_secret_test() ->
    %% Derive-Secret(early_secret, "derived", "").
    ?assertEqual(
        hex(~"6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba"),
        ?M:derive_secret(?M:early_secret(), ~"derived", ?M:transcript_hash(<<>>))
    ).

handshake_secret_test() ->
    %% handshake_secret from the §3 x25519 shared secret.
    ?assertEqual(
        hex(~"1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac"),
        ?M:handshake_secret(?M:early_secret(), shared_secret())
    ).

master_secret_test() ->
    HandshakeSecret = ?M:handshake_secret(?M:early_secret(), shared_secret()),
    ?assertEqual(
        hex(~"18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919"),
        ?M:master_secret(HandshakeSecret)
    ).

%% =============================================================================
%% RFC 8448 §3 traffic secrets + Finished — the authority. The
%% transcript-hash contexts are the §3 values.
%% =============================================================================

rfc8448_traffic_secrets_test() ->
    HandshakeSecret = ?M:handshake_secret(?M:early_secret(), shared_secret()),
    MasterSecret = ?M:master_secret(HandshakeSecret),
    HsHash = hex(~"860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8"),
    ApHash = hex(~"96088718a85d2c0d2b21a16a7f637eba132bd1a01feac57b8f8ec571ef41c47c"),
    ?assertEqual(
        hex(~"b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21"),
        ?M:traffic_secret(client, handshake, HandshakeSecret, HsHash)
    ),
    ?assertEqual(
        hex(~"b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38"),
        ?M:traffic_secret(server, handshake, HandshakeSecret, HsHash)
    ),
    ?assertEqual(
        hex(~"775fae04efd2ee7a546c9544a5070c639fe9a67945b7d18310b269e0e9e98069"),
        ?M:traffic_secret(client, application, MasterSecret, ApHash)
    ),
    ?assertEqual(
        hex(~"40d3a34fd7b0c9651bb55866a650eddf179237a2923b2124be7f6eae319aeca0"),
        ?M:traffic_secret(server, application, MasterSecret, ApHash)
    ).

rfc8448_finished_test() ->
    HandshakeSecret = ?M:handshake_secret(?M:early_secret(), shared_secret()),
    HsHash = hex(~"860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8"),
    ServerSecret = ?M:traffic_secret(server, handshake, HandshakeSecret, HsHash),
    FinishedKey = ?M:finished_key(ServerSecret),
    ?assertEqual(
        hex(~"008d3b66f816ea559f96b537e885c31fc068bf492c652f01f288a1d8cdc19fc8"),
        FinishedKey
    ),
    %% Transcript hash over ClientHello..server CertificateVerify.
    FinishedInput = hex(~"91208a9082bb48b14e2f607d839c0d3a55c4f8e1fbb88e3c1ba0e2a32be88a59"),
    ?assertEqual(
        hex(~"5d84b2762deff4fcd2a765d6567d94a9f32e4553166893ad86769457e40564ca"),
        ?M:verify_data(FinishedKey, FinishedInput)
    ).

%% =============================================================================
%% RFC 8448 §5 (HelloRetryRequest), the authority for the message_hash
%% transcript (RFC 8446 §4.4.1) and a P-256 key exchange (§7.4.2).
%% =============================================================================

message_hash_test() ->
    %% Handshake type 254, a 24-bit length of 32, then SHA-256(ClientHello1).
    ClientHello1 = rfc8448_hrr_client_hello1(),
    ?assertEqual(
        <<254, 0, 0, 32, (crypto:hash(sha256, ClientHello1))/binary>>,
        iolist_to_binary(?M:message_hash(ClientHello1))
    ).

%% The transcript through the ServerHello after a retry starts with the
%% message_hash of the first ClientHello, then the HelloRetryRequest, the
%% second ClientHello, and the ServerHello.
rfc8448_hello_retry_transcript_test() ->
    ?assertEqual(
        rfc8448_hrr_hello_hash(),
        ?M:transcript_hash([
            ?M:message_hash(rfc8448_hrr_client_hello1()),
            rfc8448_hrr_hello_retry_request(),
            rfc8448_hrr_client_hello2(),
            rfc8448_hrr_server_hello()
        ])
    ).

%% The P-256 ECDHE shared secret is the X coordinate of the shared point
%% (RFC 8446 §7.4.2), here from the client's public share and the server's
%% private key, and the §5 handshake traffic secrets follow from it.
rfc8448_p256_handshake_secrets_test() ->
    ClientShare = hex(
        ~"04a6da7392ec591e17abfd535964b99894d13befb221b3def2ebe3830eac8f0151812677c4d6d2237e85cf01d6910cfb83954e76ba7352830534159897e8065780"
    ),
    ServerPriv = hex(~"8c510601f9765bfb8ed693449a48989859b5cfa879cb9f5443c41c5ff10634ed"),
    Shared = crypto:compute_key(ecdh, ClientShare, ServerPriv, secp256r1),
    ?assertEqual(
        hex(~"c142ce13ca11b5c2233652e63ad3d97844f1621fbfb9de69d547dc8fedeabeb4"), Shared
    ),
    HandshakeSecret = ?M:handshake_secret(?M:early_secret(), Shared),
    ?assertEqual(
        hex(~"ce022e5e6e81e50736d773f2d3adfce8220d049bf510f0dbfac927ef4243b148"),
        HandshakeSecret
    ),
    ?assertEqual(
        hex(~"158aa7ab8855073582b41d674b4055cabcc534728f659314861b4e08e2011566"),
        ?M:traffic_secret(client, handshake, HandshakeSecret, rfc8448_hrr_hello_hash())
    ),
    ?assertEqual(
        hex(~"3403e781e2af7b6508da28574f6e95a1abf162de83a97927c37672a4a0cef8a1"),
        ?M:traffic_secret(server, handshake, HandshakeSecret, rfc8448_hrr_hello_hash())
    ).

rfc8448_hrr_hello_hash() ->
    hex(~"8aa8e828ec2f8a884fec95a3139de01c15a3daa7ff5bfc3f4bfcc21b438d7bf8").

%% RFC 8448 §5's handshake messages, framed: the first ClientHello (an x25519
%% share), the HelloRetryRequest (asking for P-256, with a cookie), the second
%% ClientHello (a P-256 share, the cookie, and 175 bytes of padding), and the
%% ServerHello.
rfc8448_hrr_client_hello1() ->
    hex(
        "010000b00303b0b1c5a5aa37c5919f2ed1d5c6fff7fcb7849716945a2b8cee9258a34667"
        "7b6f000006130113031302010000810000000b0009000006736572766572ff0100010000"
        "0a00080006001d00170018003300260024001d0020e8e8e3f3b93a25ed97a14a7dcacb8a"
        "272c6288e585c6484d05262fcad062ad1f002b0003020304000d0020001e040305030603"
        "020308040805080604010501060102010402050206020202002d00020101001c00024001"
    ).

rfc8448_hrr_hello_retry_request() ->
    hex(
        "020000ac0303cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8"
        "339c001301000084003300020017002c0074007271dcd04bb88bc3189119398a00000000"
        "eefafc76c146b823b096f8aacad365dd0030953f4edf625636e5f21bb2e23fcc654b1b5b"
        "40318d10d137abcbb87574e36e8a1f025f7dfa5d6e50781b5eda4aa15b0c8be778257d16"
        "aa3030e9e7841dd9e4c0342267e8ca0caf571fb2b7cff0f934b0002b00020304"
    ).

rfc8448_hrr_client_hello2() ->
    Head = hex(
        "010001fc0303b0b1c5a5aa37c5919f2ed1d5c6fff7fcb7849716945a2b8cee9258a34667"
        "7b6f000006130113031302010001cd0000000b0009000006736572766572ff0100010000"
        "0a00080006001d001700180033004700450017004104a6da7392ec591e17abfd535964b9"
        "9894d13befb221b3def2ebe3830eac8f0151812677c4d6d2237e85cf01d6910cfb83954e"
        "76ba7352830534159897e8065780002b0003020304000d0020001e040305030603020308"
        "040805080604010501060102010402050206020202002c0074007271dcd04bb88bc31891"
        "19398a00000000eefafc76c146b823b096f8aacad365dd0030953f4edf625636e5f21bb2"
        "e23fcc654b1b5b40318d10d137abcbb87574e36e8a1f025f7dfa5d6e50781b5eda4aa15b"
        "0c8be778257d16aa3030e9e7841dd9e4c0342267e8ca0caf571fb2b7cff0f934b0002d00"
        "020101001c00024001001500af"
    ),
    <<Head/binary, 0:(175 * 8)>>.

rfc8448_hrr_server_hello() ->
    hex(
        "020000770303bb341d847fd789c47c387172dc0c9bf147fccacb5043d86ca4c598d3ff57"
        "1b9800130100004f003300450017004104583e054b7a66672ae020ad9d2686fcc85b5ad4"
        "1a134a0f03ee72b893052bd85b4c8de6776f5b04ac07d83540eab3e3d9c547bc6528c431"
        "7d294686093a6cad7d002b00020304"
    ).

%% RFC 8448 §3 ECDHE (x25519) shared secret.
shared_secret() ->
    hex(~"8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d").

%% Uppercase before decoding so the literals are portable across OTP
%% versions regardless of `binary:decode_hex/1`'s lowercase handling. A
%% multi-line vector is adjacent plain strings, so take any iodata.
hex(Hex) -> binary:decode_hex(string:uppercase(iolist_to_binary(Hex))).
