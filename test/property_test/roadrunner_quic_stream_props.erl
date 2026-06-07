-module(roadrunner_quic_stream_props).
-moduledoc """
Property-based test for `roadrunner_quic_stream` receive reassembly.

Invariant: however a byte stream is fragmented into STREAM frame pieces,
reordered, and partly retransmitted, feeding the pieces through
`receive_data/4` reassembles exactly the original bytes and reports the
stream's end. The fragmentation, duplication, and shuffle are derived
deterministically from a generated seed (a pure function, easier to trust
than nested generators), so the property varies them across runs.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

prop_reassembles_in_any_order() ->
    ?FORALL(
        {Bytes, Seed},
        {non_empty(binary()), integer(1, 1_000_000)},
        begin
            Frames = fragment(Bytes, Seed),
            {Delivered, FinReached} = reassemble(Frames),
            Delivered =:= Bytes andalso FinReached
        end
    ).

%% Feed every frame through receive_data/4, concatenating what is delivered
%% and noting whether the FIN was reached.
reassemble(Frames) ->
    {_Stream, Delivered, FinReached} = lists:foldl(
        fun({Offset, Data, Fin}, {Stream, Acc, Seen}) ->
            {ok, Bin, Reached, Stream1} = roadrunner_quic_stream:receive_data(
                Offset, Data, Fin, Stream
            ),
            {Stream1, <<Acc/binary, Bin/binary>>, Seen orelse Reached}
        end,
        {roadrunner_quic_stream:new(), <<>>, false},
        Frames
    ),
    {Delivered, FinReached}.

%% Fragment Bytes on two independent grids and shuffle the union. Two
%% different cut grids over the same bytes guarantee partially overlapping
%% and multi-segment-spanning pieces (the reassembler's core paths), while
%% drawing both from the same bytes keeps overlapping bytes identical
%% (RFC 9000 §2.2). A piece is a FIN iff it ends at the final size.
fragment(Bytes, Seed) ->
    Final = byte_size(Bytes),
    Pieces = pieces(Bytes, 0, Seed) ++ pieces(Bytes, 0, Seed bxor 16#5555),
    shuffle([{Offset, Data, Offset + byte_size(Data) =:= Final} || {Offset, Data} <- Pieces], Seed).

pieces(<<>>, _Offset, _Seed) ->
    [];
pieces(Bin, Offset, Seed) ->
    Take = min(1 + (erlang:phash2({Seed, Offset}) rem 4), byte_size(Bin)),
    <<Chunk:Take/binary, Rest/binary>> = Bin,
    [{Offset, Chunk} | pieces(Rest, Offset + Take, Seed)].

shuffle(Frames, Seed) ->
    [Frame || {_Key, Frame} <- lists:sort([{erlang:phash2({Seed, F}), F} || F <- Frames])].
