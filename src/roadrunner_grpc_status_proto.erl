-module(roadrunner_grpc_status_proto).
-moduledoc false.

%% gRPC's rich error model (google/rpc/status.proto), written by hand: a
%% google.rpc.Status of `int32 code = 1`, `string message = 2` and
%% `repeated google.protobuf.Any details = 3`, each Any a `string type_url
%% = 1` and `bytes value = 2`. Proto3 leaves out a field at its default (a
%% zero code, an empty string or bytes), as protobuf writers do.

-export([status/3]).

%% The google.rpc.Status of a status code, its message and its details,
%% each `{TypeUrl, Value}`, `Value` the detail message's own bytes. A detail
%% of any other shape raises.
-spec status(roadrunner_grpc_status:code(), binary(), [{binary(), iodata()}]) -> iodata().
status(Code, Message, Details) ->
    [
        code(Code),
        string_field(2, Message)
        | [field(3, any(TypeUrl, Value)) || {TypeUrl, Value} <- Details]
    ].

-spec code(roadrunner_grpc_status:code()) -> iodata().
code(0) -> [];
code(Code) -> [1 bsl 3, Code].

%% google.protobuf.Any.
-spec any(binary(), iodata()) -> iodata().
any(TypeUrl, Value) when is_binary(TypeUrl) ->
    [string_field(1, TypeUrl), string_field(2, Value)].

-spec string_field(1..2, iodata()) -> iodata().
string_field(Number, Value) ->
    case iolist_size(Value) of
        0 -> [];
        _ -> field(Number, Value)
    end.

%% A length-delimited field (wire type 2).
-spec field(1..3, iodata()) -> iodata().
field(Number, Value) ->
    [(Number bsl 3) bor 2, varint(iolist_size(Value)), Value].

-spec varint(non_neg_integer()) -> binary().
varint(N) when N < 128 -> <<N>>;
varint(N) -> <<1:1, (N band 127):7, (varint(N bsr 7))/binary>>.
