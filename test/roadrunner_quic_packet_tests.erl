-module(roadrunner_quic_packet_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_packet).

%% QUIC v1.
-define(V1, 16#00000001).
%% RFC 9001 Appendix A example client DCID.
-define(DCID, <<16#83, 16#94, 16#c8, 16#f0, 16#3e, 16#51, 16#57, 16#08>>).
-define(SCID, <<1, 2, 3, 4>>).

enc(Iolist) -> iolist_to_binary(Iolist).

%% =============================================================================
%% Encode helpers and structural checks.
%% =============================================================================

long_opts_cases(initial) ->
    [
        #{token => <<>>, pn => 0, payload => <<>>},
        #{token => <<"tok">>, pn => 2, payload => <<"frames">>},
        %% Packet numbers spanning each truncated width.
        #{token => <<>>, pn => 255, payload => <<1, 2, 3>>},
        #{token => <<>>, pn => 256, payload => <<1, 2, 3>>},
        #{token => <<>>, pn => 65536, payload => <<1, 2, 3>>},
        #{token => <<>>, pn => 16777216, payload => binary:copy(<<0>>, 100)}
    ];
long_opts_cases(_Type) ->
    [
        #{pn => 0, payload => <<>>},
        #{pn => 1000, payload => <<"abc">>},
        #{pn => 16777216, payload => binary:copy(<<9>>, 50)}
    ].

encode_short_default_key_phase_test() ->
    ?assertEqual(
        enc(?M:encode_short(?DCID, 5, <<"x">>, false, 0)),
        enc(?M:encode_short(?DCID, 5, <<"x">>, false))
    ).

encode_short_spin_bit_set_test() ->
    %% A true spin bit sets first-byte bit 5 (RFC 9000 §17.3.1).
    <<FirstByte, _/binary>> = enc(?M:encode_short(?DCID, 5, <<"x">>, true)),
    ?assertEqual(2#00100000, FirstByte band 2#00100000).

%% =============================================================================
%% Round-trip: encode then decode (header protection is not applied here).
%% =============================================================================

roundtrip_long_test() ->
    [
        begin
            Bin = enc(?M:encode_long(Type, ?V1, ?DCID, ?SCID, Opts)),
            #{pn := PN, payload := Payload} = Opts1 = expected_long(Type, Opts),
            ?assertEqual({ok, Opts1, <<>>}, ?M:decode(Bin, byte_size(?DCID))),
            %% pn_offset points exactly at the encoded packet number.
            {ok, Off} = ?M:pn_offset(Bin, byte_size(?DCID)),
            PNLen = ?M:pn_length(PN),
            <<_:Off/binary, PNBin:PNLen/binary, Rest/binary>> = Bin,
            ?assertEqual(?M:encode_pn(PN, PNLen), PNBin),
            ?assertEqual(Payload, Rest)
        end
     || Type <- [initial, handshake, zero_rtt], Opts <- long_opts_cases(Type)
    ].

expected_long(initial, #{token := Token, pn := PN, payload := Payload}) ->
    #{
        type => initial,
        version => ?V1,
        dcid => ?DCID,
        scid => ?SCID,
        token => Token,
        pn => PN,
        payload => Payload
    };
expected_long(Type, #{pn := PN, payload := Payload}) ->
    #{type => Type, version => ?V1, dcid => ?DCID, scid => ?SCID, pn => PN, payload => Payload}.

roundtrip_short_test() ->
    DCIDLen = byte_size(?DCID),
    [
        begin
            Bin = enc(?M:encode_short(?DCID, PN, Payload, false, KeyPhase)),
            ?assertEqual(
                {ok, #{type => one_rtt, dcid => ?DCID, pn => PN, payload => Payload}, <<>>},
                ?M:decode(Bin, DCIDLen)
            ),
            {ok, Off} = ?M:pn_offset(Bin, DCIDLen),
            ?assertEqual(1 + DCIDLen, Off),
            <<FirstByte, _/binary>> = Bin,
            ?assertEqual(KeyPhase, ?M:key_phase(FirstByte))
        end
     || PN <- [0, 300, 70000], Payload <- [<<>>, <<"body">>], KeyPhase <- [0, 1]
    ].

%% =============================================================================
%% Coalesced decode.
%% =============================================================================

%% A coalesced datagram (Initial followed by a short-header packet): the
%% Initial decodes and leaves the short-header bytes as the remainder.
decode_coalesced_test() ->
    First = enc(?M:encode_long(initial, ?V1, ?DCID, ?SCID, #{pn => 1, payload => <<"a">>})),
    Second = enc(?M:encode_short(?DCID, 2, <<"b">>, false)),
    {ok, #{type := initial}, Rest} = ?M:decode(<<First/binary, Second/binary>>, byte_size(?DCID)),
    ?assertEqual(Second, Rest).

%% =============================================================================
%% coalesced_split/1 (works on a still-protected datagram).
%% =============================================================================

%% A long-header packet is bounded by its Length field, leaving the
%% following coalesced packet as the remainder.
coalesced_split_long_test() ->
    First = enc(?M:encode_long(initial, ?V1, ?DCID, ?SCID, #{pn => 1, payload => <<"abc">>})),
    Second = enc(?M:encode_short(?DCID, 2, <<"d">>, false)),
    ?assertEqual(
        {ok, First, Second}, ?M:coalesced_split(<<First/binary, Second/binary>>)
    ).

%% A short-header packet runs to the end of the datagram (no remainder).
coalesced_split_short_test() ->
    Short = enc(?M:encode_short(?DCID, 2, <<"body">>, false)),
    ?assertEqual({ok, Short, <<>>}, ?M:coalesced_split(Short)).

%% Empty input and trailing padding (a zero first byte / cleared fixed
%% bit) end the coalesced run.
coalesced_split_done_test() ->
    ?assertEqual(done, ?M:coalesced_split(<<>>)),
    ?assertEqual(done, ?M:coalesced_split(<<0, 0, 0>>)).

%% A long header truncated before its connection IDs cannot be bounded.
coalesced_split_truncated_test() ->
    ?assertEqual({error, truncated}, ?M:coalesced_split(<<16#C0, ?V1:32, 8>>)).

%% A long header whose Length field claims more bytes than the datagram
%% holds cannot be sliced.
coalesced_split_length_exceeds_test() ->
    Full = enc(?M:encode_long(initial, ?V1, ?DCID, ?SCID, #{pn => 1, payload => <<"abcdefgh">>})),
    Truncated = binary:part(Full, 0, byte_size(Full) - 4),
    ?assertEqual({error, truncated}, ?M:coalesced_split(Truncated)).

%% A long header whose DCID length exceeds the 20-byte maximum is invalid.
coalesced_split_invalid_cid_test() ->
    ?assertEqual(
        {error, invalid_packet}, ?M:coalesced_split(<<16#C0, ?V1:32, 21>>)
    ).

%% =============================================================================
%% dcid/2 routing (works on a still-protected packet).
%% =============================================================================

dcid_test() ->
    Long = enc(?M:encode_long(handshake, ?V1, ?DCID, ?SCID, #{pn => 0, payload => <<>>})),
    ?assertEqual({ok, ?DCID}, ?M:dcid(Long, 0)),
    Short = enc(?M:encode_short(?DCID, 0, <<>>, false)),
    ?assertEqual({ok, ?DCID}, ?M:dcid(Short, byte_size(?DCID))).

%% =============================================================================
%% Packet-number coding.
%% =============================================================================

pn_length_boundaries_test() ->
    ?assertEqual(1, ?M:pn_length(0)),
    ?assertEqual(1, ?M:pn_length(255)),
    ?assertEqual(2, ?M:pn_length(256)),
    ?assertEqual(2, ?M:pn_length(65535)),
    ?assertEqual(3, ?M:pn_length(65536)),
    ?assertEqual(3, ?M:pn_length(16777215)),
    ?assertEqual(4, ?M:pn_length(16777216)).

pn_roundtrip_test() ->
    [
        begin
            Len = ?M:pn_length(PN),
            ?assertEqual(
                {PN, <<16#ff>>}, ?M:decode_pn(<<(?M:encode_pn(PN, Len))/binary, 16#ff>>, Len)
            )
        end
     || PN <- [0, 1, 255, 256, 65535, 65536, 16777215, 16777216, 4294967295]
    ].

%% =============================================================================
%% Malformed input: every short read is {error, truncated}, never a crash.
%% =============================================================================

decode_errors_test() ->
    DCIDLen = byte_size(?DCID),
    ?assertEqual({error, invalid_packet}, ?M:decode(<<>>, DCIDLen)),
    %% Long header truncated mid connection-id.
    ?assertEqual({error, invalid_cid_length}, ?M:decode(<<16#C0, ?V1:32, 8, 1, 2, 3>>, DCIDLen)),
    %% Long header with a connection id longer than 20 bytes.
    ?assertEqual({error, invalid_packet}, ?M:decode(<<16#C0, ?V1:32, 21, 0:168>>, DCIDLen)),
    %% Long header whose SCID bytes are truncated (length 5, only 2 present).
    ?assertEqual({error, truncated}, ?M:decode(<<16#C0, ?V1:32, 0, 5, 1, 2>>, DCIDLen)),
    %% Short header truncated before the DCID is complete.
    ?assertEqual({error, truncated}, ?M:decode(<<16#40, 1, 2>>, DCIDLen)),
    %% Short header with no room for the packet number.
    ?assertEqual({error, truncated}, ?M:decode(<<16#40, ?DCID/binary>>, DCIDLen)).

decode_version_negotiation_rejected_test() ->
    %% Version 0 marks a Version Negotiation packet; a server never gets one.
    VN = <<16#C0, 0:32, 0, 0>>,
    ?assertEqual({error, unexpected_version_negotiation}, ?M:decode(VN, 0)).

decode_retry_rejected_test() ->
    %% Type bits 11 = Retry, a client-only inbound packet.
    Retry = <<16#F0, ?V1:32, 0, 0>>,
    ?assertEqual({error, unexpected_retry}, ?M:decode(Retry, 0)).

decode_token_too_large_test() ->
    %% Initial whose token length varint claims more than the cap.
    Bin = <<16#C0, ?V1:32, 0, 0, (roadrunner_quic_varint:encode(1000))/binary, 0:8000>>,
    ?assertEqual({error, token_too_large}, ?M:decode(Bin, 0)).

decode_invalid_length_test() ->
    %% Handshake whose Length varint (0) is smaller than the packet-number
    %% length (>= 1), so the payload size is negative.
    Bin = <<16#E0, ?V1:32, 0, 0, (roadrunner_quic_varint:encode(0))/binary>>,
    ?assertEqual({error, invalid_length}, ?M:decode(Bin, 0)).

decode_truncated_token_and_length_test() ->
    %% Initial whose token length varint promises bytes that are not there.
    BadToken = <<16#C0, ?V1:32, 0, 0, (roadrunner_quic_varint:encode(5))/binary, 1, 2>>,
    ?assertEqual({error, truncated}, ?M:decode(BadToken, 0)),
    %% Initial that ends right after a zero-length token (no Length varint).
    NoLength = <<16#C0, ?V1:32, 0, 0, 0>>,
    ?assertEqual({error, truncated}, ?M:decode(NoLength, 0)),
    %% Length present but the packet-number/payload bytes are missing.
    ShortBody = <<16#C0, ?V1:32, 0, 0, 0, (roadrunner_quic_varint:encode(5))/binary>>,
    ?assertEqual({error, truncated}, ?M:decode(ShortBody, 0)).

dcid_errors_test() ->
    ?assertEqual({error, invalid_packet}, ?M:dcid(<<>>, 0)),
    %% Long header claiming a 21-byte (too long) connection id.
    ?assertEqual({error, invalid_packet}, ?M:dcid(<<16#C0, ?V1:32, 21, 0>>, 0)),
    %% Long header truncated before the DCID is complete.
    ?assertEqual({error, truncated}, ?M:dcid(<<16#C0, ?V1:32, 8, 1, 2>>, 0)),
    %% Short header truncated before the DCID is complete.
    ?assertEqual({error, truncated}, ?M:dcid(<<16#40, 1, 2>>, 8)).

pn_offset_errors_test() ->
    ?assertEqual({error, invalid_packet}, ?M:pn_offset(<<>>, 0)),
    %% Long header that ends inside the connection ids.
    ?assertEqual({error, truncated}, ?M:pn_offset(<<16#C0, ?V1:32, 8, 1, 2, 3>>, 0)),
    %% Long header missing its SCID-length byte.
    ?assertEqual({error, truncated}, ?M:pn_offset(<<16#C0, ?V1:32, 0>>, 0)),
    %% Long header whose SCID bytes are truncated (length 5, only 2 present).
    ?assertEqual({error, truncated}, ?M:pn_offset(<<16#C0, ?V1:32, 0, 5, 1, 2>>, 0)),
    %% Initial whose token length varint is truncated.
    ?assertEqual({error, truncated}, ?M:pn_offset(<<16#C0, ?V1:32, 0, 0, 16#40>>, 0)),
    %% Initial whose token bytes are truncated (length 3, only 2 present).
    ?assertEqual({error, truncated}, ?M:pn_offset(<<16#C0, ?V1:32, 0, 0, 3, 1, 2>>, 0)),
    %% Initial whose Length varint is missing.
    ?assertEqual({error, truncated}, ?M:pn_offset(<<16#C0, ?V1:32, 0, 0, 0>>, 0)).

long_header_info_test() ->
    DCID = <<1, 2, 3, 4, 5, 6, 7, 8>>,
    SCID = <<9, 9, 9, 9>>,
    Bin =
        <<16#C0, 16#FF000001:32, (byte_size(DCID)), DCID/binary, (byte_size(SCID)), SCID/binary,
            "payload">>,
    ?assertEqual(
        {ok, #{version => 16#FF000001, dcid => DCID, scid => SCID}},
        ?M:long_header_info(Bin)
    ).

%% Connection ids longer than the v1 20-byte limit are still parsed (the
%% invariant lengths are a full 8 bits), so an unsupported version carried with
%% a long connection id can still elicit Version Negotiation (RFC 9000 §17.2.1).
long_header_info_allows_oversized_cids_test() ->
    DCID = binary:copy(<<7>>, 30),
    SCID = binary:copy(<<8>>, 25),
    Bin = <<16#C0, 16#FF000001:32, (byte_size(DCID)), DCID/binary, (byte_size(SCID)), SCID/binary>>,
    ?assertEqual(
        {ok, #{version => 16#FF000001, dcid => DCID, scid => SCID}},
        ?M:long_header_info(Bin)
    ).

long_header_info_rejects_short_header_test() ->
    ?assertEqual({error, not_long_header}, ?M:long_header_info(<<16#40, 1, 2, 3>>)),
    ?assertEqual({error, not_long_header}, ?M:long_header_info(<<>>)).

long_header_info_truncated_test() ->
    %% Long header that ends inside the SCID (length 5, only 2 present).
    ?assertEqual({error, truncated}, ?M:long_header_info(<<16#C0, ?V1:32, 0, 5, 1, 2>>)),
    %% Long header missing its SCID length byte.
    ?assertEqual({error, truncated}, ?M:long_header_info(<<16#C0, ?V1:32, 2, 1, 2>>)).

%% =============================================================================
%% Version Negotiation packet: the first byte's unused bits are arbitrary,
%% so check the structure instead.
%% =============================================================================

version_negotiation_structure_test() ->
    Versions = [?V1, 16#FF000020],
    Bin = enc(?M:encode_version_negotiation(?DCID, ?SCID, Versions)),
    DCIDLen = byte_size(?DCID),
    SCIDLen = byte_size(?SCID),
    ?assertMatch(
        <<16#C0, 0:32, DCIDLen, _:DCIDLen/binary, SCIDLen, _:SCIDLen/binary, _/binary>>, Bin
    ),
    <<16#C0, 0:32, DCIDLen, D:DCIDLen/binary, SCIDLen, S:SCIDLen/binary, VBytes/binary>> = Bin,
    ?assertEqual(?DCID, D),
    ?assertEqual(?SCID, S),
    ?assertEqual([V || <<V:32>> <= VBytes], Versions).
