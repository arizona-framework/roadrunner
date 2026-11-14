-module(roadrunner_grpc_protobuf_fake_pb).
-moduledoc false.

%% A service as gpb modules generated with other options give it: `Greeter`
%% without `maps` (its methods as `#rpc{}` records), `ProplistGreeter` with
%% `defs_as_proplists`. `Colliding` has two methods whose functions would
%% have the same name; `Partial` and `Odd` a method in no format gpb has.

-export([get_service_def/1, service_name_to_fqbin/1, service_and_rpc_name_to_fqbins/2]).

get_service_def('Greeter') ->
    {{service, 'Greeter'}, [{rpc, 'SayHello', 'HelloRequest', 'HelloReply', false, false, []}]};
get_service_def('ProplistGreeter') ->
    {{service, 'ProplistGreeter'}, [
        [
            {name, 'SayHello'},
            {input, 'HelloRequest'},
            {output, 'HelloReply'},
            {input_stream, false},
            {output_stream, true},
            {opts, []}
        ]
    ]};
get_service_def('Colliding') ->
    {{service, 'Colliding'}, [
        {rpc, 'GetV2', 'HelloRequest', 'HelloReply', false, false, []},
        {rpc, 'Get_V2', 'HelloRequest', 'HelloReply', false, false, []}
    ]};
get_service_def('Partial') ->
    {{service, 'Partial'}, [[{name, 'SayHello'}]]};
get_service_def('Odd') ->
    {{service, 'Odd'}, [odd]};
get_service_def(_) ->
    error.

service_name_to_fqbin(Service) -> <<"helloworld.", (atom_to_binary(Service))/binary>>.

service_and_rpc_name_to_fqbins(Service, Rpc) ->
    {service_name_to_fqbin(Service), atom_to_binary(Rpc)}.
