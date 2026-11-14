-module(roadrunner_grpc_reflection_SUITE).
-moduledoc """
gRPC's server reflection (`roadrunner_grpc_reflection`) over HTTP/2:
`ServerReflectionInfo` on `v1` and `v1alpha`, answering from the
FileDescriptorProtos in `roadrunner_grpc_reflection_test_files`.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2, init_per_testcase/2, end_per_testcase/2]).
-export([
    list_services/1,
    file_containing_symbol/1,
    file_by_filename/1,
    file_containing_extension/1,
    all_extension_numbers_of_type/1,
    not_found/1,
    no_request/1,
    builtin_files/1,
    requests_on_one_stream/1,
    malformed_request_is_internal/1
]).

-define(F, roadrunner_grpc_reflection_test_files).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [{group, v1}, {group, v1alpha}].

groups() ->
    Cases = [
        list_services,
        file_containing_symbol,
        file_by_filename,
        file_containing_extension,
        all_extension_numbers_of_type,
        not_found,
        no_request,
        builtin_files,
        requests_on_one_stream,
        malformed_request_is_internal
    ],
    [{v1, [], Cases}, {v1alpha, [], Cases}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(roadrunner),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(Version, Config) ->
    [
        {path,
            <<"/grpc.reflection.", (atom_to_binary(Version))/binary,
                ".ServerReflection/ServerReflectionInfo">>}
        | Config
    ].

end_per_group(_Version, _Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    {ok, _} = roadrunner_listener:start_link(?MODULE, #{
        port => 0,
        protocols => [http2],
        body_buffering => manual,
        routes => roadrunner_grpc:routes(#{
            services => [
                %% A module whose files/0 gives `base.proto` and `dep.proto`.
                roadrunner_grpc_test_service,
                %% A descriptor with `ext.proto`, a `base.proto` of its own,
                %% which the first one given shadows, and two files that
                %% declare the same message.
                #{
                    name => ~"test.Runtime",
                    module => roadrunner_grpc_test_service,
                    rpcs => #{},
                    files => [
                        ?F:ext(),
                        ?F:file_named(~"base.proto"),
                        ?F:file_named(~"other.proto"),
                        ?F:file_named(~"again.proto")
                    ]
                },
                %% A descriptor without files.
                #{name => ~"test.Bare", module => roadrunner_grpc_test_service, rpcs => #{}}
            ],
            health => true,
            reflection => true
        })
    }),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_listener:stop(?MODULE).

%% The services whose files declare them, the health service and
%% reflection's own two among them: `test.Runtime`, whose files do not
%% declare it, and `test.Bare`, with none, are left out, so a tool can
%% describe each one listed. The request's host and the request itself
%% come back.
list_services(Config) ->
    Request = request(~"example.org", ?F:field(7, ~"*")),
    [Response] = info(Config, [Request]),
    ?assertEqual([~"example.org"], ?F:values(1, Response)),
    ?assertEqual([Request], ?F:values(2, Response)),
    [List] = ?F:values(6, Response),
    ?assertEqual(
        [
            ~"test.Echo",
            ~"grpc.health.v1.Health",
            ~"grpc.reflection.v1.ServerReflection",
            ~"grpc.reflection.v1alpha.ServerReflection"
        ],
        [Name || Service <- ?F:values(1, ?F:fields(List)), {1, Name} <- ?F:fields(Service)]
    ).

%% A service, a method, a message, a nested message, a field, a oneof, an
%% enum, an enum value (named next to its enum) and an extension each
%% answer their file and its imports; an import no service gave is left
%% out.
file_containing_symbol(Config) ->
    Base = [?F:base(), ?F:dep()],
    Dep = [?F:dep()],
    lists:foreach(
        fun({Symbol, Files}) ->
            ?assertEqual({Symbol, Files}, {Symbol, files(Config, ?F:field(4, Symbol))})
        end,
        [
            {~"test.Echo", Base},
            {~"test.Echo.Unary", Base},
            {~"test.Msg", Base},
            {~"test.Msg.Inner", Base},
            {~"test.Msg.id", Base},
            {~"test.Msg.choice", Base},
            {~"test.Msg.Kind", Base},
            {~"test.Msg.KIND_A", Base},
            {~"test.Msg.inner_ext", Base},
            {~"test.ext", Base},
            {~"test.dep.Dep", Dep},
            {~"test.dep.Dep.id", Dep},
            {~"test.dep.Color", Dep},
            {~"test.dep.RED", Dep},
            {~"Top", [?F:ext(), ?F:base(), ?F:dep()]},
            {~"more", [?F:ext(), ?F:base(), ?F:dep()]},
            %% Declared in two files: the first one given.
            {~"Shadowed", [?F:file_named(~"other.proto")]}
        ]
    ).

%% A file and its imports all the way down.
file_by_filename(Config) ->
    ?assertEqual([?F:ext(), ?F:base(), ?F:dep()], files(Config, ?F:field(3, ~"ext.proto"))),
    ?assertEqual([?F:dep()], files(Config, ?F:field(3, ~"dep.proto"))).

file_containing_extension(Config) ->
    ?assertEqual([?F:base(), ?F:dep()], files(Config, extension(~"test.Msg", 100))),
    ?assertEqual([?F:base(), ?F:dep()], files(Config, extension(~"test.Msg", 101))),
    ?assertEqual([?F:ext(), ?F:base(), ?F:dep()], files(Config, extension(~"test.Msg", 200))).

all_extension_numbers_of_type(Config) ->
    [Response] = info(Config, [request(<<>>, ?F:field(6, ~"test.Msg"))]),
    [Numbers] = ?F:values(5, Response),
    Fields = ?F:fields(Numbers),
    ?assertEqual([~"test.Msg"], ?F:values(1, Fields)),
    [Packed] = ?F:values(2, Fields),
    ?assertEqual(<<100, 101, 200, 1>>, Packed),
    %% A message no extension extends has none: the field is left out.
    [None] = info(Config, [request(<<>>, ?F:field(6, ~"test.dep.Dep"))]),
    [NoNumbers] = ?F:values(5, None),
    ?assertEqual([{1, ~"test.dep.Dep"}], ?F:fields(NoNumbers)).

%% What reflection does not know is NOT_FOUND, the names of a service
%% that gives no files among it; the host stays out when the request has
%% none.
not_found(Config) ->
    Requests = [
        ?F:field(3, ~"missing.proto"),
        ?F:field(4, ~"test.Nope"),
        ?F:field(4, ~"test.Bare"),
        extension(~"test.Msg", 7),
        ?F:field(6, ~"test.Nope")
    ],
    Responses = info(Config, [request(<<>>, Request) || Request <- Requests]),
    ?assertEqual(length(Requests), length(Responses)),
    lists:foreach(
        fun(Response) ->
            ?assertEqual([], ?F:values(1, Response)),
            [Error] = ?F:values(7, Response),
            ?assertMatch([{1, 5}, {2, <<"unknown ", _/binary>>}], ?F:fields(Error))
        end,
        Responses
    ).

%% The health service and reflection describe themselves with gRPC's own
%% files, by their names and by the files' names.
builtin_files(Config) ->
    Health = [roadrunner_grpc_descriptor:health()],
    V1 = [roadrunner_grpc_descriptor:reflection(~"v1")],
    V1Alpha = [roadrunner_grpc_descriptor:reflection(~"v1alpha")],
    lists:foreach(
        fun({Query, Files}) -> ?assertEqual({Query, Files}, {Query, files(Config, Query)}) end,
        [
            {?F:field(4, ~"grpc.health.v1.Health"), Health},
            {?F:field(4, ~"grpc.health.v1.Health.Watch"), Health},
            {?F:field(4, ~"grpc.health.v1.HealthCheckResponse.SERVING"), Health},
            {?F:field(3, ~"grpc/health/v1/health.proto"), Health},
            {?F:field(4, ~"grpc.reflection.v1.ServerReflection"), V1},
            {?F:field(4, ~"grpc.reflection.v1.ServerReflectionRequest"), V1},
            {?F:field(3, ~"grpc/reflection/v1/reflection.proto"), V1},
            {?F:field(4, ~"grpc.reflection.v1alpha.ServerReflection.ServerReflectionInfo"), V1Alpha}
        ]
    ).

%% A request with nothing asked is INVALID_ARGUMENT.
no_request(Config) ->
    [Response] = info(Config, [request(~"h", [])]),
    [Error] = ?F:values(7, Response),
    ?assertMatch([{1, 3}, {2, _}], ?F:fields(Error)).

%% One stream answers each request in turn, and does not send again a file
%% it sent as an import; the file asked for it always sends.
requests_on_one_stream(Config) ->
    Responses = info(Config, [
        request(<<>>, ?F:field(4, ~"test.Msg")),
        request(<<>>, ?F:field(3, ~"ext.proto")),
        request(<<>>, ?F:field(3, ~"base.proto")),
        request(<<>>, ?F:field(7, <<>>))
    ]),
    ?assertMatch(
        [[_, _], [_], [_], []],
        [
            case ?F:values(4, Response) of
                [Files] -> ?F:values(1, ?F:fields(Files));
                [] -> []
            end
         || Response <- Responses
        ]
    ),
    [[Msg], [Ext], [Base], _] = [?F:values(4, Response) || Response <- Responses],
    ?assertEqual([?F:base(), ?F:dep()], ?F:values(1, ?F:fields(Msg))),
    ?assertEqual([?F:ext()], ?F:values(1, ?F:fields(Ext))),
    ?assertEqual([?F:base()], ?F:values(1, ?F:fields(Base))).

malformed_request_is_internal(Config) ->
    C = roadrunner_grpc_test_client:open(?config(port, Config)),
    {Headers, [], trailers_only, _} = roadrunner_grpc_test_client:call(
        C, 1, ?config(path, Config), [<<10, 9, "ab">>]
    ),
    ?assertEqual(~"13", proplists:get_value(~"grpc-status", Headers)).

%% --- helpers ---

request(Host, Query) ->
    iolist_to_binary([
        case Host of
            <<>> -> [];
            _ -> ?F:field(1, Host)
        end,
        Query
    ]).

extension(Type, Number) ->
    ?F:field(5, [?F:field(1, Type), ?F:varint_field(2, Number)]).

%% The files one request's answer holds.
files(Config, Query) ->
    [Response] = info(Config, [request(<<>>, Query)]),
    [Files] = ?F:values(4, Response),
    ?F:values(1, ?F:fields(Files)).

%% The responses to the requests, sent on one stream, each read as its
%% fields; the call ends OK.
info(Config, Requests) ->
    C = roadrunner_grpc_test_client:open(?config(port, Config)),
    {_Headers, Messages, Trailers, _} = roadrunner_grpc_test_client:call(
        C, 1, ?config(path, Config), Requests
    ),
    ?assertEqual(~"0", proplists:get_value(~"grpc-status", Trailers)),
    [?F:fields(Message) || Message <- Messages].
