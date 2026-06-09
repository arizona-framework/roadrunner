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

%% =============================================================================
%% Send side.
%% =============================================================================

next_frame_single_slice_test() ->
    S = ?M:enqueue(<<"hello">>, ?M:new()),
    {Offset, Data, Fin, _} = ?M:next_frame(100, S),
    ?assertEqual({0, <<"hello">>, false}, {Offset, Data, Fin}).

next_frame_budget_split_test() ->
    S = ?M:enqueue(<<"abcdef">>, ?M:new()),
    {0, <<"abcd">>, false, S1} = ?M:next_frame(4, S),
    {4, <<"ef">>, false, _} = ?M:next_frame(4, S1).

enqueue_after_partial_send_test() ->
    %% A later enqueue appends in order to the unsent remainder, and the
    %% next slice starts at the advanced send offset.
    S0 = ?M:enqueue(<<"abcd">>, ?M:new()),
    {0, <<"ab">>, false, S1} = ?M:next_frame(2, S0),
    S2 = ?M:enqueue(<<"ef">>, S1),
    {2, <<"cdef">>, false, _} = ?M:next_frame(100, S2).

next_frame_nothing_when_empty_test() ->
    ?assertEqual(nothing, ?M:next_frame(100, ?M:new())).

next_frame_nothing_with_zero_budget_test() ->
    S = ?M:enqueue(<<"data">>, ?M:new()),
    ?assertEqual(nothing, ?M:next_frame(0, S)).

fin_rides_last_slice_test() ->
    S = ?M:finish(?M:enqueue(<<"abcdef">>, ?M:new())),
    %% A budget split: the FIN is deferred until the slice that drains the
    %% buffer.
    {0, <<"abcd">>, false, S1} = ?M:next_frame(4, S),
    {4, <<"ef">>, true, _} = ?M:next_frame(4, S1).

fin_only_frame_test() ->
    %% finish with no data: a single empty FIN frame, then nothing.
    S = ?M:finish(?M:new()),
    {0, <<>>, true, S1} = ?M:next_frame(100, S),
    ?assertEqual(nothing, ?M:next_frame(100, S1)).

fin_after_data_drains_test() ->
    %% Data sent without a FIN, then finish: the FIN follows as an empty
    %% frame at the post-data offset.
    S = ?M:enqueue(<<"body">>, ?M:new()),
    {0, <<"body">>, false, S1} = ?M:next_frame(100, S),
    S2 = ?M:finish(S1),
    {4, <<>>, true, _} = ?M:next_frame(100, S2).

next_frame_idempotent_after_fin_test() ->
    S = ?M:finish(?M:enqueue(<<"x">>, ?M:new())),
    {0, <<"x">>, true, S1} = ?M:next_frame(100, S),
    ?assertEqual(nothing, ?M:next_frame(100, S1)).

stop_sending_clears_buffer_test() ->
    S = ?M:finish(?M:enqueue(<<"unsent">>, ?M:new())),
    S1 = ?M:stop_sending(S),
    ?assertEqual(nothing, ?M:next_frame(100, S1)).

send_pending_test() ->
    ?assertNot(?M:send_pending(?M:new())),
    ?assert(?M:send_pending(?M:enqueue(<<"d">>, ?M:new()))),
    ?assert(?M:send_pending(?M:finish(?M:new()))),
    {_, _, _, Sent} = ?M:next_frame(100, ?M:finish(?M:enqueue(<<"d">>, ?M:new()))),
    ?assertNot(?M:send_pending(Sent)).

%% A stream is terminal only when the send FIN is on the wire AND the receive
%% side has reached its final size (FIN delivered or reset) — one side alone is
%% not enough.
is_terminal_test() ->
    ?assertNot(?M:is_terminal(?M:new())),
    {_, _, true, SendDone} = ?M:next_frame(100, ?M:finish(?M:enqueue(~"x", ?M:new()))),
    ?assertNot(?M:is_terminal(SendDone)),
    {ok, _, true, RecvDone} = ?M:receive_data(0, ~"y", true, ?M:new()),
    ?assertNot(?M:is_terminal(RecvDone)),
    {ok, _, true, BothDone} = ?M:receive_data(0, ~"y", true, SendDone),
    ?assert(?M:is_terminal(BothDone)),
    {ok, ResetDone} = ?M:reset(0, SendDone),
    ?assert(?M:is_terminal(ResetDone)).

%% A response enqueued + finished on a sender drains into small slices that
%% reassemble, in order, to the original bytes with the FIN on the receiver.
send_recv_round_trip_test() ->
    Payload = <<"a response body spanning several stream frames">>,
    Sender = ?M:finish(?M:enqueue(Payload, ?M:new())),
    Slices = drain_all(Sender, 7),
    {Delivered, FinReached} = feed(Slices, ?M:new(), <<>>, false),
    ?assertEqual(Payload, Delivered),
    ?assert(FinReached).

%% =============================================================================
%% Helpers
%% =============================================================================

drain_all(Stream, Budget) ->
    case ?M:next_frame(Budget, Stream) of
        nothing -> [];
        {Offset, Data, Fin, Stream1} -> [{Offset, Data, Fin} | drain_all(Stream1, Budget)]
    end.

feed([], _Stream, Acc, Fin) ->
    {Acc, Fin};
feed([{Offset, Data, FrameFin} | Rest], Stream, Acc, Fin) ->
    {ok, Bin, FinReached, Stream1} = ?M:receive_data(Offset, Data, FrameFin, Stream),
    feed(Rest, Stream1, <<Acc/binary, Bin/binary>>, Fin orelse FinReached).
