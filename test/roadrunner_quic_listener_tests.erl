-module(roadrunner_quic_listener_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_listener).
-define(REG, roadrunner_quic_cid_registry).
-define(QUIC_V1, 16#00000001).
%% A version this server does not support (not v1, not the version-0 marker).
-define(UNSUPPORTED, 16#FF000001).
-define(DCID, <<1, 2, 3, 4, 5, 6, 7, 8>>).
-define(SCID, <<5, 5, 5, 5>>).

%% The routing decision is pure given the registry, so its branches are
%% covered here with crafted headers; the side-effecting spawn, the Version
%% Negotiation send, and the process loop live in roadrunner_quic_listener_SUITE.

classify_forwards_to_registered_connection_test() ->
    Registry = ?REG:new(),
    ok = ?REG:register_pair(Registry, ?DCID, <<9, 9, 9, 9, 9, 9, 9, 9>>, self()),
    ?assertEqual({forward, self()}, ?M:classify(v1_initial(?DCID), Registry)).

%% A short-header (1-RTT) packet routes to its connection by the fixed-length
%% destination id, the demux the established-connection hot path relies on.
classify_forwards_short_header_to_registered_connection_test() ->
    Registry = ?REG:new(),
    ok = ?REG:register_pair(Registry, ?DCID, <<9, 9, 9, 9, 9, 9, 9, 9>>, self()),
    ?assertEqual({forward, self()}, ?M:classify(short_header(?DCID), Registry)).

%% A v1 Initial to an unknown id spawns, capturing both the routing destination
%% id and the client's source id (the latter is what the server's replies are
%% addressed to, RFC 9000 §7.2): the two are distinct.
classify_spawns_for_v1_initial_to_unknown_cid_test() ->
    ?assertEqual({spawn, ?DCID, ?SCID}, ?M:classify(v1_initial_min(?DCID), ?REG:new())).

classify_drops_malformed_datagram_test() ->
    ?assertEqual(drop, ?M:classify(<<>>, ?REG:new())).

classify_drops_short_header_to_unknown_cid_test() ->
    ?assertEqual(drop, ?M:classify(short_header(?DCID), ?REG:new())).

%% A short-header packet at the floor to an unknown id is dropped through the
%% long-header check (a short header never negotiates a version), distinct from
%% the sub-floor drop above.
classify_drops_large_short_header_to_unknown_cid_test() ->
    ?assertEqual(drop, ?M:classify(pad(short_header(?DCID)), ?REG:new())).

%% RFC 9000 §5.2.2: a server MUST drop an unsupported-version packet below the
%% 1200-byte floor rather than answer it with Version Negotiation.
classify_drops_small_unsupported_version_test() ->
    ?assertEqual(drop, ?M:classify(unsupported_version(?DCID, ?SCID), ?REG:new())).

%% RFC 9000 §14.1: a v1 Initial below the 1200-byte datagram floor is discarded,
%% so it never spawns even though its header is a well-formed v1 Initial.
classify_drops_small_v1_initial_to_unknown_cid_test() ->
    ?assertEqual(drop, ?M:classify(v1_initial(?DCID), ?REG:new())).

%% Only a long-header *Initial* (type 00) spawns; a v1 long header of another
%% type (here Handshake, type 10) to an unknown id is dropped even at the floor
%% (a supported version is never answered with Version Negotiation).
classify_drops_v1_handshake_to_unknown_cid_test() ->
    ?assertEqual(drop, ?M:classify(pad(v1_handshake(?DCID)), ?REG:new())).

%% RFC 9000 §5.2.2/§17.2.1: an unsupported-version long header at the floor is
%% answered with Version Negotiation, reporting the client's ids (the caller
%% swaps them onto the wire).
classify_triggers_version_negotiation_for_unsupported_version_test() ->
    SCID = <<7, 7, 7>>,
    ?assertEqual(
        {version_negotiation, ?DCID, SCID},
        ?M:classify(pad(unsupported_version(?DCID, SCID)), ?REG:new())
    ).

%% RFC 9000 §6.1: a received Version Negotiation packet (version 0) MUST NOT be
%% answered with another Version Negotiation packet.
classify_does_not_answer_a_version_negotiation_test() ->
    ?assertEqual(drop, ?M:classify(pad(long_header(16#C0, 0, ?DCID, ?SCID)), ?REG:new())).

%% RFC 9000 §17.2.1: connection-id length MUST NOT gate the Version Negotiation
%% decision, so an unsupported version carried with an id longer than v1 allows
%% (which dcid/2 cannot read) is still answered.
classify_version_negotiation_ignores_connection_id_length_test() ->
    BigDCID = binary:copy(<<3>>, 30),
    SCID = <<7, 7, 7>>,
    ?assertEqual(
        {version_negotiation, BigDCID, SCID},
        ?M:classify(pad(unsupported_version(BigDCID, SCID)), ?REG:new())
    ).

%% A well-formed long header (first byte, version, DCID, SCID); body-less, so
%% below the §14.1 floor until padded.
long_header(FirstByte, Version, DCID, SCID) ->
    <<FirstByte, Version:32, (byte_size(DCID)), DCID/binary, (byte_size(SCID)), SCID/binary>>.

%% A v1 Initial (first byte 0xC0 = long+fixed+type 00), below the floor.
v1_initial(DCID) ->
    long_header(16#C0, ?QUIC_V1, DCID, ?SCID).

%% The same Initial padded to the §14.1 floor, so it is spawn-eligible.
v1_initial_min(DCID) ->
    pad(v1_initial(DCID)).

%% A v1 long header of type 10 (Handshake): first byte 0xE0 = long+fixed+type 10.
v1_handshake(DCID) ->
    long_header(16#E0, ?QUIC_V1, DCID, ?SCID).

%% An unsupported-version long header, below the floor until padded.
unsupported_version(DCID, SCID) ->
    long_header(16#C0, ?UNSUPPORTED, DCID, SCID).

%% A short-header (1-RTT) packet (first byte 0x40 = short+fixed); its DCID is
%% the fixed server SCID length (8 bytes).
short_header(DCID) ->
    <<16#40, DCID/binary, 0>>.

%% Pad a datagram up to the RFC 9000 §14.1 1200-byte floor.
pad(Datagram) ->
    <<Datagram/binary, 0:((1200 - byte_size(Datagram)) * 8)>>.
