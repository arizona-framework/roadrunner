-module(roadrunner_quic_listener_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_listener).
-define(REG, roadrunner_quic_cid_registry).
-define(QUIC_V1, 16#00000001).

%% The routing decision is pure given the registry, so its branches are
%% covered here with crafted headers; the side-effecting spawn + the process
%% loop live in roadrunner_quic_listener_SUITE.

classify_forwards_to_registered_connection_test() ->
    Registry = ?REG:new(),
    DCID = <<1, 2, 3, 4, 5, 6, 7, 8>>,
    ok = ?REG:register_pair(Registry, DCID, <<9, 9, 9, 9, 9, 9, 9, 9>>, self()),
    ?assertEqual({forward, self()}, ?M:classify(v1_initial(DCID), Registry)).

classify_spawns_for_v1_initial_to_unknown_cid_test() ->
    DCID = <<1, 2, 3, 4, 5, 6, 7, 8>>,
    ?assertEqual({spawn, DCID}, ?M:classify(v1_initial_min(DCID), ?REG:new())).

classify_drops_malformed_datagram_test() ->
    ?assertEqual(drop, ?M:classify(<<>>, ?REG:new())).

classify_drops_short_header_to_unknown_cid_test() ->
    DCID = <<1, 2, 3, 4, 5, 6, 7, 8>>,
    ?assertEqual(drop, ?M:classify(short_header(DCID), ?REG:new())).

classify_drops_unknown_version_initial_test() ->
    DCID = <<1, 2, 3, 4, 5, 6, 7, 8>>,
    ?assertEqual(drop, ?M:classify(unknown_version_initial(DCID), ?REG:new())).

%% RFC 9000 §14.1: a v1 Initial below the 1200-byte datagram floor is discarded,
%% so it never spawns even though its header is a well-formed v1 Initial.
classify_drops_small_v1_initial_to_unknown_cid_test() ->
    DCID = <<1, 2, 3, 4, 5, 6, 7, 8>>,
    ?assertEqual(drop, ?M:classify(v1_initial(DCID), ?REG:new())).

%% Only a long-header *Initial* (type 00) spawns; a v1 long-header of another
%% type (here Handshake, type 10) to an unknown id is dropped even at the floor.
classify_drops_v1_handshake_to_unknown_cid_test() ->
    DCID = <<1, 2, 3, 4, 5, 6, 7, 8>>,
    ?assertEqual(drop, ?M:classify(pad(v1_handshake(DCID)), ?REG:new())).

%% A long-header Initial (first byte 0xC0 = long+fixed+type 00) for QUIC v1,
%% carrying the DCID; enough bytes for dcid/2 + the version check, but below the
%% §14.1 1200-byte floor.
v1_initial(DCID) ->
    <<16#C0, ?QUIC_V1:32, (byte_size(DCID)), DCID/binary>>.

%% The same Initial padded to the §14.1 floor, so it is spawn-eligible.
v1_initial_min(DCID) ->
    pad(v1_initial(DCID)).

%% A v1 long header with packet type 10 (Handshake): first byte 0xE0 =
%% long+fixed+type 10.
v1_handshake(DCID) ->
    <<16#E0, ?QUIC_V1:32, (byte_size(DCID)), DCID/binary>>.

unknown_version_initial(DCID) ->
    <<16#C0, 16#FF000001:32, (byte_size(DCID)), DCID/binary>>.

%% A short-header (1-RTT) packet (first byte 0x40 = short+fixed); its DCID is
%% the fixed server SCID length (8 bytes).
short_header(DCID) ->
    <<16#40, DCID/binary, 0>>.

%% Pad a datagram up to the RFC 9000 §14.1 1200-byte floor.
pad(Datagram) ->
    <<Datagram/binary, 0:((1200 - byte_size(Datagram)) * 8)>>.
