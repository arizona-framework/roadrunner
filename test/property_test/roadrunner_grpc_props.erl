-module(roadrunner_grpc_props).
-moduledoc """
Property-based tests for the gRPC wire pieces: message framing
(`roadrunner_grpc_frame`), the `grpc-message` encoding
(`roadrunner_grpc_status`) and the `grpc-timeout` reader
(`roadrunner_grpc_timeout`).
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

%% Framed messages, split into DATA-sized pieces anywhere, decode back to
%% the same messages in order.
prop_frame_round_trips() ->
    ?FORALL(
        {Messages, Cut},
        {list({boolean(), binary()}), pos_integer()},
        begin
            Wire = iolist_to_binary([roadrunner_grpc_frame:encode(C, M) || {C, M} <- Messages]),
            decode_all(pieces(Wire, Cut), <<>>) =:= Messages
        end
    ).

%% Any message decodes back to itself, and its encoding holds only space
%% through `~`, with `%` only as an escape's start.
prop_status_message_round_trips() ->
    ?FORALL(
        Message,
        binary(),
        begin
            Encoded = roadrunner_grpc_status:encode_message(Message),
            roadrunner_grpc_status:decode_message(Encoded) =:= Message andalso
                lists:all(fun(C) -> C >= 16#20 andalso C =< 16#7E end, binary_to_list(Encoded))
        end
    ).

%% Reading a timeout never crashes, and what it reads is a count of
%% milliseconds, infinity or error.
prop_timeout_parse_never_crashes() ->
    ?FORALL(
        Value,
        oneof([binary(), timeout_value()]),
        case roadrunner_grpc_timeout:parse(Value) of
            {ok, infinity} -> true;
            {ok, Ms} -> is_integer(Ms) andalso Ms >= 0 andalso Ms =< 16#FFFFFFFF;
            error -> true
        end
    ).

timeout_value() ->
    ?LET(
        {Digits, Unit},
        {non_empty(list(integer($0, $9))), oneof([$H, $M, $S, $m, $u, $n])},
        list_to_binary(Digits ++ [Unit])
    ).

pieces(<<>>, _Cut) ->
    [];
pieces(Bin, Cut) when byte_size(Bin) =< Cut ->
    [Bin];
pieces(Bin, Cut) ->
    <<Piece:Cut/binary, Rest/binary>> = Bin,
    [Piece | pieces(Rest, Cut)].

decode_all([], <<>>) ->
    [];
decode_all(Pieces, Buffer) ->
    case roadrunner_grpc_frame:decode(Buffer, 16#FFFFFFFF) of
        {ok, C, M, Rest} ->
            [{C, M} | decode_all(Pieces, Rest)];
        more ->
            [Piece | Rest] = Pieces,
            decode_all(Rest, <<Buffer/binary, Piece/binary>>)
    end.
