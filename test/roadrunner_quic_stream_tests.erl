-module(roadrunner_quic_stream_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_stream).

%% =============================================================================
%% In-order and out-of-order reassembly.
%% =============================================================================

in_order_delivery_test() ->
    {ok, D1, false, S1} = ?M:receive_data(0, <<"hello ">>, false, ?M:new()),
    {ok, D2, false, _} = ?M:receive_data(6, <<"world">>, false, S1),
    ?assertEqual(<<"hello ">>, D1),
    ?assertEqual(<<"world">>, D2).

out_of_order_gap_fill_test() ->
    %% The second piece arrives first (a gap), so nothing is delivered; the
    %% first piece fills the gap and both drain in order.
    {ok, D1, false, S1} = ?M:receive_data(6, <<"world">>, false, ?M:new()),
    ?assertEqual(<<>>, D1),
    {ok, D2, false, _} = ?M:receive_data(0, <<"hello ">>, false, S1),
    ?assertEqual(<<"hello world">>, D2).

multiple_gaps_test() ->
    %% Three out-of-order gapped pieces buffer, then the first fills and the
    %% whole prefix drains.
    {ok, <<>>, false, S1} = ?M:receive_data(2, <<"cc">>, false, ?M:new()),
    {ok, <<>>, false, S2} = ?M:receive_data(6, <<"gg">>, false, S1),
    {ok, <<>>, false, S3} = ?M:receive_data(4, <<"ee">>, false, S2),
    {ok, D, false, _} = ?M:receive_data(0, <<"aa">>, false, S3),
    ?assertEqual(<<"aacceegg">>, D).

%% =============================================================================
%% Duplicates and overlap.
%% =============================================================================

duplicate_dropped_test() ->
    {ok, <<"abc">>, false, S1} = ?M:receive_data(0, <<"abc">>, false, ?M:new()),
    %% A full retransmit of already-delivered data yields nothing new.
    {ok, D1, false, S2} = ?M:receive_data(0, <<"abc">>, false, S1),
    ?assertEqual(<<>>, D1),
    %% A frame overlapping the delivered prefix delivers only its new tail.
    {ok, D2, false, _} = ?M:receive_data(1, <<"bcde">>, false, S2),
    ?assertEqual(<<"de">>, D2).

buffered_overlap_test() ->
    %% A buffered gap piece, then a piece overlapping it on both sides;
    %% existing bytes are kept and the new before/after parts are added.
    {ok, <<>>, false, S1} = ?M:receive_data(6, <<"world">>, false, ?M:new()),
    {ok, <<>>, false, S2} = ?M:receive_data(3, <<"lo worldXX">>, false, S1),
    {ok, D, false, _} = ?M:receive_data(0, <<"hel">>, false, S2),
    ?assertEqual(<<"hello worldXX">>, D).

fully_covered_piece_dropped_test() ->
    %% A piece entirely inside a buffered segment adds nothing.
    {ok, <<>>, false, S1} = ?M:receive_data(6, <<"world">>, false, ?M:new()),
    {ok, <<>>, false, S2} = ?M:receive_data(7, <<"or">>, false, S1),
    {ok, D, false, _} = ?M:receive_data(0, <<"hello ">>, false, S2),
    ?assertEqual(<<"hello world">>, D).

multi_segment_span_test() ->
    %% A piece that overlaps one buffered segment, fills the gap after it,
    %% and overlaps a second buffered segment (the after_segment recursion
    %% into a non-empty rest). Stream bytes: "01ccEEgg".
    {ok, <<>>, false, S1} = ?M:receive_data(2, <<"cc">>, false, ?M:new()),
    {ok, <<>>, false, S2} = ?M:receive_data(6, <<"gg">>, false, S1),
    {ok, <<>>, false, S3} = ?M:receive_data(1, <<"1ccEEgg">>, false, S2),
    {ok, D, false, _} = ?M:receive_data(0, <<"0">>, false, S3),
    ?assertEqual(<<"01ccEEgg">>, D).

%% =============================================================================
%% FIN / end-of-stream.
%% =============================================================================

fin_with_data_test() ->
    {ok, D, FinReached, _} = ?M:receive_data(0, <<"final">>, true, ?M:new()),
    ?assertEqual(<<"final">>, D),
    ?assert(FinReached).

fin_only_delivery_test() ->
    %% A stream that ends with no further data: an empty FIN frame at the
    %% read cursor delivers {<<>>, true}.
    {ok, <<"data">>, false, S1} = ?M:receive_data(0, <<"data">>, false, ?M:new()),
    {ok, D, FinReached, _} = ?M:receive_data(4, <<>>, true, S1),
    ?assertEqual(<<>>, D),
    ?assert(FinReached).

fin_rides_gap_fill_test() ->
    %% The FIN arrives out of order and buffers; the gap-filling non-FIN
    %% frame delivers everything and the FIN together.
    {ok, <<>>, false, S1} = ?M:receive_data(5, <<"!!">>, true, ?M:new()),
    {ok, D, FinReached, _} = ?M:receive_data(0, <<"hello">>, false, S1),
    ?assertEqual(<<"hello!!">>, D),
    ?assert(FinReached).

fin_with_buffered_gaps_test() ->
    %% A FIN whose final size is validated against buffered (not yet
    %% delivered) data.
    {ok, <<>>, false, S1} = ?M:receive_data(3, <<"de">>, false, ?M:new()),
    {ok, <<>>, false, S2} = ?M:receive_data(5, <<>>, true, S1),
    {ok, D, FinReached, _} = ?M:receive_data(0, <<"abc">>, false, S2),
    ?assertEqual(<<"abcde">>, D),
    ?assert(FinReached).

duplicate_fin_not_redelivered_test() ->
    {ok, <<"x">>, true, S1} = ?M:receive_data(0, <<"x">>, true, ?M:new()),
    %% A retransmit of the final frame must not deliver the FIN again.
    {ok, D, FinReached, _} = ?M:receive_data(0, <<"x">>, true, S1),
    ?assertEqual(<<>>, D),
    ?assertNot(FinReached).

%% =============================================================================
%% Final-size errors (RFC 9000 §4.5).
%% =============================================================================

data_beyond_final_size_test() ->
    {ok, _, true, S1} = ?M:receive_data(0, <<"abc">>, true, ?M:new()),
    ?assertEqual({error, final_size_error}, ?M:receive_data(3, <<"d">>, false, S1)).

conflicting_final_size_test() ->
    {ok, _, false, S1} = ?M:receive_data(0, <<"ab">>, false, ?M:new()),
    {ok, <<>>, false, S2} = ?M:receive_data(5, <<"f">>, true, S1),
    ?assertEqual({error, final_size_error}, ?M:receive_data(2, <<"cd">>, true, S2)).

final_size_below_received_test() ->
    {ok, _, false, S1} = ?M:receive_data(0, <<"abcde">>, false, ?M:new()),
    ?assertEqual({error, final_size_error}, ?M:receive_data(3, <<>>, true, S1)).

%% =============================================================================
%% RESET_STREAM.
%% =============================================================================

reset_accepts_consistent_final_size_test() ->
    {ok, _, false, S1} = ?M:receive_data(0, <<"abc">>, false, ?M:new()),
    ?assertMatch({ok, _}, ?M:reset(3, S1)),
    ?assertMatch({ok, _}, ?M:reset(10, S1)).

reset_conflicting_final_size_test() ->
    {ok, _, true, S1} = ?M:receive_data(0, <<"abc">>, true, ?M:new()),
    ?assertEqual({error, final_size_error}, ?M:reset(5, S1)).

reset_final_size_below_received_test() ->
    {ok, _, false, S1} = ?M:receive_data(0, <<"abcde">>, false, ?M:new()),
    ?assertEqual({error, final_size_error}, ?M:reset(3, S1)).

reset_final_size_below_buffered_test() ->
    %% A buffered (not yet delivered) gap counts as received data, so a
    %% reset final size below it is rejected.
    {ok, <<>>, false, S1} = ?M:receive_data(3, <<"de">>, false, ?M:new()),
    ?assertEqual({error, final_size_error}, ?M:reset(4, S1)).

reset_aborts_receive_test() ->
    %% After a RESET_STREAM the receive side is terminal: buffered data is
    %% discarded and a later STREAM frame delivers nothing.
    {ok, <<>>, false, S1} = ?M:receive_data(2, <<"cc">>, false, ?M:new()),
    {ok, S2} = ?M:reset(4, S1),
    {ok, D, FinReached, _} = ?M:receive_data(0, <<"ab">>, false, S2),
    ?assertEqual(<<>>, D),
    ?assertNot(FinReached).
