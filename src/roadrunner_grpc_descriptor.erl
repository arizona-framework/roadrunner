-module(roadrunner_grpc_descriptor).
-moduledoc false.

%% The `.proto` files of the services roadrunner brings, gRPC's
%% grpc/health/v1/health.proto and grpc/reflection/{v1,v1alpha}/
%% reflection.proto, as serialized `google.protobuf.FileDescriptorProto`s
%% for server reflection, written by hand from Erlang terms as protoc
%% describes them.

-export([health/0, reflection/1]).

%% FieldDescriptorProto.Label and .Type values.
-define(OPTIONAL, 1).
-define(REPEATED, 3).
-define(INT32, 5).
-define(STRING, 9).
-define(MESSAGE, 11).
-define(BYTES, 12).
-define(ENUM, 14).

-type type() :: string | bytes | int32 | {message, binary()} | {enum, binary()}.
-type field() :: {binary(), pos_integer(), optional | repeated, type()}.
-type message() :: #{
    name := binary(),
    fields := [field() | {oneof, binary(), [field()]}],
    nested => [message()],
    enums => [{binary(), [{binary(), non_neg_integer()}]}],
    map_entry => true
}.
-type rpc() :: {binary(), binary(), binary(), boolean(), boolean()}.
-type option() :: {pos_integer(), binary() | boolean()}.

%% grpc/health/v1/health.proto.
-spec health() -> binary().
health() ->
    Status = ~".grpc.health.v1.HealthCheckResponse",
    file(
        ~"grpc/health/v1/health.proto",
        ~"grpc.health.v1",
        [
            #{name => ~"HealthCheckRequest", fields => [{~"service", 1, optional, string}]},
            #{
                name => ~"HealthCheckResponse",
                fields => [{~"status", 1, optional, {enum, <<Status/binary, ".ServingStatus">>}}],
                enums => [
                    {~"ServingStatus", [
                        {~"UNKNOWN", 0},
                        {~"SERVING", 1},
                        {~"NOT_SERVING", 2},
                        {~"SERVICE_UNKNOWN", 3}
                    ]}
                ]
            },
            #{name => ~"HealthListRequest", fields => []},
            #{
                name => ~"HealthListResponse",
                fields => [
                    {
                        ~"statuses",
                        1,
                        repeated,
                        {message, ~".grpc.health.v1.HealthListResponse.StatusesEntry"}
                    }
                ],
                nested => [
                    #{
                        name => ~"StatusesEntry",
                        fields => [
                            {~"key", 1, optional, string},
                            {~"value", 2, optional, {message, Status}}
                        ],
                        map_entry => true
                    }
                ]
            }
        ],
        {~"Health", [
            {~"Check", ~".grpc.health.v1.HealthCheckRequest", Status, false, false},
            {
                ~"List",
                ~".grpc.health.v1.HealthListRequest",
                ~".grpc.health.v1.HealthListResponse",
                false,
                false
            },
            {~"Watch", ~".grpc.health.v1.HealthCheckRequest", Status, false, true}
        ]},
        %% java_package, java_outer_classname, java_multiple_files,
        %% go_package, objc_class_prefix, csharp_namespace.
        [
            {1, ~"io.grpc.health.v1"},
            {8, ~"HealthProto"},
            {10, true},
            {11, ~"google.golang.org/grpc/health/grpc_health_v1"},
            {36, ~"GrpcHealthV1"},
            {37, ~"Grpc.Health.V1"}
        ]
    ).

%% grpc/reflection/v1/reflection.proto and its older v1alpha twin: the
%% same messages, in their own package.
-spec reflection(binary()) -> binary().
reflection(Version) ->
    Package = <<"grpc.reflection.", Version/binary>>,
    Type = fun(Name) -> {message, <<".", Package/binary, ".", Name/binary>>} end,
    {message, Request} = Type(~"ServerReflectionRequest"),
    {message, Response} = Type(~"ServerReflectionResponse"),
    file(
        <<"grpc/reflection/", Version/binary, "/reflection.proto">>,
        Package,
        [
            #{
                name => ~"ServerReflectionRequest",
                fields => [
                    {~"host", 1, optional, string},
                    {oneof, ~"message_request", [
                        {~"file_by_filename", 3, optional, string},
                        {~"file_containing_symbol", 4, optional, string},
                        {~"file_containing_extension", 5, optional, Type(~"ExtensionRequest")},
                        {~"all_extension_numbers_of_type", 6, optional, string},
                        {~"list_services", 7, optional, string}
                    ]}
                ]
            },
            #{
                name => ~"ExtensionRequest",
                fields => [
                    {~"containing_type", 1, optional, string},
                    {~"extension_number", 2, optional, int32}
                ]
            },
            #{
                name => ~"ServerReflectionResponse",
                fields => [
                    {~"valid_host", 1, optional, string},
                    {~"original_request", 2, optional, {message, Request}},
                    {oneof, ~"message_response", [
                        {~"file_descriptor_response", 4, optional, Type(~"FileDescriptorResponse")},
                        {
                            ~"all_extension_numbers_response",
                            5,
                            optional,
                            Type(~"ExtensionNumberResponse")
                        },
                        {~"list_services_response", 6, optional, Type(~"ListServiceResponse")},
                        {~"error_response", 7, optional, Type(~"ErrorResponse")}
                    ]}
                ]
            },
            #{
                name => ~"FileDescriptorResponse",
                fields => [{~"file_descriptor_proto", 1, repeated, bytes}]
            },
            #{
                name => ~"ExtensionNumberResponse",
                fields => [
                    {~"base_type_name", 1, optional, string},
                    {~"extension_number", 2, repeated, int32}
                ]
            },
            #{
                name => ~"ListServiceResponse",
                fields => [{~"service", 1, repeated, Type(~"ServiceResponse")}]
            },
            #{name => ~"ServiceResponse", fields => [{~"name", 1, optional, string}]},
            #{
                name => ~"ErrorResponse",
                fields => [
                    {~"error_code", 1, optional, int32},
                    {~"error_message", 2, optional, string}
                ]
            }
        ],
        {~"ServerReflection", [{~"ServerReflectionInfo", Request, Response, true, true}]},
        reflection_options(Version)
    ).

%% java_package, java_outer_classname, java_multiple_files, go_package, and
%% v1alpha's `deprecated`.
-spec reflection_options(binary()) -> [option()].
reflection_options(Version) ->
    [
        {1, <<"io.grpc.reflection.", Version/binary>>},
        {8, ~"ServerReflectionProto"},
        {10, true},
        {11, <<"google.golang.org/grpc/reflection/grpc_reflection_", Version/binary>>}
        | [{23, true} || Version =:= ~"v1alpha"]
    ].

%% FileDescriptorProto: `name` (1), `package` (2), `message_type` (4),
%% `service` (6), `options` (8) and `syntax` (12).
-spec file(binary(), binary(), [message()], {binary(), [rpc()]}, [option()]) -> binary().
file(Name, Package, Messages, {Service, Rpcs}, Options) ->
    iolist_to_binary([
        field(1, Name),
        field(2, Package),
        [field(4, message(Message)) || Message <- Messages],
        field(6, [field(1, Service) | [field(2, rpc(Rpc)) || Rpc <- Rpcs]]),
        field(8, [option(Option) || Option <- Options]),
        field(12, ~"proto3")
    ]).

%% DescriptorProto: `name` (1), `field` (2), `nested_type` (3),
%% `enum_type` (4), `options` (7, MessageOptions' `map_entry`, 7) and
%% `oneof_decl` (8). A oneof's fields carry its index (`oneof_index`, 9).
-spec message(message()) -> iodata().
message(#{name := Name, fields := Fields} = Message) ->
    Oneofs = [Oneof || {oneof, Oneof, _} <- Fields],
    [
        field(1, Name),
        [field(2, field_descriptor(Field, Oneofs)) || Field <- flat_fields(Fields)],
        [field(3, message(Nested)) || #{nested := All} <- [Message], Nested <- All],
        [field(4, enum(Enum)) || #{enums := All} <- [Message], Enum <- All],
        [field(7, [7 bsl 3, 1]) || #{map_entry := true} <- [Message]],
        [field(8, field(1, Oneof)) || Oneof <- Oneofs]
    ].

-spec flat_fields([field() | {oneof, binary(), [field()]}]) -> [field() | {binary(), field()}].
flat_fields([]) -> [];
flat_fields([{oneof, Oneof, Fields} | Rest]) -> oneof_fields(Oneof, Fields, Rest);
flat_fields([Field | Rest]) -> [Field | flat_fields(Rest)].

-spec oneof_fields(binary(), [field()], [field() | {oneof, binary(), [field()]}]) ->
    [field() | {binary(), field()}].
oneof_fields(_Oneof, [], Rest) -> flat_fields(Rest);
oneof_fields(Oneof, [Field | Fields], Rest) -> [{Oneof, Field} | oneof_fields(Oneof, Fields, Rest)].

%% FieldDescriptorProto: `name` (1), `number` (3), `label` (4), `type` (5),
%% `type_name` (6), `oneof_index` (9) and `json_name` (10).
-spec field_descriptor(field() | {binary(), field()}, [binary()]) -> iodata().
field_descriptor({Oneof, {_, _, _, _} = Field}, Oneofs) ->
    Index = length(lists:takewhile(fun(Other) -> Other =/= Oneof end, Oneofs)),
    [field_descriptor(Field, Oneofs), varint_field(9, Index)];
field_descriptor({Name, Number, Label, Type}, _Oneofs) ->
    [
        field(1, Name),
        varint_field(3, Number),
        varint_field(4, label(Label)),
        varint_field(5, type(Type)),
        case Type of
            {_, TypeName} -> field(6, TypeName);
            _ -> []
        end,
        field(10, json_name(Name))
    ].

-spec label(optional | repeated) -> pos_integer().
label(optional) -> ?OPTIONAL;
label(repeated) -> ?REPEATED.

-spec type(type()) -> pos_integer().
type(string) -> ?STRING;
type(bytes) -> ?BYTES;
type(int32) -> ?INT32;
type({message, _}) -> ?MESSAGE;
type({enum, _}) -> ?ENUM.

%% protoc's JSON name: lowerCamelCase, each `_` dropped and the letter
%% after it capitalised; the names here are lowercase words joined by `_`.
-spec json_name(binary()) -> binary().
json_name(<<"_", C, Rest/binary>>) -> <<(C - 32), (json_name(Rest))/binary>>;
json_name(<<C, Rest/binary>>) -> <<C, (json_name(Rest))/binary>>;
json_name(<<>>) -> <<>>.

%% EnumDescriptorProto: `name` (1) and its values (2), each its `name` (1)
%% and `number` (2).
-spec enum({binary(), [{binary(), non_neg_integer()}]}) -> iodata().
enum({Name, Values}) ->
    [
        field(1, Name)
        | [field(2, [field(1, Value), varint_field(2, Number)]) || {Value, Number} <- Values]
    ].

%% MethodDescriptorProto: `name` (1), `input_type` (2), `output_type` (3),
%% `client_streaming` (5) and `server_streaming` (6), left out when false.
-spec rpc(rpc()) -> iodata().
rpc({Name, Input, Output, ClientStreaming, ServerStreaming}) ->
    [
        field(1, Name),
        field(2, Input),
        field(3, Output),
        [varint_field(5, 1) || ClientStreaming],
        [varint_field(6, 1) || ServerStreaming]
    ].

%% A FileOptions field: a string, or a bool.
-spec option(option()) -> iodata().
option({Number, true}) -> varint_field(Number, 1);
option({Number, Value}) -> field(Number, Value).

-spec field(pos_integer(), iodata()) -> iodata().
field(Number, Value) ->
    [varint((Number bsl 3) bor 2), varint(iolist_size(Value)), Value].

-spec varint_field(pos_integer(), non_neg_integer()) -> iodata().
varint_field(Number, Value) ->
    [varint(Number bsl 3), varint(Value)].

-spec varint(non_neg_integer()) -> binary().
varint(N) when N < 128 -> <<N>>;
varint(N) -> <<1:1, (N band 127):7, (varint(N bsr 7))/binary>>.
