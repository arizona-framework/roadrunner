-module(roadrunner_grpc_protobuf_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("gpb/descr_src/gpb_descriptor.hrl").

-export([empty_call/2]).

-define(M, roadrunner_grpc_protobuf).
-define(PB, test_pb).
-define(IMPL, roadrunner_grpc_protobuf_interop).
-define(SERVICE, 'grpc.testing.TestService').
-define(FAKE, roadrunner_grpc_protobuf_fake_pb).

codec_test() ->
    ?assertEqual(~"proto", ?M:subtype()),
    Type = {?PB, 'grpc.testing.SimpleRequest'},
    Request = #{response_size => 3, payload => #{type => 'COMPRESSABLE', body => ~"abc"}},
    Bytes = iolist_to_binary(?M:encode(Type, Request)),
    ?assertMatch(#{response_size := 3, payload := #{body := ~"abc"}}, ?M:decode(Type, Bytes)),
    ?assertError(_, ?M:decode(Type, <<255, 255>>)).

service_test() ->
    #{name := Name, module := Module, rpcs := Rpcs} = ?M:service(?PB, ?SERVICE, ?IMPL),
    ?assertEqual({~"grpc.testing.TestService", ?IMPL}, {Name, Module}),
    ?assertEqual(
        #{
            function => unary_call,
            kind => unary,
            input => {?PB, 'grpc.testing.SimpleRequest'},
            output => {?PB, 'grpc.testing.SimpleResponse'}
        },
        maps:get(~"UnaryCall", Rpcs)
    ),
    ?assertEqual(
        [
            {~"CacheableUnaryCall", unary},
            {~"EmptyCall", unary},
            {~"FullDuplexCall", bidi_stream},
            {~"HalfDuplexCall", bidi_stream},
            {~"StreamingInputCall", client_stream},
            {~"StreamingOutputCall", server_stream},
            {~"UnaryCall", unary},
            {~"UnimplementedCall", unary}
        ],
        lists:sort([{Method, Kind} || Method := #{kind := Kind} <- Rpcs])
    ),
    %% By its full gRPC name, the same service.
    ?assertEqual(
        ?M:service(?PB, ?SERVICE, ?IMPL), ?M:service(?PB, ~"grpc.testing.TestService", ?IMPL)
    ),
    %% The routes compile: every method's function is exported.
    ?assertMatch([_], roadrunner_grpc:routes(#{services => [?M:service(?PB, ?SERVICE, ?IMPL)]})),
    _ = roadrunner_grpc:init_route(#{service => ?M:service(?PB, ?SERVICE, ?IMPL)}).

function_names_test() ->
    #{rpcs := #{~"EmptyCall" := #{function := AsIs}}} =
        ?M:service(?PB, ?SERVICE, ?IMPL, #{function_names => as_is}),
    ?assertEqual('EmptyCall', AsIs),
    Prefixed = fun(Method) -> binary_to_atom(<<"handle_", Method/binary>>) end,
    #{rpcs := #{~"EmptyCall" := #{function := Custom}}} =
        ?M:service(?PB, ?SERVICE, ?IMPL, #{function_names => Prefixed}),
    ?assertEqual('handle_EmptyCall', Custom).

%% With `unexported => unimplemented` a method the module does not export is
%% left out, for the core to answer UNIMPLEMENTED; by default it is kept,
%% for the routes to refuse.
unexported_test() ->
    #{rpcs := Rpcs} = ?M:service(?PB, ?SERVICE, ?MODULE, #{unexported => unimplemented}),
    ?assertEqual([~"EmptyCall"], maps:keys(Rpcs)),
    #{rpcs := All} = ?M:service(?PB, ?SERVICE, ?MODULE, #{unexported => error}),
    ?assertEqual(8, map_size(All)),
    ?assertError(
        {invalid_grpc_opt, service, _},
        roadrunner_grpc:init_route(#{service => ?M:service(?PB, ?SERVICE, ?MODULE)})
    ).

%% The one TestService method here, for `unexported_test`.
empty_call(_Request, Stream) ->
    {reply, #{}, Stream}.

%% A gpb module generated without `maps` gives its methods as records.
record_rpcs_test() ->
    ?assertEqual(
        #{
            name => ~"helloworld.Greeter",
            module => ?MODULE,
            rpcs => #{
                ~"SayHello" => #{
                    function => say_hello,
                    kind => unary,
                    input => {?FAKE, 'HelloRequest'},
                    output => {?FAKE, 'HelloReply'}
                }
            }
        },
        ?M:service(?FAKE, 'Greeter', ?MODULE)
    ).

%% With `defs_as_proplists` it gives them as proplists.
proplist_rpcs_test() ->
    ?assertEqual(
        #{
            ~"SayHello" => #{
                function => say_hello,
                kind => server_stream,
                input => {?FAKE, 'HelloRequest'},
                output => {?FAKE, 'HelloReply'}
            }
        },
        maps:get(rpcs, ?M:service(?FAKE, 'ProplistGreeter', ?MODULE))
    ),
    ?assertError(
        {unsupported_gpb_rpc_format, [{name, 'SayHello'}]}, ?M:service(?FAKE, 'Partial', ?MODULE)
    ),
    ?assertError({unsupported_gpb_rpc_format, odd}, ?M:service(?FAKE, 'Odd', ?MODULE)).

%% `GetV2` and `Get_V2` are both `get_v2`: refused, as one function would
%% answer both.
duplicate_function_test() ->
    ?assertError(
        {duplicate_function, get_v2, [~"GetV2", ~"Get_V2"]},
        ?M:service(?FAKE, 'Colliding', ?MODULE)
    ),
    ?assertMatch(
        #{rpcs := #{~"GetV2" := #{function := 'GetV2'}, ~"Get_V2" := #{function := 'Get_V2'}}},
        ?M:service(?FAKE, 'Colliding', ?MODULE, #{function_names => as_is})
    ).

errors_test() ->
    ?assertError({unknown_service, ?PB, 'nope.Nope'}, ?M:service(?PB, 'nope.Nope', ?IMPL)),
    ?assertError({unknown_service, ?PB, ~"nope.Nope"}, ?M:service(?PB, ~"nope.Nope", ?IMPL)),
    ?assertError({unknown_service, ?PB, "nope.Nope"}, ?M:service(?PB, "nope.Nope", ?IMPL)),
    ?assertError(
        {invalid_grpc_protobuf_opt, function_names, camel},
        ?M:service(?PB, ?SERVICE, ?IMPL, #{function_names => camel})
    ),
    ?assertError(
        {invalid_grpc_protobuf_opt, unexported, skip},
        ?M:service(?PB, ?SERVICE, ?IMPL, #{unexported => skip})
    ),
    ?assertError({unknown_grpc_protobuf_opt, nope}, ?M:service(?PB, ?SERVICE, ?IMPL, #{nope => 1})),
    ?assertError({invalid_grpc_protobuf_opts, [x]}, ?M:service(?PB, ?SERVICE, ?IMPL, [x])).

%% A module that does not load, or is not a gpb module with services, by
%% the service's gpb name or its full gRPC name.
invalid_gpb_module_test() ->
    lists:foreach(
        fun(GpbModule) ->
            ?assertError({invalid_gpb_module, GpbModule}, ?M:service(GpbModule, ?SERVICE, ?IMPL)),
            ?assertError(
                {invalid_gpb_module, GpbModule},
                ?M:service(GpbModule, ~"grpc.testing.TestService", ?IMPL)
            )
        end,
        [no_such_pb, lists, "pb"]
    ).

invalid_module_test() ->
    ?assertError({invalid_module, "impl"}, ?M:service(?PB, ?SERVICE, "impl")).

snake_case_test() ->
    lists:foreach(
        fun({In, Out}) -> ?assertEqual(Out, ?M:snake_case(In)) end,
        [
            {"SayHello", "say_hello"},
            {"EmptyCall", "empty_call"},
            {"HTTPGet", "http_get"},
            {"GetHTTP", "get_http"},
            {"GetV2", "get_v2"},
            {"V2Get", "v2_get"},
            {"already_snake", "already_snake"},
            {"lowerThenUpper", "lower_then_upper"},
            {"A", "a"},
            {"", ""}
        ]
    ).

%% With gpb's `descriptor` option the service gives the gpb module's files,
%% each one another imports named as the import names it, one none imports
%% keeping gpb's name (its package's path), the rest as gpb wrote it, but
%% for map entries; without the option, none.
files_test() ->
    #{files := PbFiles} = ?M:service(?PB, ?SERVICE, ?IMPL),
    [Test, Empty, Messages] =
        Decoded = [
            gpb_descriptor:decode_msg(File, 'FileDescriptorProto')
         || File <- PbFiles
        ],
    ?assertEqual(
        [
            {"grpc/testing/test.proto", ["empty.proto", "messages.proto"]},
            {"empty.proto", []},
            {"messages.proto", []}
        ],
        [{Name, Deps} || #'FileDescriptorProto'{name = Name, dependency = Deps} <- Decoded]
    ),
    ?assertEqual([Test, Empty], [
        (gpb_descriptor:decode_msg(?PB:descriptor(Proto), 'FileDescriptorProto'))#'FileDescriptorProto'{
            name = Name
        }
     || {Proto, Name} <- [{"test", "grpc/testing/test.proto"}, {"empty", "empty.proto"}]
    ]),
    ?assertEqual(
        (gpb_descriptor:decode_msg(?PB:descriptor("messages"), 'FileDescriptorProto'))#'FileDescriptorProto'.package,
        Messages#'FileDescriptorProto'.package
    ),
    ?assertNot(is_map_key(files, ?M:service(?FAKE, 'Greeter', ?MODULE))),
    %% An import by a path is the name its file goes by; the other fields
    %% stay as they were.
    #{files := [Greeter, Imported]} = ?M:service(
        roadrunner_grpc_protobuf_fake_descr_pb, 'Greeter', ?MODULE
    ),
    Import = roadrunner_grpc_protobuf_fake_descr_pb:import(),
    ?assertEqual(<<10, 17, "pkg/greeter.proto", 26, 130, 1, Import/binary, 80, 0>>, Greeter),
    #'FileDescriptorProto'{name = ImportName, message_type = [Holder]} = gpb_descriptor:decode_msg(
        Imported, 'FileDescriptorProto'
    ),
    ?assertEqual(binary_to_list(Import), ImportName),
    %% A field name that starts with a capital, or a digit after `_`, keeps
    %% it as protoc does; a group's field takes its message's name
    %% lowercased.
    ?assertMatch(
        #'DescriptorProto'{
            name = "Holder",
            field = [
                #'FieldDescriptorProto'{
                    name = "Labels_2x",
                    label = 'LABEL_REPEATED',
                    type_name = ".pkg.Holder.Labels2xEntry"
                },
                #'FieldDescriptorProto'{name = "plain"},
                #'FieldDescriptorProto'{
                    name = "mygroup",
                    json_name = undefined,
                    type = 'TYPE_GROUP',
                    type_name = ".pkg.Holder.MyGroup"
                }
            ],
            nested_type = [
                #'DescriptorProto'{name = "MyGroup"},
                #'DescriptorProto'{
                    name = "Labels2xEntry",
                    field = [
                        #'FieldDescriptorProto'{
                            name = "key", number = 1, label = 'LABEL_OPTIONAL', type = 'TYPE_STRING'
                        },
                        #'FieldDescriptorProto'{
                            name = "value",
                            number = 2,
                            label = 'LABEL_OPTIONAL',
                            type = 'TYPE_INT32'
                        }
                    ],
                    options = #'MessageOptions'{map_entry = true}
                }
            ]
        },
        Holder
    ).

%% gpb declares map entries at the top of the file, shared by every map
%% field of the same key and value types; each map field gets its own,
%% nested in its message and named after it as protoc names it
%% (`rpcs_by_peer` has `RpcsByPeerEntry`), its key and value optional, the
%% field's `type_name` naming it. messages.proto has `map<string, int32>`
%% and `map<string, Message>` fields, in a message and in a nested one.
map_entries_test() ->
    #{files := [_, _, File]} = ?M:service(?PB, ?SERVICE, ?IMPL),
    #'FileDescriptorProto'{message_type = Messages} = gpb_descriptor:decode_msg(
        File, 'FileDescriptorProto'
    ),
    ?assertEqual(
        [],
        [Name || #'DescriptorProto'{name = Name} <- Messages, lists:prefix("MapFieldEntry", Name)]
    ),
    [Stats] = [M || #'DescriptorProto'{name = "LoadBalancerStatsResponse"} = M <- Messages],
    #'DescriptorProto'{field = Fields, nested_type = Nested} = Stats,
    Prefix = ".grpc.testing.LoadBalancerStatsResponse.",
    ?assertEqual(
        [
            {"rpcs_by_peer", 'LABEL_REPEATED', Prefix ++ "RpcsByPeerEntry"},
            {"num_failures", 'LABEL_OPTIONAL', undefined},
            {"rpcs_by_method", 'LABEL_REPEATED', Prefix ++ "RpcsByMethodEntry"},
            {"metadatas_by_peer", 'LABEL_REPEATED', Prefix ++ "MetadatasByPeerEntry"}
        ],
        [
            {Name, Label, TypeName}
         || #'FieldDescriptorProto'{name = Name, label = Label, type_name = TypeName} <- Fields
        ]
    ),
    Entry = fun(Name) ->
        [E] = [E || #'DescriptorProto'{name = N} = E <- Nested, N =:= Name],
        #'DescriptorProto'{field = EntryFields, options = #'MessageOptions'{map_entry = true}} = E,
        [
            {N, Number, Label, Type, TypeName}
         || #'FieldDescriptorProto'{
                name = N, number = Number, label = Label, type = Type, type_name = TypeName
            } <- EntryFields
        ]
    end,
    Key = {"key", 1, 'LABEL_OPTIONAL', 'TYPE_STRING', undefined},
    ?assertEqual(
        [Key, {"value", 2, 'LABEL_OPTIONAL', 'TYPE_INT32', undefined}], Entry("RpcsByPeerEntry")
    ),
    ?assertEqual(
        [Key, {"value", 2, 'LABEL_OPTIONAL', 'TYPE_MESSAGE', Prefix ++ "RpcsByPeer"}],
        Entry("RpcsByMethodEntry")
    ),
    %% The nested message's map field gets an entry of its own.
    [#'DescriptorProto'{field = [ByPeer], nested_type = [ByPeerEntry]}] = [
        M
     || #'DescriptorProto'{name = "RpcsByPeer"} = M <- Nested
    ],
    ?assertEqual(Prefix ++ "RpcsByPeer.RpcsByPeerEntry", ByPeer#'FieldDescriptorProto'.type_name),
    ?assertEqual("RpcsByPeerEntry", ByPeerEntry#'DescriptorProto'.name).

%% The files of roadrunner's own services, written by hand in the core,
%% read by gpb's descriptor module as gRPC's .proto files declare them.
builtin_files_test() ->
    Health = gpb_descriptor:decode_msg(
        roadrunner_grpc_descriptor:health(), 'FileDescriptorProto'
    ),
    ?assertMatch(
        #'FileDescriptorProto'{
            name = "grpc/health/v1/health.proto",
            package = "grpc.health.v1",
            dependency = [],
            syntax = "proto3",
            options = #'FileOptions'{
                java_package = "io.grpc.health.v1",
                java_outer_classname = "HealthProto",
                java_multiple_files = true,
                go_package = "google.golang.org/grpc/health/grpc_health_v1",
                objc_class_prefix = "GrpcHealthV1",
                csharp_namespace = "Grpc.Health.V1"
            }
        },
        Health
    ),
    H = ".grpc.health.v1.",
    ?assertEqual(
        [
            {"HealthCheckRequest", [{"service", 1, 'LABEL_OPTIONAL', 'TYPE_STRING', undefined}], [],
                [], []},
            {"HealthCheckResponse",
                [
                    {"status", 1, 'LABEL_OPTIONAL', 'TYPE_ENUM',
                        H ++ "HealthCheckResponse.ServingStatus"}
                ],
                [],
                [
                    {"ServingStatus", [
                        {"UNKNOWN", 0}, {"SERVING", 1}, {"NOT_SERVING", 2}, {"SERVICE_UNKNOWN", 3}
                    ]}
                ],
                []},
            {"HealthListRequest", [], [], [], []},
            {"HealthListResponse",
                [
                    {"statuses", 1, 'LABEL_REPEATED', 'TYPE_MESSAGE',
                        H ++ "HealthListResponse.StatusesEntry"}
                ],
                [
                    {"StatusesEntry",
                        [
                            {"key", 1, 'LABEL_OPTIONAL', 'TYPE_STRING', undefined},
                            {"value", 2, 'LABEL_OPTIONAL', 'TYPE_MESSAGE',
                                H ++ "HealthCheckResponse"}
                        ],
                        [], [], [], true}
                ],
                [], []}
        ],
        [message(M) || M <- Health#'FileDescriptorProto'.message_type]
    ),
    ?assertEqual(
        [
            {"Health", [
                {"Check", H ++ "HealthCheckRequest", H ++ "HealthCheckResponse", false, false},
                {"List", H ++ "HealthListRequest", H ++ "HealthListResponse", false, false},
                {"Watch", H ++ "HealthCheckRequest", H ++ "HealthCheckResponse", false, true}
            ]}
        ],
        [service(S) || S <- Health#'FileDescriptorProto'.service]
    ),
    lists:foreach(fun reflection_file/1, [~"v1", ~"v1alpha"]).

reflection_file(Version) ->
    V = binary_to_list(Version),
    File = gpb_descriptor:decode_msg(
        roadrunner_grpc_descriptor:reflection(Version), 'FileDescriptorProto'
    ),
    P = ".grpc.reflection." ++ V ++ ".",
    #'FileDescriptorProto'{
        name = Name,
        package = Package,
        dependency = [],
        syntax = "proto3",
        options = #'FileOptions'{
            java_package = JavaPackage,
            java_outer_classname = "ServerReflectionProto",
            java_multiple_files = true,
            go_package = GoPackage,
            deprecated = Deprecated
        }
    } = File,
    ?assertEqual(
        {
            "grpc/reflection/" ++ V ++ "/reflection.proto",
            "grpc.reflection." ++ V,
            "io.grpc.reflection." ++ V,
            "google.golang.org/grpc/reflection/grpc_reflection_" ++ V,
            V =:= "v1alpha"
        },
        {Name, Package, JavaPackage, GoPackage, Deprecated =:= true}
    ),
    S = 'TYPE_STRING',
    O = 'LABEL_OPTIONAL',
    M = 'TYPE_MESSAGE',
    ?assertEqual(
        [
            {"ServerReflectionRequest",
                [
                    {"host", 1, O, S, undefined},
                    {"file_by_filename", 3, O, S, undefined, 0},
                    {"file_containing_symbol", 4, O, S, undefined, 0},
                    {"file_containing_extension", 5, O, M, P ++ "ExtensionRequest", 0},
                    {"all_extension_numbers_of_type", 6, O, S, undefined, 0},
                    {"list_services", 7, O, S, undefined, 0}
                ],
                [], [], ["message_request"]},
            {"ExtensionRequest",
                [
                    {"containing_type", 1, O, S, undefined},
                    {"extension_number", 2, O, 'TYPE_INT32', undefined}
                ],
                [], [], []},
            {"ServerReflectionResponse",
                [
                    {"valid_host", 1, O, S, undefined},
                    {"original_request", 2, O, M, P ++ "ServerReflectionRequest"},
                    {"file_descriptor_response", 4, O, M, P ++ "FileDescriptorResponse", 0},
                    {"all_extension_numbers_response", 5, O, M, P ++ "ExtensionNumberResponse", 0},
                    {"list_services_response", 6, O, M, P ++ "ListServiceResponse", 0},
                    {"error_response", 7, O, M, P ++ "ErrorResponse", 0}
                ],
                [], [], ["message_response"]},
            {"FileDescriptorResponse",
                [{"file_descriptor_proto", 1, 'LABEL_REPEATED', 'TYPE_BYTES', undefined}], [], [],
                []},
            {"ExtensionNumberResponse",
                [
                    {"base_type_name", 1, O, S, undefined},
                    {"extension_number", 2, 'LABEL_REPEATED', 'TYPE_INT32', undefined}
                ],
                [], [], []},
            {"ListServiceResponse", [{"service", 1, 'LABEL_REPEATED', M, P ++ "ServiceResponse"}],
                [], [], []},
            {"ServiceResponse", [{"name", 1, O, S, undefined}], [], [], []},
            {"ErrorResponse",
                [
                    {"error_code", 1, O, 'TYPE_INT32', undefined},
                    {"error_message", 2, O, S, undefined}
                ],
                [], [], []}
        ],
        [message(Message) || Message <- File#'FileDescriptorProto'.message_type]
    ),
    ?assertEqual(
        [
            {"ServerReflection", [
                {"ServerReflectionInfo", P ++ "ServerReflectionRequest",
                    P ++ "ServerReflectionResponse", true, true}
            ]}
        ],
        [service(Service) || Service <- File#'FileDescriptorProto'.service]
    ),
    %% protoc's JSON names.
    [#'DescriptorProto'{field = [_, ByFilename | _]} | _] = File#'FileDescriptorProto'.message_type,
    ?assertEqual("fileByFilename", ByFilename#'FieldDescriptorProto'.json_name).

%% A message as `{Name, Fields, Nested, Enums, Oneofs}`, a map entry with
%% `true` after; a field `{Name, Number, Label, Type, TypeName}`, its oneof's
%% index after when in one.
message(#'DescriptorProto'{
    name = Name,
    field = Fields,
    nested_type = Nested,
    enum_type = Enums,
    oneof_decl = Oneofs,
    options = Options
}) ->
    Message = {
        Name,
        [field(F) || F <- Fields],
        [message(N) || N <- Nested],
        [
            {EnumName, [{V, N} || #'EnumValueDescriptorProto'{name = V, number = N} <- Values]}
         || #'EnumDescriptorProto'{name = EnumName, value = Values} <- Enums
        ],
        [OneofName || #'OneofDescriptorProto'{name = OneofName} <- Oneofs]
    },
    case Options of
        #'MessageOptions'{map_entry = true} -> erlang:append_element(Message, true);
        undefined -> Message
    end.

field(#'FieldDescriptorProto'{
    name = Name,
    number = Number,
    label = Label,
    type = Type,
    type_name = TypeName,
    oneof_index = Oneof
}) ->
    case Oneof of
        undefined -> {Name, Number, Label, Type, TypeName};
        _ -> {Name, Number, Label, Type, TypeName, Oneof}
    end.

service(#'ServiceDescriptorProto'{name = Name, method = Methods}) ->
    {Name, [
        {M, In, Out, ClientStreaming =:= true, ServerStreaming =:= true}
     || #'MethodDescriptorProto'{
            name = M,
            input_type = In,
            output_type = Out,
            client_streaming = ClientStreaming,
            server_streaming = ServerStreaming
        } <- Methods
    ]}.
