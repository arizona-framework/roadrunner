-module(roadrunner_quic_stream).
-moduledoc false.

%% QUIC stream receive-side reassembly (RFC 9000 §2.2/§4.5), pure.
%%
%% A per-stream state that turns out-of-order, overlapping, and
%% retransmitted STREAM frame pieces into the in-order byte stream the
%% application reads. The connection loop holds one of these per stream id
%% (the peer of `roadrunner_quic_flow`, which it also holds per stream),
%% feeds each received STREAM frame in with `receive_data/4`, and turns the
%% result into a `{stream_data, StreamId, Bytes, Fin}` event, including the
%% FIN-only `{<<>>, true}` case the HTTP/3 layer dispatches a request on.
%% A RESET_STREAM aborts the receive side via `reset/2`.
%%
%% Pure and stateless about windows: flow control (the receive-window
%% limit and MAX_STREAM_DATA grants) stays in the loop's
%% `roadrunner_quic_flow`, which already returns `flow_control_error`. This
%% module owns only ordering and the RFC 9000 §4.5 final-size rules, so it
%% returns `final_size_error` and nothing else. The outbound send buffer is
%% a separate concern, added in a follow-up.
%%
%% Buffered out-of-order data is kept as a sorted, non-overlapping list of
%% `{Offset, Bytes}` segments (overlaps are trimmed on insert, since the
%% bytes at an offset never change), so the contiguous prefix drains
%% cleanly from the read cursor.

-export([new/0, receive_data/4, reset/2]).

-export_type([t/0]).

-record(stream, {
    %% Next byte to deliver: the length of the contiguous prefix already
    %% handed to the application.
    offset = 0 :: non_neg_integer(),
    %% Buffered gaps: sorted ascending, non-overlapping, every offset
    %% strictly above `offset`.
    segments = [] :: [{non_neg_integer(), binary()}],
    %% The stream's final size once a FIN (or RESET_STREAM) sets it.
    final_size = undefined :: non_neg_integer() | undefined,
    %% Whether the FIN has already been delivered (so a retransmit does
    %% not deliver it twice).
    fin_delivered = false :: boolean(),
    %% Set by a RESET_STREAM: the receive side is aborted, so later STREAM
    %% frames deliver nothing (RFC 9000 §3.2).
    aborted = false :: boolean()
}).

-opaque t() :: #stream{}.

-doc "A fresh receive stream, read cursor at offset 0.".
-spec new() -> t().
new() ->
    #stream{}.

-doc """
Take a received STREAM frame piece (`Offset`, `Data`, end-of-stream `Fin`)
and return the bytes that are now contiguous from the read cursor and
whether the stream's end has been reached.

`Deliverable` is the newly contiguous bytes (empty when the frame only
filled a gap above the cursor, or was a pure duplicate). `FinReached` is
true exactly once, when the contiguous data first reaches the final size;
combined with an empty `Deliverable` that is the FIN-only end-of-stream.
Returns `{error, final_size_error}` on an RFC 9000 §4.5 violation (data
past the final size, a conflicting final size, or a final size below
already-received data).
""".
-spec receive_data(non_neg_integer(), binary(), boolean(), t()) ->
    {ok, binary(), boolean(), t()} | {error, final_size_error}.
receive_data(_Offset, _Data, _Fin, #stream{aborted = true} = Stream) ->
    %% RESET_STREAM aborted the receive side; ignore any late data.
    {ok, <<>>, false, Stream};
receive_data(Offset, Data, Fin, #stream{offset = Cursor} = Stream) ->
    End = Offset + byte_size(Data),
    case final_size(End, Fin, Stream) of
        {error, _} = Error ->
            Error;
        {ok, FinalSize} ->
            {KeepOffset, KeepData} = trim(Offset, Data, Cursor),
            Segments = insert_segment(KeepOffset, KeepData, Stream#stream.segments),
            {Deliverable, NewCursor, Rest} = drain(Cursor, Segments),
            FinReached = FinalSize =/= undefined andalso NewCursor >= FinalSize,
            DeliverFin = FinReached andalso not Stream#stream.fin_delivered,
            {ok, Deliverable, DeliverFin, Stream#stream{
                offset = NewCursor,
                segments = Rest,
                final_size = FinalSize,
                fin_delivered = FinReached
            }}
    end.

-doc """
Abort the receive side on a RESET_STREAM, validating its final size
against what was already received (RFC 9000 §4.5). On success the receive
side is terminal: buffered data is discarded and later STREAM frames
deliver nothing (RFC 9000 §3.2). Returns `{error, final_size_error}` on a
conflicting or too-small final size.
""".
-spec reset(non_neg_integer(), t()) -> {ok, t()} | {error, final_size_error}.
reset(FinalSize, #stream{final_size = Existing} = Stream) ->
    case
        (Existing =/= undefined andalso FinalSize =/= Existing) orelse
            FinalSize < highest_received(Stream)
    of
        true -> {error, final_size_error};
        false -> {ok, Stream#stream{final_size = FinalSize, segments = [], aborted = true}}
    end.

%% =============================================================================
%% Internal
%% =============================================================================

%% Validate the frame's end offset against the final size and, on a FIN,
%% establish it (RFC 9000 §4.5).
-spec final_size(non_neg_integer(), boolean(), t()) ->
    {ok, non_neg_integer() | undefined} | {error, final_size_error}.
final_size(End, Fin, #stream{final_size = Final} = Stream) ->
    case Final of
        %% A FIN sets the final size, but it cannot fall below data already
        %% received.
        undefined when Fin ->
            case End < highest_received(Stream) of
                true -> {error, final_size_error};
                false -> {ok, End}
            end;
        undefined ->
            {ok, undefined};
        %% Data may not extend past an established final size.
        _ when End > Final ->
            {error, final_size_error};
        %% A FIN may not contradict an established final size.
        _ when Fin andalso End =/= Final ->
            {error, final_size_error};
        _ ->
            {ok, Final}
    end.

%% The offset one past the highest byte received so far (delivered or
%% buffered).
-spec highest_received(t()) -> non_neg_integer().
highest_received(#stream{offset = Cursor, segments = []}) ->
    Cursor;
highest_received(#stream{segments = Segments}) ->
    {Offset, Data} = lists:last(Segments),
    Offset + byte_size(Data).

%% Drop the part of a piece that the read cursor has already delivered.
-spec trim(non_neg_integer(), binary(), non_neg_integer()) -> {non_neg_integer(), binary()}.
trim(Offset, Data, Cursor) when Offset >= Cursor ->
    {Offset, Data};
trim(Offset, Data, Cursor) ->
    Drop = Cursor - Offset,
    case Data of
        <<_:Drop/binary, Tail/binary>> -> {Cursor, Tail};
        _ -> {Cursor, <<>>}
    end.

%% Insert a piece into the sorted, non-overlapping segment list, keeping
%% existing bytes where they overlap (the wire guarantees the bytes at an
%% offset are identical, RFC 9000 §2.2). An empty piece is a no-op.
-spec insert_segment(non_neg_integer(), binary(), [{non_neg_integer(), binary()}]) ->
    [{non_neg_integer(), binary()}].
insert_segment(_Offset, <<>>, Segments) ->
    Segments;
insert_segment(Offset, Data, []) ->
    [{Offset, Data}];
insert_segment(Offset, Data, [{SegOffset, SegData} = Segment | Rest]) ->
    End = Offset + byte_size(Data),
    SegEnd = SegOffset + byte_size(SegData),
    if
        End =< SegOffset ->
            [{Offset, Data}, Segment | Rest];
        Offset >= SegEnd ->
            [Segment | insert_segment(Offset, Data, Rest)];
        true ->
            before_segment(Offset, Data, SegOffset) ++
                [Segment | after_segment(Offset, Data, End, SegEnd, Rest)]
    end.

%% The part of an overlapping piece that falls before the segment it hit.
-spec before_segment(non_neg_integer(), binary(), non_neg_integer()) ->
    [{non_neg_integer(), binary()}].
before_segment(Offset, Data, SegOffset) when Offset < SegOffset ->
    [{Offset, binary:part(Data, 0, SegOffset - Offset)}];
before_segment(_Offset, _Data, _SegOffset) ->
    [].

%% The part of an overlapping piece that falls after the segment it hit,
%% re-inserted against the remaining segments.
-spec after_segment(
    non_neg_integer(), binary(), non_neg_integer(), non_neg_integer(), [
        {non_neg_integer(), binary()}
    ]
) -> [{non_neg_integer(), binary()}].
after_segment(Offset, Data, End, SegEnd, Rest) when End > SegEnd ->
    insert_segment(SegEnd, binary:part(Data, SegEnd - Offset, End - SegEnd), Rest);
after_segment(_Offset, _Data, _End, _SegEnd, Rest) ->
    Rest.

%% Pop the contiguous prefix starting at the cursor, advancing through
%% adjacent segments; body recursion, consing the bytes on the way out.
-spec drain(non_neg_integer(), [{non_neg_integer(), binary()}]) ->
    {binary(), non_neg_integer(), [{non_neg_integer(), binary()}]}.
drain(Cursor, [{Cursor, Data} | Rest]) ->
    {More, NewCursor, Remaining} = drain(Cursor + byte_size(Data), Rest),
    {<<Data/binary, More/binary>>, NewCursor, Remaining};
drain(Cursor, Segments) ->
    {<<>>, Cursor, Segments}.
