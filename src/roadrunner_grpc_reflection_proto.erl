-module(roadrunner_grpc_reflection_proto).
-moduledoc false.

%% The protobuf messages of gRPC's server reflection
%% (grpc/reflection/v1/reflection.proto, the same in v1alpha), read and
%% written by hand, and the parts of a `google.protobuf.FileDescriptorProto`
%% (google/protobuf/descriptor.proto) reflection looks up: the file's name,
%% its imports, and the full names it declares.

-export([request/1, response/3, file/1]).

-export_type([query/0, answer/0, file/0]).

-type query() ::
    {file_by_filename, binary()}
    | {file_containing_symbol, binary()}
    | {file_containing_extension, binary(), integer()}
    | {all_extension_numbers_of_type, binary()}
    | list_services
    | none.

-type answer() ::
    {files, [binary()]}
    | {extension_numbers, binary(), [non_neg_integer()]}
    | {services, [binary()]}
    | {error, non_neg_integer(), binary()}.

-type file() :: #{
    name := binary(),
    dependencies := [binary()],
    symbols := [binary()],
    messages := [binary()],
    extensions := [{binary(), non_neg_integer()}]
}.

%% A ServerReflectionRequest: its `host` (1) and the one request its
%% `message_request` oneof holds, the last one sent when several are, as
%% protobuf reads a oneof; `none` when it holds none. Bytes that are no
%% such message are `malformed`.
-spec request(binary()) -> {ok, binary(), query()} | malformed.
request(Bytes) ->
    try
        Fields = fields(Bytes),
        {ok, string(1, Fields), query(Fields, none)}
    catch
        error:_ -> malformed
    end.

-spec query([{pos_integer(), binary() | non_neg_integer()}], query()) -> query().
query([], Query) ->
    Query;
query([{3, Name} | Rest], _Query) when is_binary(Name) ->
    query(Rest, {file_by_filename, Name});
query([{4, Symbol} | Rest], _Query) when is_binary(Symbol) ->
    query(Rest, {file_containing_symbol, Symbol});
query([{5, Extension} | Rest], _Query) when is_binary(Extension) ->
    %% ExtensionRequest: `containing_type` (1) and `extension_number` (2),
    %% an int32.
    Fields = fields(Extension),
    <<Number:32/signed>> = <<(number(2, Fields)):32>>,
    query(Rest, {file_containing_extension, string(1, Fields), Number});
query([{6, Type} | Rest], _Query) when is_binary(Type) ->
    query(Rest, {all_extension_numbers_of_type, Type});
query([{7, Content} | Rest], _Query) when is_binary(Content) ->
    query(Rest, list_services);
query([{Number, _Value} | Rest], Query) when Number < 3; Number > 7 ->
    query(Rest, Query).

%% A ServerReflectionResponse: the request's `host` as `valid_host` (1),
%% the request itself as `original_request` (2), and the answer.
-spec response(binary(), binary(), answer()) -> iodata().
response(Host, Request, Answer) ->
    [string_field(1, Host), field(2, Request) | answer(Answer)].

-spec answer(answer()) -> iodata().
answer({files, Files}) ->
    %% FileDescriptorResponse: `repeated bytes file_descriptor_proto = 1`.
    field(4, [field(1, File) || File <- Files]);
answer({extension_numbers, Type, Numbers}) ->
    %% ExtensionNumberResponse: `base_type_name` (1) and the packed
    %% `repeated int32 extension_number` (2).
    field(5, [string_field(1, Type) | packed(2, Numbers)]);
answer({services, Names}) ->
    %% ListServiceResponse: `repeated ServiceResponse service = 1`, each
    %% one its `name` (1).
    field(6, [field(1, field(1, Name)) || Name <- Names]);
answer({error, Code, Message}) ->
    %% ErrorResponse: `error_code` (1) and `error_message` (2).
    field(7, [varint_field(1, Code) | string_field(2, Message)]).

-spec packed(pos_integer(), [non_neg_integer()]) -> iodata().
packed(_Number, []) -> [];
packed(Number, Values) -> field(Number, [varint(Value) || Value <- Values]).

%% proto3 leaves a field at its default (the empty string, zero) out.
-spec string_field(pos_integer(), binary()) -> iodata().
string_field(_Number, <<>>) -> [];
string_field(Number, Value) -> field(Number, Value).

%% A varint field (wire type 0).
-spec varint_field(pos_integer(), non_neg_integer()) -> iodata().
varint_field(Number, Value) -> [Number bsl 3, varint(Value)].

%% A length-delimited field (wire type 2).
-spec field(pos_integer(), iodata()) -> iodata().
field(Number, Value) ->
    [varint((Number bsl 3) bor 2), varint(iolist_size(Value)), Value].

-spec varint(non_neg_integer()) -> binary().
varint(N) when N < 128 -> <<N>>;
varint(N) -> <<1:1, (N band 127):7, (varint(N bsr 7))/binary>>.

%% What a FileDescriptorProto declares: its `name` (1), its imports
%% (`dependency`, 3), and every full name in it, `package` (2) first:
%% messages (4) with their fields, oneofs, nested messages, enums and
%% extensions; enums (5) with their values, which protobuf scopes next to
%% their enum; services (6) with their methods; and extensions (7), with
%% the message each extends and its number. Bytes that are no such message,
%% or one without a name, raise.
-spec file(binary()) -> file().
file(Bytes) ->
    Fields = fields(Bytes),
    <<_, _/binary>> = Name = string(1, Fields),
    Scope = scope(string(2, Fields)),
    Declared = lists:flatten([
        [message(Scope, Message) || {4, Message} <- Fields],
        [enum(Scope, Enum) || {5, Enum} <- Fields],
        [service(Scope, Service) || {6, Service} <- Fields],
        [extension(Scope, Extension) || {7, Extension} <- Fields]
    ]),
    #{
        name => Name,
        dependencies => [Dependency || {3, Dependency} <- Fields, is_binary(Dependency)],
        symbols => [Symbol || {symbol, Symbol} <- Declared],
        messages => [Message || {message, Message} <- Declared],
        extensions => [{Extendee, Number} || {extension, Extendee, Number} <- Declared]
    }.

-spec scope(binary()) -> binary().
scope(<<>>) -> <<>>;
scope(Package) -> <<Package/binary, ".">>.

%% A DescriptorProto: its fields (2), nested messages (3), enums (4),
%% extensions (6) and oneofs (8) live in its scope.
-spec message(binary(), binary()) -> [term()].
message(Scope, Bytes) ->
    Fields = fields(Bytes),
    FullName = <<Scope/binary, (string(1, Fields))/binary>>,
    Inner = scope(FullName),
    [
        {symbol, FullName},
        {message, FullName},
        [{symbol, <<Inner/binary, (name(Field))/binary>>} || {2, Field} <- Fields],
        [message(Inner, Nested) || {3, Nested} <- Fields],
        [enum(Inner, Enum) || {4, Enum} <- Fields],
        [extension(Inner, Extension) || {6, Extension} <- Fields],
        [{symbol, <<Inner/binary, (name(Oneof))/binary>>} || {8, Oneof} <- Fields]
    ].

%% An EnumDescriptorProto: its values (2) are named in the enum's own
%% scope, not inside the enum.
-spec enum(binary(), binary()) -> [term()].
enum(Scope, Bytes) ->
    Fields = fields(Bytes),
    [
        {symbol, <<Scope/binary, (string(1, Fields))/binary>>}
        | [{symbol, <<Scope/binary, (name(Value))/binary>>} || {2, Value} <- Fields]
    ].

%% A ServiceDescriptorProto and its methods (2).
-spec service(binary(), binary()) -> [term()].
service(Scope, Bytes) ->
    Fields = fields(Bytes),
    FullName = <<Scope/binary, (string(1, Fields))/binary>>,
    Inner = scope(FullName),
    [
        {symbol, FullName}
        | [{symbol, <<Inner/binary, (name(Method))/binary>>} || {2, Method} <- Fields]
    ].

%% A FieldDescriptorProto that is an extension: its `extendee` (2), a full
%% name that may start with a dot, and its `number` (3).
-spec extension(binary(), binary()) -> [term()].
extension(Scope, Bytes) ->
    Fields = fields(Bytes),
    Extendee =
        case string(2, Fields) of
            <<".", Type/binary>> -> Type;
            Type -> Type
        end,
    [
        {symbol, <<Scope/binary, (string(1, Fields))/binary>>},
        {extension, Extendee, number(3, Fields)}
    ].

%% A descriptor's `name` (1).
-spec name(binary()) -> binary().
name(Bytes) ->
    string(1, fields(Bytes)).

%% The last value of a length-delimited field, the empty one when absent.
-spec string(pos_integer(), [{pos_integer(), binary() | non_neg_integer()}]) -> binary().
string(Number, Fields) ->
    case [Value || {N, Value} <- Fields, N =:= Number] of
        [] -> <<>>;
        Values -> <<_/binary>> = lists:last(Values)
    end.

%% The last value of a varint field, zero when absent.
-spec number(pos_integer(), [{pos_integer(), binary() | non_neg_integer()}]) -> non_neg_integer().
number(Number, Fields) ->
    case [Value || {N, Value} <- Fields, N =:= Number, is_integer(Value)] of
        [] -> 0;
        Values -> lists:last(Values)
    end.

%% A message's fields in order: a length-delimited one's bytes, a varint's
%% value; fixed-width fields are skipped. Malformed bytes raise.
-spec fields(binary()) -> [{pos_integer(), binary() | non_neg_integer()}].
fields(<<>>) ->
    [];
fields(Bytes) ->
    {Key, Rest} = read_varint(Bytes, 0, 0),
    Number = Key bsr 3,
    true = Number > 0,
    case Key band 7 of
        0 ->
            {Value, Rest1} = read_varint(Rest, 0, 0),
            [{Number, Value} | fields(Rest1)];
        1 ->
            <<_:64, Rest1/binary>> = Rest,
            fields(Rest1);
        2 ->
            {Len, Rest1} = read_varint(Rest, 0, 0),
            <<Value:Len/binary, Rest2/binary>> = Rest1,
            [{Number, Value} | fields(Rest2)];
        5 ->
            <<_:32, Rest1/binary>> = Rest,
            fields(Rest1)
    end.

-spec read_varint(binary(), non_neg_integer(), non_neg_integer()) ->
    {non_neg_integer(), binary()}.
read_varint(<<1:1, Low:7, Rest/binary>>, Shift, Acc) when Shift < 64 ->
    read_varint(Rest, Shift + 7, Acc bor (Low bsl Shift));
read_varint(<<0:1, Low:7, Rest/binary>>, Shift, Acc) ->
    {Acc bor (Low bsl Shift), Rest}.
