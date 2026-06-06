-module(roadrunner_quic_tls_hello_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_tls_hello).
%% The `quic` dep, kept as a test-profile differential oracle.
-define(DEP, quic_tls).
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
    ?assertEqual(
        hex("99381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c"),
        maps:get(key_share, Parsed)
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
            key_share => hex("c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f")
        })
    ),
    ?assertEqual(rfc8448_server_hello(), Built).

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
        hex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"),
        maps:get(key_share, Parsed)
    ).

parse_key_share_without_x25519_test() ->
    %% A key_share offering only secp256r1 (0x0017) -> no x25519 key extracted.
    Entry = <<16#0017:16, 4:16, 1, 2, 3, 4>>,
    Exts = [ext(16#0033, <<(byte_size(Entry)):16, Entry/binary>>)],
    {ok, Parsed} = ?M:parse_client_hello(ch_body(<<>>, [16#1301], Exts)),
    ?assertNot(maps:is_key(key_share, Parsed)),
    ?assertEqual([], maps:get(alpn_protocols, Parsed)),
    ?assertEqual([], maps:get(signature_algorithms, Parsed)).

parse_key_share_skips_to_x25519_test() ->
    %% A non-x25519 entry precedes the x25519 entry; find it past the first.
    X25519 = hex("aa00000000000000000000000000000000000000000000000000000000000099"),
    Entries = <<16#0017:16, 2:16, 9, 9, 16#001d:16, 32:16, X25519/binary>>,
    Exts = [ext(16#0033, <<(byte_size(Entries)):16, Entries/binary>>)],
    {ok, Parsed} = ?M:parse_client_hello(ch_body(<<>>, [16#1301], Exts)),
    ?assertEqual(X25519, maps:get(key_share, Parsed)).

parse_rejects_bad_transport_params_test() ->
    %% A server-only transport parameter from a client is rejected by C4.
    Bad = <<16#00, 16#01, 16#aa>>,
    Exts = [ext(16#0039, Bad)],
    ?assertEqual(
        {error, server_only_transport_parameter},
        ?M:parse_client_hello(ch_body(<<>>, [16#1301], Exts))
    ).

parse_empty_extensions_test() ->
    {ok, Parsed} = ?M:parse_client_hello(ch_body(<<1, 2, 3>>, [16#1301, 16#1302], [])),
    ?assertEqual(<<1, 2, 3>>, maps:get(session_id, Parsed)),
    ?assertEqual([16#1301, 16#1302], maps:get(cipher_suites, Parsed)),
    ?assertNot(maps:is_key(key_share, Parsed)),
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
        ext(16#0000, <<16#FF:16>>)
    ],
    {ok, Parsed} = ?M:parse_client_hello(ch_body(<<>>, [16#1301], Exts)),
    ?assertNot(maps:is_key(key_share, Parsed)),
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
%% Differential oracle vs the `quic` dep.
%% =============================================================================

%% The dep parses the RFC 8448 §3 ClientHello to the same v1-subset values.
oracle_parse_matches_dep_test() ->
    {ok, {1, Body}, <<>>} = ?FRAME:decode(rfc8448_client_hello()),
    {ok, Mine} = ?M:parse_client_hello(Body),
    {ok, Dep} = ?DEP:parse_client_hello(Body),
    ?assertEqual(maps:get(random, Dep), maps:get(random, Mine)),
    ?assertEqual(maps:get(session_id, Dep), maps:get(session_id, Mine)),
    ?assertEqual(maps:get(cipher_suites, Dep), maps:get(cipher_suites, Mine)),
    ?assertEqual(maps:get(alpn_protocols, Dep), maps:get(alpn_protocols, Mine)),
    ?assertEqual(maps:get(signature_algorithms, Dep), maps:get(signature_algorithms, Mine)),
    %% The dep keeps key_share as [{Group, Key}]; compare the x25519 entry.
    {16#001d, DepKey} = lists:keyfind(16#001d, 1, maps:get(key_share, Dep)),
    ?assertEqual(DepKey, maps:get(key_share, Mine)).

%% The dep decodes the native EncryptedExtensions to the same extension set.
oracle_encrypted_extensions_matches_dep_test() ->
    Params = #{initial_max_data => 65536, max_idle_timeout => 30000},
    Opts = #{alpn => ~"h3", transport_params => Params},
    Mine = iolist_to_binary(?M:build_encrypted_extensions(Opts)),
    Dep = ?DEP:build_encrypted_extensions(Opts),
    ?assertEqual(Dep, Mine).

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
