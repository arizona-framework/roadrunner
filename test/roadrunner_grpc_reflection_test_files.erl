-module(roadrunner_grpc_reflection_test_files).
-moduledoc false.

%% FileDescriptorProtos written by hand for the reflection tests, and the
%% few protobuf helpers to write requests and read responses:
%%
%% - `dep.proto` (package `test.dep`): message `Dep` (field `id`), enum
%%   `Color` (value `RED`)
%% - `base.proto` (package `test`), importing `dep.proto` and
%%   `missing.proto`, which no service gives: message `Msg` (field `id`,
%%   nested message `Inner`, enum `Kind` with `KIND_A`, oneof `choice`,
%%   extension `inner_ext` of `.test.Msg`, 101), service `Echo` (method
%%   `Unary`), extension `ext` of `.test.Msg`, 100
%% - `ext.proto` (no package), importing `base.proto`: message `Top`,
%%   extension `more` of `test.Msg`, 200

-export([files/0, dep/0, base/0, ext/0, file_named/1]).
-export([field/2, varint_field/2, fields/1, values/2]).

files() ->
    [base(), dep()].

dep() ->
    file([
        field(1, ~"dep.proto"),
        field(2, ~"test.dep"),
        field(4, [field(1, ~"Dep"), field(2, field(1, ~"id"))]),
        field(5, [field(1, ~"Color"), field(2, field(1, ~"RED"))])
    ]).

base() ->
    file([
        field(1, ~"base.proto"),
        field(2, ~"test"),
        field(3, ~"dep.proto"),
        field(3, ~"missing.proto"),
        field(4, [
            field(1, ~"Msg"),
            field(2, field(1, ~"id")),
            field(3, field(1, ~"Inner")),
            field(4, [field(1, ~"Kind"), field(2, field(1, ~"KIND_A"))]),
            field(6, [field(1, ~"inner_ext"), field(2, ~".test.Msg"), varint_field(3, 101)]),
            field(8, field(1, ~"choice"))
        ]),
        field(6, [field(1, ~"Echo"), field(2, field(1, ~"Unary"))]),
        field(7, [field(1, ~"ext"), field(2, ~".test.Msg"), varint_field(3, 100)]),
        %% `syntax`, a field reflection does not read.
        field(12, ~"proto3")
    ]).

ext() ->
    file([
        field(1, ~"ext.proto"),
        field(3, ~"base.proto"),
        field(4, field(1, ~"Top")),
        field(7, [field(1, ~"more"), field(2, ~"test.Msg"), varint_field(3, 200)])
    ]).

%% A file of that name, declaring message `Shadowed`.
file_named(Name) ->
    file([field(1, Name), field(4, field(1, ~"Shadowed"))]).

file(Fields) ->
    iolist_to_binary(Fields).

field(Number, Value) ->
    [varint((Number bsl 3) bor 2), varint(iolist_size(Value)), Value].

varint_field(Number, Value) ->
    [varint(Number bsl 3), varint(Value)].

varint(N) when N < 128 -> <<N>>;
varint(N) -> <<1:1, (N band 127):7, (varint(N bsr 7))/binary>>.

%% A message's fields in order, `{Number, Value}`: a length-delimited one's
%% bytes, a varint's value.
fields(<<>>) ->
    [];
fields(Bytes) ->
    {Key, Rest} = read_varint(Bytes, 0, 0),
    case Key band 7 of
        0 ->
            {Value, Rest1} = read_varint(Rest, 0, 0),
            [{Key bsr 3, Value} | fields(Rest1)];
        2 ->
            {Len, Rest1} = read_varint(Rest, 0, 0),
            <<Value:Len/binary, Rest2/binary>> = Rest1,
            [{Key bsr 3, Value} | fields(Rest2)]
    end.

%% The values of one field.
values(Number, Fields) ->
    [Value || {N, Value} <- Fields, N =:= Number].

read_varint(<<1:1, Low:7, Rest/binary>>, Shift, Acc) ->
    read_varint(Rest, Shift + 7, Acc bor (Low bsl Shift));
read_varint(<<0:1, Low:7, Rest/binary>>, Shift, Acc) ->
    {Acc bor (Low bsl Shift), Rest}.
