-module(roadrunner_grpc_health_proto).
-moduledoc false.

%% The protobuf messages of gRPC's health service (grpc/health/v1/
%% health.proto), read and written by hand: HealthCheckRequest's one string,
%% HealthCheckResponse's one enum and HealthListResponse's map of them.

-export([service/1, response/1, list/1]).

%% HealthCheckRequest's `string service = 1`, the empty name when absent;
%% other fields are skipped, as protobuf readers do. Bytes that are no
%% protobuf message are `malformed`.
-spec service(binary()) -> {ok, binary()} | malformed.
service(Request) ->
    try fields(Request) of
        #{1 := Service} -> {ok, Service};
        #{} -> {ok, <<>>}
    catch
        error:_ -> malformed
    end.

%% HealthCheckResponse: `ServingStatus status = 1`, a varint; proto3 leaves
%% out the default (UNKNOWN, 0), which this never sends.
-spec response(1..3) -> binary().
response(Status) ->
    <<8, Status>>.

%% HealthListResponse: `map<string, HealthCheckResponse> statuses = 1`,
%% each entry a message of the key (field 1) and the value (field 2).
-spec list([{binary(), 1..3}]) -> iodata().
list(Statuses) ->
    [field(1, [field(1, Service), field(2, response(Status))]) || {Service, Status} <- Statuses].

%% A length-delimited field (wire type 2).
-spec field(1..2, iodata()) -> iodata().
field(Number, Value) ->
    [(Number bsl 3) bor 2, varint(iolist_size(Value)), Value].

-spec varint(non_neg_integer()) -> binary().
varint(N) when N < 128 -> <<N>>;
varint(N) -> <<1:1, (N band 127):7, (varint(N bsr 7))/binary>>.

%% The length-delimited fields of a message by number, the last one of a
%% number winning; other wire types are skipped. Malformed bytes raise.
-spec fields(binary()) -> #{pos_integer() => binary()}.
fields(<<>>) ->
    #{};
fields(Bytes) ->
    {Key, Rest} = read_varint(Bytes, 0, 0),
    {Value, Rest1} = skip(Key band 7, Rest),
    Fields = fields(Rest1),
    case Key band 7 of
        2 when not is_map_key(Key bsr 3, Fields) -> Fields#{Key bsr 3 => Value};
        _ -> Fields
    end.

-spec skip(0..7, binary()) -> {binary(), binary()}.
skip(0, Bytes) ->
    {_, Rest} = read_varint(Bytes, 0, 0),
    {<<>>, Rest};
skip(1, <<_:64, Rest/binary>>) ->
    {<<>>, Rest};
skip(2, Bytes) ->
    {Len, Rest} = read_varint(Bytes, 0, 0),
    <<Value:Len/binary, Rest1/binary>> = Rest,
    {Value, Rest1};
skip(5, <<_:32, Rest/binary>>) ->
    {<<>>, Rest}.

-spec read_varint(binary(), non_neg_integer(), non_neg_integer()) ->
    {non_neg_integer(), binary()}.
read_varint(<<1:1, Low:7, Rest/binary>>, Shift, Acc) when Shift < 64 ->
    read_varint(Rest, Shift + 7, Acc bor (Low bsl Shift));
read_varint(<<0:1, Low:7, Rest/binary>>, Shift, Acc) ->
    {Acc bor (Low bsl Shift), Rest}.
