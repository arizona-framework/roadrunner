-module(roadrunner_grpc_protobuf_fake_descr_pb).
-moduledoc false.

%% A gpb module generated with `descriptor`. Its top file, gpb's
%% `pkg/greeter.proto` (no package), imports a file by a path of 130 bytes,
%% `protos/aaa...a.proto` (gpb's `pkg/aaa...a.proto`, package `pkg`), and
%% carries a varint field (`public_dependency`) after its import. The
%% imported file has a map field `Labels_2x` in message `Holder`, its entry
%% declared at the top as gpb does (`MapFieldEntry_1_1`, key and value
%% required), and a proto2 group `MyGroup`, its field named after the group
%% as gpb names it.

-export([get_service_def/1, service_name_to_fqbin/1, service_and_rpc_name_to_fqbins/2]).
-export([get_all_proto_names/0, descriptor/1]).
-export([import/0]).

get_service_def('Greeter') -> {{service, 'Greeter'}, []}.

service_name_to_fqbin(Service) -> <<"pkg.", (atom_to_binary(Service))/binary>>.

service_and_rpc_name_to_fqbins(Service, Rpc) ->
    {service_name_to_fqbin(Service), atom_to_binary(Rpc)}.

get_all_proto_names() -> ["greeter", lists:duplicate(117, $a)].

descriptor("greeter") ->
    <<10, 17, "pkg/greeter.proto", 26, 130, 1, (import())/binary, 80, 0>>;
descriptor(_Imported) ->
    iolist_to_binary([
        field(1, <<"pkg/", (binary:copy(~"a", 117))/binary, ".proto">>),
        field(2, ~"pkg"),
        field(4, [
            field(1, ~"Holder"),
            field(2, [
                field(1, ~"Labels_2x"),
                <<24, 1, 32, 3, 40, 11>>,
                field(6, ~".pkg.MapFieldEntry_1_1")
            ]),
            field(2, [field(1, ~"plain"), <<24, 2, 32, 1, 40, 9>>]),
            field(2, [
                field(1, ~"MyGroup"),
                <<24, 3, 32, 1, 40, 10>>,
                field(6, ~".pkg.Holder.MyGroup")
            ]),
            field(3, [field(1, ~"MyGroup"), field(2, [field(1, ~"g"), <<24, 1, 32, 1, 40, 5>>])])
        ]),
        field(4, [
            field(1, ~"MapFieldEntry_1_1"),
            field(2, [field(1, ~"key"), <<24, 1, 32, 2, 40, 9>>]),
            field(2, [field(1, ~"value"), <<24, 2, 32, 2, 40, 5>>]),
            field(7, <<56, 1>>)
        ])
    ]).

import() ->
    <<"protos/", (binary:copy(~"a", 117))/binary, ".proto">>.

field(Number, Value) ->
    Bytes = iolist_to_binary(Value),
    [(Number bsl 3) bor 2, varint(byte_size(Bytes)), Bytes].

varint(N) when N < 128 -> N;
varint(N) -> [128 bor (N band 127), varint(N bsr 7)].
