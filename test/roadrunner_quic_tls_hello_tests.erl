-module(roadrunner_quic_tls_hello_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_tls_hello).
-define(FRAME, roadrunner_quic_tls_handshake).

%% =============================================================================
%% RFC 8448 §3 "Simple 1-RTT Handshake" — the authority. Its ClientHello and
%% ServerHello use x25519 + TLS_AES_128_GCM_SHA256, exactly v1's profile.
%% =============================================================================

rfc8448_client_hello_parse_test() ->
    {ok, {1, Body}, <<>>} = ?FRAME:decode(rfc8448_client_hello()),
    {ok, Parsed} = ?M:parse_client_hello(Body),
    ?assertEqual(
        hex("cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7"),
        maps:get(random, Parsed)
    ),
    ?assertEqual(<<>>, maps:get(session_id, Parsed)),
    ?assertEqual([16#1301, 16#1303, 16#1302], maps:get(cipher_suites, Parsed)),
    ?assertEqual([16#0304], maps:get(supported_versions, Parsed)),
    ?assertEqual(
        [{16#001D, hex("99381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c")}],
        maps:get(key_shares, Parsed)
    ),
    %% x25519, secp256r1, secp384r1, secp521r1, then ffdhe2048..ffdhe8192.
    ?assertEqual(
        [16#001D, 16#0017, 16#0018, 16#0019, 16#0100, 16#0101, 16#0102, 16#0103, 16#0104],
        maps:get(supported_groups, Parsed)
    ),
    ?assertEqual(<<"server">>, maps:get(server_name, Parsed)),
    %% This ClientHello carries no ALPN and no quic_transport_parameters.
    ?assertEqual([], maps:get(alpn_protocols, Parsed)),
    ?assertNot(maps:is_key(transport_params, Parsed)),
    ?assertEqual(
        [
            16#0403,
            16#0503,
            16#0603,
            16#0203,
            16#0804,
            16#0805,
            16#0806,
            16#0401,
            16#0501,
            16#0601,
            16#0201,
            16#0402,
            16#0502,
            16#0602,
            16#0202
        ],
        maps:get(signature_algorithms, Parsed)
    ).

rfc8448_server_hello_build_test() ->
    Built = iolist_to_binary(
        ?M:build_server_hello(#{
            random => hex("a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e26928"),
            session_id => <<>>,
            cipher_suite => 16#1301,
            key_share =>
                {16#001D, hex("c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f")}
        })
    ),
    ?assertEqual(rfc8448_server_hello(), Built).

%% =============================================================================
%% RFC 8448 §5 "HelloRetryRequest": the client offers an x25519 share, the
%% server asks for P-256, and the client retries with a P-256 share.
%% =============================================================================

rfc8448_hello_retry_client_hellos_parse_test() ->
    {ok, {1, Body1}, <<>>} = ?FRAME:decode(rfc8448_hrr_client_hello1()),
    {ok, Parsed1} = ?M:parse_client_hello(Body1),
    ?assertEqual([16#001D, 16#0017, 16#0018], maps:get(supported_groups, Parsed1)),
    ?assertEqual(
        [{16#001D, hex("e8e8e3f3b93a25ed97a14a7dcacb8a272c6288e585c6484d05262fcad062ad1f")}],
        maps:get(key_shares, Parsed1)
    ),
    %% The second ClientHello replaces the shares with one P-256 share (an
    %% uncompressed point) and keeps the rest (RFC 8446 §4.1.2).
    {ok, {1, Body2}, <<>>} = ?FRAME:decode(rfc8448_hrr_client_hello2()),
    {ok, Parsed2} = ?M:parse_client_hello(Body2),
    ?assertEqual([16#001D, 16#0017, 16#0018], maps:get(supported_groups, Parsed2)),
    ?assertEqual([{16#0017, rfc8448_hrr_client_p256_share()}], maps:get(key_shares, Parsed2)),
    ?assertEqual(maps:get(random, Parsed1), maps:get(random, Parsed2)).

rfc8448_p256_server_hello_build_test() ->
    Built = iolist_to_binary(
        ?M:build_server_hello(#{
            random => hex("bb341d847fd789c47c387172dc0c9bf147fccacb5043d86ca4c598d3ff571b98"),
            session_id => <<>>,
            cipher_suite => 16#1301,
            key_share => {16#0017, rfc8448_hrr_server_p256_share()}
        })
    ),
    ?assertEqual(rfc8448_hrr_server_hello(), Built).

%% RFC 8448 §5's HelloRetryRequest also carries a cookie (RFC 8446 §4.2.2),
%% which this server does not send; without that extension it is the
%% special Random, the cipher suite, a key_share naming secp256r1, and
%% supported_versions selecting TLS 1.3.
hello_retry_request_build_test() ->
    Built = iolist_to_binary(
        ?M:build_hello_retry_request(#{
            session_id => <<>>, cipher_suite => 16#1301, group => 16#0017
        })
    ),
    ?assertEqual(
        hex(
            "020000340303cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c"
            "00130100000c00330002001700"
            "2b00020304"
        ),
        Built
    ),
    %% The Random is SHA-256("HelloRetryRequest") (RFC 8446 §4.1.3).
    <<2, _:24, 16#0303:16, Random:32/binary, _/binary>> = Built,
    ?assertEqual(crypto:hash(sha256, ~"HelloRetryRequest"), Random).

hello_retry_request_echoes_session_id_test() ->
    Built = iolist_to_binary(
        ?M:build_hello_retry_request(#{
            session_id => <<1, 2, 3>>, cipher_suite => 16#1303, group => 16#001D
        })
    ),
    <<2, _:24, 16#0303:16, _Random:32/binary, 3:8, 1, 2, 3, 16#1303:16, 0:8, 12:16, 16#0033:16,
        2:16, 16#001D:16, 16#002B:16, 2:16, 16#0304:16>> = Built.

%% =============================================================================
%% EncryptedExtensions build (QUIC: ALPN + transport parameters).
%% =============================================================================

encrypted_extensions_build_test() ->
    Params = #{initial_max_data => 1048576, initial_max_streams_bidi => 16},
    EE = iolist_to_binary(
        ?M:build_encrypted_extensions(#{alpn => ~"h3", transport_params => Params})
    ),
    %% Framed message: type 8, then <<ExtLen:16, ALPN, TP>>.
    {ok, {8, Body}, <<>>} = ?FRAME:decode(EE),
    <<ExtLen:16, Exts:ExtLen/binary>> = Body,
    %% ALPN extension (0x0010): ProtocolNameList = <<NamesLen:16, Len:8, "h3">>.
    AlpnData = <<3:16, 2:8, "h3">>,
    Alpn = <<16#0010:16, (byte_size(AlpnData)):16, AlpnData/binary>>,
    %% Transport params extension (0x0039) carrying the C4-encoded body.
    TPData = iolist_to_binary(roadrunner_quic_transport_params:encode(Params)),
    TP = <<16#0039:16, (byte_size(TPData)):16, TPData/binary>>,
    ?assertEqual(<<Alpn/binary, TP/binary>>, Exts).

encrypted_extensions_omits_absent_test() ->
    %% No alpn, no transport_params -> an empty extension list.
    EE = iolist_to_binary(?M:build_encrypted_extensions(#{})),
    {ok, {8, Body}, <<>>} = ?FRAME:decode(EE),
    ?assertEqual(<<0:16>>, Body).

encrypted_extensions_omits_empty_test() ->
    %% A present-but-empty protocol or params map is treated as absent
    %% (a zero-length ALPN ProtocolName would be invalid per RFC 7301).
    EE = iolist_to_binary(?M:build_encrypted_extensions(#{alpn => <<>>, transport_params => #{}})),
    {ok, {8, Body}, <<>>} = ?FRAME:decode(EE),
    ?assertEqual(<<0:16>>, Body).

%% =============================================================================
%% parse_client_hello — extension extraction edges (crafted ClientHellos).
%% =============================================================================

parse_extracts_alpn_and_transport_params_test() ->
    Params = #{initial_max_data => 4096},
    TPData = iolist_to_binary(roadrunner_quic_transport_params:encode(Params)),
    Exts = [
        ext(16#0010, <<3:16, 2:8, "h3">>),
        key_share_ext(hex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")),
        ext(16#0039, TPData)
    ],
    {ok, Parsed} = ?M:parse_client_hello(ch_body(<<>>, [16#1301], Exts)),
    ?assertEqual([~"h3"], maps:get(alpn_protocols, Parsed)),
    ?assertEqual({ok, Params}, {ok, maps:get(transport_params, Parsed)}),
    ?assertEqual(
        [{16#001D, hex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")}],
        maps:get(key_shares, Parsed)
    ).

parse_key_shares_in_client_order_test() ->
    %% Every entry, any group, in the client's order (RFC 8446 §4.2.8); the
    %% server, not the codec, picks among them. A trailing partial entry is
    %% dropped.
    X25519 = hex("aa00000000000000000000000000000000000000000000000000000000000099"),
    Entries = <<16#0017:16, 2:16, 9, 9, 16#001d:16, 32:16, X25519/binary, 16#0018:16, 5:16, 1>>,
    Exts = [ext(16#0033, <<(byte_size(Entries)):16, Entries/binary>>)],
    {ok, Parsed} = ?M:parse_client_hello(ch_body(<<>>, [16#1301], Exts)),
    ?assertEqual([{16#0017, <<9, 9>>}, {16#001D, X25519}], maps:get(key_shares, Parsed)),
    ?assertNot(maps:is_key(supported_groups, Parsed)),
    ?assertEqual([], maps:get(alpn_protocols, Parsed)),
    ?assertEqual([], maps:get(signature_algorithms, Parsed)).

parse_empty_key_share_and_groups_test() ->
    %% An empty client_shares vector is a valid offer (the client asks the
    %% server to pick, RFC 8446 §4.2.8), kept apart from an absent one.
    Exts = [ext(16#0033, <<0:16>>), ext(16#000A, <<4:16, 16#001D:16, 16#0017:16>>)],
    {ok, Parsed} = ?M:parse_client_hello(ch_body(<<>>, [16#1301], Exts)),
    ?assertEqual([], maps:get(key_shares, Parsed)),
    ?assertEqual([16#001D, 16#0017], maps:get(supported_groups, Parsed)).

parse_rejects_bad_transport_params_test() ->
    %% A server-only transport parameter from a client is rejected by C4,
    %% surfaced as TRANSPORT_PARAMETER_ERROR (RFC 9000 §18.2).
    Bad = <<16#00, 16#01, 16#aa>>,
    Exts = [ext(16#0039, Bad)],
    ?assertEqual(
        {error, transport_parameter_error},
        ?M:parse_client_hello(ch_body(<<>>, [16#1301], Exts))
    ).

parse_supported_versions_test() ->
    %% A one-byte-length list of 16-bit versions (RFC 8446 §4.2.1), kept in
    %% the client's order, unknown values included.
    Exts = [ext(16#002B, <<6:8, 16#7A7A:16, 16#0304:16, 16#0303:16>>)],
    {ok, Parsed} = ?M:parse_client_hello(ch_body(<<>>, [16#1301], Exts)),
    ?assertEqual([16#7A7A, 16#0304, 16#0303], maps:get(supported_versions, Parsed)).

parse_empty_extensions_test() ->
    {ok, Parsed} = ?M:parse_client_hello(ch_body(<<1, 2, 3>>, [16#1301, 16#1302], [])),
    ?assertEqual(<<1, 2, 3>>, maps:get(session_id, Parsed)),
    ?assertEqual([16#1301, 16#1302], maps:get(cipher_suites, Parsed)),
    %% No supported_versions: a TLS 1.2-style ClientHello offers no TLS 1.3.
    ?assertEqual([], maps:get(supported_versions, Parsed)),
    ?assertNot(maps:is_key(key_shares, Parsed)),
    ?assertNot(maps:is_key(supported_groups, Parsed)),
    ?assertNot(maps:is_key(server_name, Parsed)).

parse_lenient_on_malformed_extension_data_test() ->
    %% Each extension's inner length prefix overruns its data; extraction
    %% is lenient (absent/empty), never a crash. The transport parameters
    %% are the one extension whose decode error would propagate, so they
    %% are not included here.
    Exts = [
        ext(16#0033, <<16#FF:16, 1, 2>>),
        ext(16#0010, <<16#FF:16>>),
        ext(16#000D, <<16#FF:16>>),
        ext(16#0000, <<16#FF:16>>),
        ext(16#002B, <<16#FF:8>>),
        ext(16#000A, <<16#FF:16>>)
    ],
    {ok, Parsed} = ?M:parse_client_hello(ch_body(<<>>, [16#1301], Exts)),
    ?assertNot(maps:is_key(key_shares, Parsed)),
    ?assertNot(maps:is_key(supported_groups, Parsed)),
    ?assertEqual([], maps:get(supported_versions, Parsed)),
    ?assertEqual([], maps:get(alpn_protocols, Parsed)),
    ?assertEqual([], maps:get(signature_algorithms, Parsed)),
    ?assertNot(maps:is_key(server_name, Parsed)).

%% =============================================================================
%% parse_client_hello — malformed input is a flat error, never a crash.
%% =============================================================================

parse_rejects_wrong_legacy_version_test() ->
    ?assertEqual({error, malformed_client_hello}, ?M:parse_client_hello(<<16#0304:16, 0:256>>)).

parse_rejects_truncated_test() ->
    ?assertMatch({error, _}, ?M:parse_client_hello(<<>>)),
    ?assertMatch({error, _}, ?M:parse_client_hello(<<16#0303:16>>)),
    %% Header present, but the session-id length overruns.
    ?assertEqual(
        {error, truncated},
        ?M:parse_client_hello(<<16#0303:16, 0:256, 5:8, 1, 2>>)
    ).

parse_rejects_duplicate_extension_test() ->
    Exts = [ext(16#0010, <<0:16>>), ext(16#0010, <<0:16>>)],
    ?assertEqual(
        {error, duplicate_extension},
        ?M:parse_client_hello(ch_body(<<>>, [16#1301], Exts))
    ).

parse_rejects_malformed_extensions_test() ->
    %% An extension header that overruns the extensions block.
    Exts = <<16#0010:16, 16#FF:16, 1, 2>>,
    ?assertEqual(
        {error, malformed_extensions},
        ?M:parse_client_hello(ch_body_raw_exts(<<>>, [16#1301], Exts))
    ).

%% =============================================================================
%% Fixtures and helpers
%% =============================================================================

%% Build a ClientHello body with the given session id, cipher list, and a
%% list of already-encoded extensions.
ch_body(SessionId, Ciphers, Exts) ->
    ch_body_raw_exts(SessionId, Ciphers, iolist_to_binary(Exts)).

ch_body_raw_exts(SessionId, Ciphers, ExtBytes) ->
    CipherBytes = <<<<C:16>> || C <- Ciphers>>,
    Random = binary:copy(<<7>>, 32),
    iolist_to_binary([
        <<16#0303:16, Random/binary, (byte_size(SessionId)):8>>,
        SessionId,
        <<(byte_size(CipherBytes)):16>>,
        CipherBytes,
        <<1:8, 0:8>>,
        <<(byte_size(ExtBytes)):16>>,
        ExtBytes
    ]).

%% One encoded extension: Type:16, Length:16, Data.
ext(Type, Data) ->
    <<Type:16, (byte_size(Data)):16, Data/binary>>.

%% A client key_share extension carrying a single x25519 entry.
key_share_ext(PubKey) ->
    Entry = <<16#001d:16, (byte_size(PubKey)):16, PubKey/binary>>,
    ext(16#0033, <<(byte_size(Entry)):16, Entry/binary>>).

rfc8448_client_hello() ->
    hex(
        "010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024d"
        "ece7000006130113031302010000910000000b0009000006736572766572ff0100010000"
        "0a00140012001d00170018001901000101010201030104002300000033002600240"
        "01d002099381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c"
        "002b0003020304000d0020001e040305030603020308040805080604010501060102010"
        "402050206020202002d00020101001c00024001"
    ).

%% RFC 8448 §5's first ClientHello (an x25519 share) and second ClientHello
%% (a P-256 share, a cookie, and 175 bytes of padding), framed.
rfc8448_hrr_client_hello1() ->
    hex(
        "010000b00303b0b1c5a5aa37c5919f2ed1d5c6fff7fcb7849716945a2b8cee9258a34667"
        "7b6f000006130113031302010000810000000b0009000006736572766572ff0100010000"
        "0a00080006001d00170018003300260024001d0020e8e8e3f3b93a25ed97a14a7dcacb8a"
        "272c6288e585c6484d05262fcad062ad1f002b0003020304000d0020001e040305030603"
        "020308040805080604010501060102010402050206020202002d00020101001c00024001"
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

rfc8448_hrr_client_p256_share() ->
    hex(
        "04a6da7392ec591e17abfd535964b99894d13befb221b3def2ebe3830eac8f0151812677"
        "c4d6d2237e85cf01d6910cfb83954e76ba7352830534159897e8065780"
    ).

rfc8448_hrr_server_p256_share() ->
    hex(
        "04583e054b7a66672ae020ad9d2686fcc85b5ad41a134a0f03ee72b893052bd85b4c8de6"
        "776f5b04ac07d83540eab3e3d9c547bc6528c4317d294686093a6cad7d"
    ).

%% RFC 8448 §5's ServerHello after the retry (a P-256 share), framed.
rfc8448_hrr_server_hello() ->
    hex(
        "020000770303bb341d847fd789c47c387172dc0c9bf147fccacb5043d86ca4c598d3ff57"
        "1b9800130100004f003300450017004104583e054b7a66672ae020ad9d2686fcc85b5ad4"
        "1a134a0f03ee72b893052bd85b4c8de6776f5b04ac07d83540eab3e3d9c547bc6528c431"
        "7d294686093a6cad7d002b00020304"
    ).

rfc8448_server_hello() ->
    hex(
        "0200005603 03a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2"
        "692800130100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc25"
        "3b833df1dd69b1b04e751f0f002b00020304"
    ).

%% Decode a (possibly whitespace-formatted) hex string to bytes.
hex(Hex) ->
    Bytes = <<<<B>> || <<B>> <= iolist_to_binary(Hex), B =/= $\s, B =/= $\n>>,
    binary:decode_hex(string:uppercase(Bytes)).
