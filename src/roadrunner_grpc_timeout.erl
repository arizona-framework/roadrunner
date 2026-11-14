-module(roadrunner_grpc_timeout).
-moduledoc false.

%% The `grpc-timeout` request header (gRPC's PROTOCOL-HTTP2): a value of at
%% most 8 ASCII digits and one unit, `H` hours, `M` minutes, `S` seconds,
%% `m` milliseconds, `u` microseconds or `n` nanoseconds. It is read as
%% milliseconds, a part of one rounding up so a deadline never comes early.
%% A timeout longer than a `receive` can wait (`16#FFFFFFFF` ms, about 49
%% days) is as good as none, so it reads as `infinity`.

-export([parse/1]).

-define(MAX_WAIT, 16#FFFFFFFF).

-doc """
The timeout in milliseconds, `infinity` for one past what a wait can take,
or `error` for a value that is not 1 to 8 digits and a unit.
""".
-spec parse(binary()) -> {ok, non_neg_integer() | infinity} | error.
parse(<<C, Rest/binary>>) when C >= $0, C =< $9 ->
    digits(Rest, C - $0, 1);
parse(_Value) ->
    error.

%% Read the digits straight off the value, then the unit as its last byte.
-spec digits(binary(), non_neg_integer(), 1..8) -> {ok, non_neg_integer() | infinity} | error.
digits(<<C, Rest/binary>>, Value, Count) when Count < 8, C >= $0, C =< $9 ->
    digits(Rest, Value * 10 + (C - $0), Count + 1);
digits(<<Unit>>, Value, _Count) ->
    unit(Unit, Value);
digits(_Rest, _Value, _Count) ->
    error.

-spec unit(byte(), non_neg_integer()) -> {ok, non_neg_integer() | infinity} | error.
unit($H, Value) -> bounded(Value * 3_600_000);
unit($M, Value) -> bounded(Value * 60_000);
unit($S, Value) -> bounded(Value * 1000);
unit($m, Value) -> bounded(Value);
unit($u, Value) -> bounded((Value + 999) div 1000);
unit($n, Value) -> bounded((Value + 999_999) div 1_000_000);
unit(_Unit, _Value) -> error.

-spec bounded(non_neg_integer()) -> {ok, non_neg_integer() | infinity}.
bounded(Ms) when Ms =< ?MAX_WAIT -> {ok, Ms};
bounded(_Ms) -> {ok, infinity}.
