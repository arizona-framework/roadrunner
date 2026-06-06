-module(roadrunner_quic_tls_handshake_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_tls_handshake).
%% The `quic` dep, kept as a test-profile differential oracle.
-define(DEP, quic_tls).

%% RFC 8446 §4 HandshakeType values exercised here.
-define(CLIENT_HELLO, 1).
-define(SERVER_HELLO, 2).
-define(ENCRYPTED_EXTENSIONS, 8).
-define(CERTIFICATE, 11).
-define(CERTIFICATE_VERIFY, 15).
-define(FINISHED, 20).

%% =============================================================================
%% RFC 8446 §4 framing structure — the authority.
%%
%% Handshake = <<HandshakeType:8, Length:24, Body:Length/binary>>; the
%% length is the body length, big-endian, excluding the 4-byte header.
%% =============================================================================

rfc_finished_vector_test() ->
    %% Finished (type 20) carrying a 32-byte verify_data (SHA-256 suite):
    %% <<20, 0,0,32, ...32 bytes...>>, 36 bytes on the wire.
    VerifyData = binary:copy(<<16#ab>>, 32),
    Wire = <<?FINISHED, 0, 0, 32, VerifyData/binary>>,
    ?assertEqual(Wire, enc(?FINISHED, VerifyData)),
    ?assertEqual({ok, {?FINISHED, VerifyData}, <<>>}, ?M:decode(Wire)).

rfc_empty_body_vector_test() ->
    %% A zero-length body frames to just the 4-byte header.
    ?assertEqual(<<?SERVER_HELLO, 0, 0, 0>>, enc(?SERVER_HELLO, <<>>)),
    ?assertEqual({ok, {?SERVER_HELLO, <<>>}, <<>>}, ?M:decode(<<?SERVER_HELLO, 0, 0, 0>>)).

rfc_multibyte_length_vector_test() ->
    %% 300-byte body -> length 0x00012C spans two of the three length bytes.
    Body = binary:copy(<<7>>, 300),
    ?assertEqual(<<?CERTIFICATE, 0, 16#01, 16#2C, Body/binary>>, enc(?CERTIFICATE, Body)),
    %% 70000-byte body exercises the high byte of the uint24 length.
    Big = binary:copy(<<9>>, 70000),
    ?assertEqual(<<?CERTIFICATE, 16#01, 16#11, 16#70, Big/binary>>, enc(?CERTIFICATE, Big)).

%% =============================================================================
%% encode/2 — iolist body kept by reference, iodata bodies.
%% =============================================================================

encode_keeps_body_by_reference_test() ->
    %% The body is the same term in the iolist, never copied into the header.
    Body = binary:copy(<<16#5a>>, 64),
    ?assertEqual([<<?CERTIFICATE, 0, 0, 64>>, Body], ?M:encode(?CERTIFICATE, Body)).

encode_accepts_iodata_body_test() ->
    %% An iolist body is framed with its flattened size, never pre-flattened.
    ?assertEqual(
        <<?ENCRYPTED_EXTENSIONS, 0, 0, 4, "abcd">>,
        enc(?ENCRYPTED_EXTENSIONS, [<<"ab">>, <<"cd">>])
    ).

encode_type_boundaries_test() ->
    %% Any uint8 type frames into the single type byte.
    ?assertEqual(<<0, 0, 0, 0>>, enc(0, <<>>)),
    ?assertEqual(<<255, 0, 0, 1, 16#ff>>, enc(255, <<16#ff>>)).

%% =============================================================================
%% decode/1 — trailing bytes, back-to-back messages.
%% =============================================================================

decode_keeps_trailing_bytes_test() ->
    %% One message followed by two trailing bytes: Rest carries them.
    ?assertEqual(
        {ok, {?FINISHED, <<16#aa>>}, <<16#bb, 16#cc>>},
        ?M:decode(<<?FINISHED, 0, 0, 1, 16#aa, 16#bb, 16#cc>>)
    ).

decode_back_to_back_messages_test() ->
    %% Two framed messages concatenated decode in sequence via Rest.
    First = enc(?SERVER_HELLO, <<"hello">>),
    Second = enc(?FINISHED, <<"done">>),
    {ok, {?SERVER_HELLO, <<"hello">>}, Rest} = ?M:decode(<<First/binary, Second/binary>>),
    ?assertEqual(Second, Rest),
    ?assertEqual({ok, {?FINISHED, <<"done">>}, <<>>}, ?M:decode(Rest)).

%% =============================================================================
%% decode/1 — incomplete buffers report the two-phase {more, Need}.
%% =============================================================================

decode_short_header_returns_more_test() ->
    %% Fewer than 4 header bytes: ask for the rest of the header.
    ?assertEqual({more, 4}, ?M:decode(<<>>)),
    ?assertEqual({more, 3}, ?M:decode(<<?FINISHED>>)),
    ?assertEqual({more, 2}, ?M:decode(<<?FINISHED, 0>>)),
    ?assertEqual({more, 1}, ?M:decode(<<?FINISHED, 0, 0>>)).

decode_short_body_returns_more_test() ->
    %% Full header, body short: ask for the remaining body bytes.
    %% Header only (length 32, zero body present) -> need all 32.
    ?assertEqual({more, 32}, ?M:decode(<<?FINISHED, 0, 0, 32>>)),
    %% Length 5, three body bytes present -> need 2 more.
    ?assertEqual({more, 2}, ?M:decode(<<?CERTIFICATE, 0, 0, 5, "abc">>)).

%% =============================================================================
%% Differential oracle vs the `quic` dep (kept as a test-profile dep).
%% =============================================================================

%% Encode is byte-for-byte identical to the dep's flat-binary framing.
oracle_encode_matches_dep_test() ->
    [
        ?assertEqual(?DEP:encode_handshake_message(Type, Body), enc(Type, Body))
     || {Type, Body} <- oracle_messages()
    ].

%% A complete message decodes to the same {ok, {Type, Body}, Rest} the dep
%% yields (the dep's success shape matches the native one exactly).
oracle_decode_matches_dep_test() ->
    [
        begin
            Wire = ?DEP:encode_handshake_message(Type, Body),
            ?assertEqual(?DEP:decode_handshake_message(Wire), ?M:decode(Wire))
        end
     || {Type, Body} <- oracle_messages()
    ].

%% Representative messages: server-emitted types, boundary type bytes, and
%% bodies that span one, two, and all three uint24 length bytes.
oracle_messages() ->
    [
        {?CLIENT_HELLO, <<"client hello body">>},
        {?SERVER_HELLO, <<>>},
        {?ENCRYPTED_EXTENSIONS, binary:copy(<<3>>, 17)},
        {?CERTIFICATE, binary:copy(<<7>>, 300)},
        {?CERTIFICATE_VERIFY, binary:copy(<<8>>, 64)},
        {?FINISHED, binary:copy(<<16#ab>>, 32)},
        {0, <<>>},
        {255, <<16#ff>>},
        {?CERTIFICATE, binary:copy(<<9>>, 70000)}
    ].

%% =============================================================================
%% Helpers
%% =============================================================================

%% Flatten the encoder's iolist to compare against the dep's flat binary.
enc(Type, Body) ->
    iolist_to_binary(?M:encode(Type, Body)).
