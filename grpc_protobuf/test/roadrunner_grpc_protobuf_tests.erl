-module(roadrunner_grpc_protobuf_tests).

-include_lib("eunit/include/eunit.hrl").

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
