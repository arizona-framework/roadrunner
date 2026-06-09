-module(roadrunner_quic_frame).
-moduledoc false.

%% QUIC transport frame codec (RFC 9000 §19), pure wire syntax.
%%
%% Covers the core frame set a server-only v1 endpoint sends and receives;
%% the 0-RTT/datagram/reliable-reset extension frames are out of scope.
%% `encode/1` returns iodata (CRYPTO and STREAM keep their payload by
%% reference, never copied); `decode/1` reads one frame and never crashes
%% on a malformed packet (a short read is `{error, truncated}`);
%% `decode_all/1` reads a whole packet payload into a frame list.
%%
%% The ACK frame holds the raw wire fields (Largest Acknowledged, ACK
%% Delay, First ACK Range, the Gap/Range pairs, and ECN counts); turning
%% those into acknowledged packet-number ranges is `roadrunner_quic_ack`'s
%% job (RFC 9000 §19.3).

-export([encode/1, decode/1, decode_all/1]).

-export_type([frame/0, ecn_counts/0]).

%% RFC 9000 §19 frame types.
-define(PADDING, 16#00).
-define(PING, 16#01).
-define(ACK, 16#02).
-define(ACK_ECN, 16#03).
-define(RESET_STREAM, 16#04).
-define(STOP_SENDING, 16#05).
-define(CRYPTO, 16#06).
-define(NEW_TOKEN, 16#07).
%% STREAM is 0x08-0x0f: 0x08 with the low 3 bits as the FIN/LEN/OFF flags.
-define(STREAM, 16#08).
-define(STREAM_MAX, 16#0F).
-define(STREAM_FIN, 16#01).
-define(STREAM_LEN, 16#02).
-define(STREAM_OFF, 16#04).
-define(MAX_DATA, 16#10).
-define(MAX_STREAM_DATA, 16#11).
-define(MAX_STREAMS_BIDI, 16#12).
-define(MAX_STREAMS_UNI, 16#13).
-define(DATA_BLOCKED, 16#14).
-define(STREAM_DATA_BLOCKED, 16#15).
-define(STREAMS_BLOCKED_BIDI, 16#16).
-define(STREAMS_BLOCKED_UNI, 16#17).
-define(NEW_CONNECTION_ID, 16#18).
-define(RETIRE_CONNECTION_ID, 16#19).
-define(PATH_CHALLENGE, 16#1A).
-define(PATH_RESPONSE, 16#1B).
-define(CONNECTION_CLOSE, 16#1C).
-define(CONNECTION_CLOSE_APP, 16#1D).
-define(HANDSHAKE_DONE, 16#1E).

-type stream_id() :: non_neg_integer().
-type ecn_counts() :: {
    ECT0 :: non_neg_integer(), ECT1 :: non_neg_integer(), CE :: non_neg_integer()
}.

-type frame() ::
    padding
    | ping
    | handshake_done
    | {ack, Largest :: non_neg_integer(), AckDelay :: non_neg_integer(),
        FirstRange :: non_neg_integer(), Ranges :: [{non_neg_integer(), non_neg_integer()}],
        Ecn :: ecn_counts() | undefined}
    | {reset_stream, stream_id(), ErrorCode :: non_neg_integer(), FinalSize :: non_neg_integer()}
    | {stop_sending, stream_id(), ErrorCode :: non_neg_integer()}
    | {crypto, Offset :: non_neg_integer(), Data :: binary()}
    | {new_token, Token :: binary()}
    | {stream, stream_id(), Offset :: non_neg_integer(), Data :: binary(), Fin :: boolean()}
    | {max_data, non_neg_integer()}
    | {max_stream_data, stream_id(), non_neg_integer()}
    | {max_streams, bidi | uni, non_neg_integer()}
    | {data_blocked, non_neg_integer()}
    | {stream_data_blocked, stream_id(), non_neg_integer()}
    | {streams_blocked, bidi | uni, non_neg_integer()}
    | {new_connection_id, Seq :: non_neg_integer(), RetirePrior :: non_neg_integer(),
        CID :: binary(), StatelessResetToken :: binary()}
    | {retire_connection_id, Seq :: non_neg_integer()}
    | {path_challenge, binary()}
    | {path_response, binary()}
    | {connection_close, transport | application, ErrorCode :: non_neg_integer(),
        FrameType :: non_neg_integer() | undefined, Reason :: binary()}.

%% =============================================================================
%% encode/1
%% =============================================================================

-doc "Encode one frame to iodata (CRYPTO and STREAM keep their payload by reference).".
-spec encode(frame()) -> iodata().
encode(padding) ->
    <<?PADDING>>;
encode(ping) ->
    <<?PING>>;
encode(handshake_done) ->
    <<?HANDSHAKE_DONE>>;
encode({ack, Largest, AckDelay, FirstRange, Ranges, Ecn}) ->
    encode_ack(Largest, AckDelay, FirstRange, Ranges, Ecn);
encode({reset_stream, StreamId, ErrorCode, FinalSize}) ->
    <<?RESET_STREAM, (vint(StreamId))/binary, (vint(ErrorCode))/binary, (vint(FinalSize))/binary>>;
encode({stop_sending, StreamId, ErrorCode}) ->
    <<?STOP_SENDING, (vint(StreamId))/binary, (vint(ErrorCode))/binary>>;
encode({crypto, Offset, Data}) ->
    [<<?CRYPTO, (vint(Offset))/binary, (vint(byte_size(Data)))/binary>>, Data];
encode({new_token, Token}) ->
    [<<?NEW_TOKEN, (vint(byte_size(Token)))/binary>>, Token];
encode({stream, StreamId, Offset, Data, Fin}) ->
    [stream_header(StreamId, Offset, byte_size(Data), Fin), Data];
encode({max_data, Max}) ->
    <<?MAX_DATA, (vint(Max))/binary>>;
encode({max_stream_data, StreamId, Max}) ->
    <<?MAX_STREAM_DATA, (vint(StreamId))/binary, (vint(Max))/binary>>;
encode({max_streams, bidi, Max}) ->
    <<?MAX_STREAMS_BIDI, (vint(Max))/binary>>;
encode({max_streams, uni, Max}) ->
    <<?MAX_STREAMS_UNI, (vint(Max))/binary>>;
encode({data_blocked, Limit}) ->
    <<?DATA_BLOCKED, (vint(Limit))/binary>>;
encode({stream_data_blocked, StreamId, Limit}) ->
    <<?STREAM_DATA_BLOCKED, (vint(StreamId))/binary, (vint(Limit))/binary>>;
encode({streams_blocked, bidi, Limit}) ->
    <<?STREAMS_BLOCKED_BIDI, (vint(Limit))/binary>>;
encode({streams_blocked, uni, Limit}) ->
    <<?STREAMS_BLOCKED_UNI, (vint(Limit))/binary>>;
encode({new_connection_id, Seq, RetirePrior, CID, Token}) when byte_size(Token) =:= 16 ->
    <<?NEW_CONNECTION_ID, (vint(Seq))/binary, (vint(RetirePrior))/binary, (byte_size(CID)):8,
        CID/binary, Token/binary>>;
encode({retire_connection_id, Seq}) ->
    <<?RETIRE_CONNECTION_ID, (vint(Seq))/binary>>;
encode({path_challenge, Data}) when byte_size(Data) =:= 8 ->
    <<?PATH_CHALLENGE, Data/binary>>;
encode({path_response, Data}) when byte_size(Data) =:= 8 ->
    <<?PATH_RESPONSE, Data/binary>>;
encode({connection_close, transport, ErrorCode, FrameType, Reason}) ->
    [
        <<?CONNECTION_CLOSE, (vint(ErrorCode))/binary, (vint(FrameType))/binary,
            (vint(byte_size(Reason)))/binary>>,
        Reason
    ];
encode({connection_close, application, ErrorCode, _FrameType, Reason}) ->
    [
        <<?CONNECTION_CLOSE_APP, (vint(ErrorCode))/binary, (vint(byte_size(Reason)))/binary>>,
        Reason
    ].

%% STREAM frame header (everything before the data): the type's low 3 bits
%% carry OFF/LEN/FIN. LEN is always set, so the frame is self-delimiting
%% even when coalesced with later frames (RFC 9000 §19.8).
-spec stream_header(stream_id(), non_neg_integer(), non_neg_integer(), boolean()) -> binary().
stream_header(StreamId, Offset, Length, Fin) ->
    Type = ?STREAM bor offset_flag(Offset) bor ?STREAM_LEN bor fin_flag(Fin),
    OffsetBin =
        case Offset of
            0 -> <<>>;
            _ -> vint(Offset)
        end,
    <<Type, (vint(StreamId))/binary, OffsetBin/binary, (vint(Length))/binary>>.

-spec offset_flag(non_neg_integer()) -> 0 | 16#04.
offset_flag(0) -> 0;
offset_flag(_) -> ?STREAM_OFF.

-spec fin_flag(boolean()) -> 0 | 16#01.
fin_flag(true) -> ?STREAM_FIN;
fin_flag(false) -> 0.

-spec encode_ack(
    non_neg_integer(),
    non_neg_integer(),
    non_neg_integer(),
    [{non_neg_integer(), non_neg_integer()}],
    ecn_counts() | undefined
) -> iolist().
encode_ack(Largest, AckDelay, FirstRange, Ranges, Ecn) ->
    Type =
        case Ecn of
            undefined -> ?ACK;
            _ -> ?ACK_ECN
        end,
    Head =
        <<Type, (vint(Largest))/binary, (vint(AckDelay))/binary, (vint(length(Ranges)))/binary,
            (vint(FirstRange))/binary>>,
    [Head, encode_ack_ranges(Ranges) | encode_ecn(Ecn)].

-spec encode_ack_ranges([{non_neg_integer(), non_neg_integer()}]) -> iolist().
encode_ack_ranges([]) ->
    [];
encode_ack_ranges([{Gap, Range} | Rest]) ->
    [vint(Gap), vint(Range) | encode_ack_ranges(Rest)].

-spec encode_ecn(ecn_counts() | undefined) -> iolist().
encode_ecn(undefined) ->
    [];
encode_ecn({ECT0, ECT1, CE}) ->
    [vint(ECT0), vint(ECT1), vint(CE)].

%% =============================================================================
%% decode/1
%% =============================================================================

-doc """
Decode one frame, returning `{ok, Frame, Rest}` or `{error, Reason}`.
A truncated frame (the packet ended mid-field) is `{error, truncated}`;
an unrecognised type is `{error, {unknown_frame_type, Type}}`.
""".
-spec decode(binary()) -> {ok, frame(), binary()} | {error, term()}.
decode(<<?PADDING, Rest/binary>>) ->
    {ok, padding, Rest};
decode(<<?PING, Rest/binary>>) ->
    {ok, ping, Rest};
decode(<<?ACK, Rest/binary>>) ->
    decode_ack(Rest, no_ecn);
decode(<<?ACK_ECN, Rest/binary>>) ->
    decode_ack(Rest, ecn);
decode(<<?RESET_STREAM, Rest/binary>>) ->
    maybe
        {ok, StreamId, R1} ?= take_varint(Rest),
        {ok, ErrorCode, R2} ?= take_varint(R1),
        {ok, FinalSize, R3} ?= take_varint(R2),
        {ok, {reset_stream, StreamId, ErrorCode, FinalSize}, R3}
    end;
decode(<<?STOP_SENDING, Rest/binary>>) ->
    maybe
        {ok, StreamId, R1} ?= take_varint(Rest),
        {ok, ErrorCode, R2} ?= take_varint(R1),
        {ok, {stop_sending, StreamId, ErrorCode}, R2}
    end;
decode(<<?CRYPTO, Rest/binary>>) ->
    maybe
        {ok, Offset, R1} ?= take_varint(Rest),
        {ok, Length, R2} ?= take_varint(R1),
        {ok, Data, R3} ?= take_data(Length, R2),
        {ok, {crypto, Offset, Data}, R3}
    end;
decode(<<?NEW_TOKEN, Rest/binary>>) ->
    maybe
        {ok, Length, R1} ?= take_varint(Rest),
        {ok, Token, R2} ?= take_data(Length, R1),
        {ok, {new_token, Token}, R2}
    end;
decode(<<Type, Rest/binary>>) when Type >= ?STREAM, Type =< ?STREAM_MAX ->
    decode_stream(Type, Rest);
decode(<<?MAX_DATA, Rest/binary>>) ->
    decode_one_varint(Rest, fun(Max) -> {max_data, Max} end);
decode(<<?MAX_STREAM_DATA, Rest/binary>>) ->
    maybe
        {ok, StreamId, R1} ?= take_varint(Rest),
        {ok, Max, R2} ?= take_varint(R1),
        {ok, {max_stream_data, StreamId, Max}, R2}
    end;
decode(<<?MAX_STREAMS_BIDI, Rest/binary>>) ->
    decode_one_varint(Rest, fun(Max) -> {max_streams, bidi, Max} end);
decode(<<?MAX_STREAMS_UNI, Rest/binary>>) ->
    decode_one_varint(Rest, fun(Max) -> {max_streams, uni, Max} end);
decode(<<?DATA_BLOCKED, Rest/binary>>) ->
    decode_one_varint(Rest, fun(Limit) -> {data_blocked, Limit} end);
decode(<<?STREAM_DATA_BLOCKED, Rest/binary>>) ->
    maybe
        {ok, StreamId, R1} ?= take_varint(Rest),
        {ok, Limit, R2} ?= take_varint(R1),
        {ok, {stream_data_blocked, StreamId, Limit}, R2}
    end;
decode(<<?STREAMS_BLOCKED_BIDI, Rest/binary>>) ->
    decode_one_varint(Rest, fun(Limit) -> {streams_blocked, bidi, Limit} end);
decode(<<?STREAMS_BLOCKED_UNI, Rest/binary>>) ->
    decode_one_varint(Rest, fun(Limit) -> {streams_blocked, uni, Limit} end);
decode(<<?NEW_CONNECTION_ID, Rest/binary>>) ->
    maybe
        {ok, Seq, R1} ?= take_varint(Rest),
        {ok, RetirePrior, R2} ?= take_varint(R1),
        decode_new_cid(Seq, RetirePrior, R2)
    end;
decode(<<?RETIRE_CONNECTION_ID, Rest/binary>>) ->
    decode_one_varint(Rest, fun(Seq) -> {retire_connection_id, Seq} end);
decode(<<?PATH_CHALLENGE, Data:8/binary, Rest/binary>>) ->
    {ok, {path_challenge, Data}, Rest};
decode(<<?PATH_RESPONSE, Data:8/binary, Rest/binary>>) ->
    {ok, {path_response, Data}, Rest};
decode(<<?CONNECTION_CLOSE, Rest/binary>>) ->
    maybe
        {ok, ErrorCode, R1} ?= take_varint(Rest),
        {ok, FrameType, R2} ?= take_varint(R1),
        {ok, ReasonLen, R3} ?= take_varint(R2),
        {ok, Reason, R4} ?= take_data(ReasonLen, R3),
        {ok, {connection_close, transport, ErrorCode, FrameType, Reason}, R4}
    end;
decode(<<?CONNECTION_CLOSE_APP, Rest/binary>>) ->
    maybe
        {ok, ErrorCode, R1} ?= take_varint(Rest),
        {ok, ReasonLen, R2} ?= take_varint(R1),
        {ok, Reason, R3} ?= take_data(ReasonLen, R2),
        {ok, {connection_close, application, ErrorCode, undefined, Reason}, R3}
    end;
decode(<<?HANDSHAKE_DONE, Rest/binary>>) ->
    {ok, handshake_done, Rest};
decode(<<Type, _/binary>>) ->
    %% Includes a PATH_CHALLENGE/PATH_RESPONSE with fewer than 8 data bytes.
    case Type of
        ?PATH_CHALLENGE -> {error, truncated};
        ?PATH_RESPONSE -> {error, truncated};
        _ -> {error, {unknown_frame_type, Type}}
    end;
decode(<<>>) ->
    {error, empty}.

%% A frame whose body is exactly one varint.
-spec decode_one_varint(binary(), fun((non_neg_integer()) -> frame())) ->
    {ok, frame(), binary()} | {error, term()}.
decode_one_varint(Bin, Build) ->
    maybe
        {ok, Value, Rest} ?= take_varint(Bin),
        {ok, Build(Value), Rest}
    end.

-spec decode_stream(byte(), binary()) -> {ok, frame(), binary()} | {error, term()}.
decode_stream(Type, Rest) ->
    HasOff = (Type band ?STREAM_OFF) =/= 0,
    HasLen = (Type band ?STREAM_LEN) =/= 0,
    Fin = (Type band ?STREAM_FIN) =/= 0,
    maybe
        {ok, StreamId, R1} ?= take_varint(Rest),
        {ok, Offset, R2} ?= take_stream_offset(HasOff, R1),
        decode_stream_data(StreamId, Offset, Fin, HasLen, R2)
    end.

-spec take_stream_offset(boolean(), binary()) ->
    {ok, non_neg_integer(), binary()} | {error, term()}.
take_stream_offset(true, Bin) -> take_varint(Bin);
take_stream_offset(false, Bin) -> {ok, 0, Bin}.

-spec decode_stream_data(stream_id(), non_neg_integer(), boolean(), boolean(), binary()) ->
    {ok, frame(), binary()} | {error, term()}.
decode_stream_data(StreamId, Offset, Fin, true, Bin) ->
    maybe
        {ok, Length, R1} ?= take_varint(Bin),
        {ok, Data, R2} ?= take_data(Length, R1),
        {ok, {stream, StreamId, Offset, Data, Fin}, R2}
    end;
decode_stream_data(StreamId, Offset, Fin, false, Bin) ->
    %% No length flag: the data runs to the end of the packet payload.
    {ok, {stream, StreamId, Offset, Bin, Fin}, <<>>}.

-spec decode_new_cid(non_neg_integer(), non_neg_integer(), binary()) ->
    {ok, frame(), binary()} | {error, term()}.
decode_new_cid(Seq, RetirePrior, <<CIDLen, Rest/binary>>) when CIDLen >= 1, CIDLen =< 20 ->
    case Rest of
        <<CID:CIDLen/binary, Token:16/binary, R/binary>> ->
            {ok, {new_connection_id, Seq, RetirePrior, CID, Token}, R};
        _ ->
            {error, truncated}
    end;
decode_new_cid(_Seq, _RetirePrior, _Bin) ->
    %% RFC 9000 §19.15: the connection ID length must be 1..20.
    {error, frame_encoding_error}.

-spec decode_ack(binary(), no_ecn | ecn) -> {ok, frame(), binary()} | {error, term()}.
decode_ack(Bin, EcnFlag) ->
    maybe
        {ok, Largest, R1} ?= take_varint(Bin),
        {ok, AckDelay, R2} ?= take_varint(R1),
        {ok, RangeCount, R3} ?= take_varint(R2),
        {ok, FirstRange, R4} ?= take_varint(R3),
        {ok, Ranges, R5} ?= take_ack_ranges(RangeCount, R4),
        decode_ack_ecn(Largest, AckDelay, FirstRange, Ranges, EcnFlag, R5)
    end.

%% Body recursion: cons each {Gap, Range} pair on the way out.
-spec take_ack_ranges(non_neg_integer(), binary()) ->
    {ok, [{non_neg_integer(), non_neg_integer()}], binary()} | {error, term()}.
take_ack_ranges(0, Bin) ->
    {ok, [], Bin};
take_ack_ranges(N, Bin) ->
    maybe
        {ok, Gap, R1} ?= take_varint(Bin),
        {ok, Range, R2} ?= take_varint(R1),
        {ok, Rest, R3} ?= take_ack_ranges(N - 1, R2),
        {ok, [{Gap, Range} | Rest], R3}
    end.

-spec decode_ack_ecn(
    non_neg_integer(),
    non_neg_integer(),
    non_neg_integer(),
    [{non_neg_integer(), non_neg_integer()}],
    no_ecn | ecn,
    binary()
) -> {ok, frame(), binary()} | {error, term()}.
decode_ack_ecn(Largest, AckDelay, FirstRange, Ranges, no_ecn, Bin) ->
    {ok, {ack, Largest, AckDelay, FirstRange, Ranges, undefined}, Bin};
decode_ack_ecn(Largest, AckDelay, FirstRange, Ranges, ecn, Bin) ->
    maybe
        {ok, ECT0, R1} ?= take_varint(Bin),
        {ok, ECT1, R2} ?= take_varint(R1),
        {ok, CE, R3} ?= take_varint(R2),
        {ok, {ack, Largest, AckDelay, FirstRange, Ranges, {ECT0, ECT1, CE}}, R3}
    end.

%% =============================================================================
%% decode_all/1
%% =============================================================================

-doc "Decode every frame in a packet payload into a list, in order.".
-spec decode_all(binary()) -> {ok, [frame()]} | {error, term()}.
decode_all(<<>>) ->
    {ok, []};
decode_all(<<?PADDING, Rest/binary>>) ->
    %% PADDING is a no-op (RFC 9000 §19.1) and packets pad in long runs (a
    %% client Initial is padded to 1200 bytes), so collapse a whole run into a
    %% single `padding` frame rather than decoding each zero byte on its own.
    decode_all_padding(Rest);
decode_all(Bin) ->
    maybe
        {ok, Frame, Rest} ?= decode(Bin),
        {ok, Frames} ?= decode_all(Rest),
        {ok, [Frame | Frames]}
    end.

%% Skip the rest of a PADDING run, then emit one `padding` frame ahead of
%% whatever follows it. Pad runs are long (a client Initial pads ~1150 bytes),
%% so step a machine word at a time and fall back to single bytes at the tail.
-spec decode_all_padding(binary()) -> {ok, [frame()]} | {error, term()}.
decode_all_padding(<<0:64, Rest/binary>>) ->
    decode_all_padding(Rest);
decode_all_padding(<<?PADDING, Rest/binary>>) ->
    decode_all_padding(Rest);
decode_all_padding(Bin) ->
    maybe
        {ok, Frames} ?= decode_all(Bin),
        {ok, [padding | Frames]}
    end.

%% =============================================================================
%% Internal
%% =============================================================================

-spec vint(non_neg_integer()) -> binary().
vint(N) ->
    roadrunner_quic_varint:encode(N).

%% `roadrunner_quic_varint:decode/1` yields `{ok, V, Rest} | {more, _}`;
%% an incomplete varint inside a packet is a malformed frame, normalised
%% to `{error, truncated}` so decode never crashes.
-spec take_varint(binary()) -> {ok, non_neg_integer(), binary()} | {error, truncated}.
take_varint(Bin) ->
    case roadrunner_quic_varint:decode(Bin) of
        {ok, _Value, _Rest} = Ok -> Ok;
        {more, _Need} -> {error, truncated}
    end.

%% Take `Length` octets, or `{error, truncated}` if the packet is short.
-spec take_data(non_neg_integer(), binary()) -> {ok, binary(), binary()} | {error, truncated}.
take_data(Length, Bin) ->
    case Bin of
        <<Data:Length/binary, Rest/binary>> -> {ok, Data, Rest};
        _ -> {error, truncated}
    end.
