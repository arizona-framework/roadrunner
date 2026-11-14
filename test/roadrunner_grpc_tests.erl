-module(roadrunner_grpc_tests).

-include_lib("eunit/include/eunit.hrl").

-export([subtype/0]).

-define(M, roadrunner_grpc).
-define(SVC, roadrunner_grpc_test_service).

routes_test() ->
    ?assertEqual(
        [
            #{
                path => ~"/test.Echo/:method",
                handler => ?M,
                state => #{service => ?SVC, max_message_size => 9}
            }
        ],
        ?M:routes(#{services => [?SVC], max_message_size => 9})
    ),
    ?assertMatch(
        [#{max_content_length := 5, state := #{service := ?SVC}}],
        ?M:routes(#{services => [?SVC], max_content_length => 5})
    ),
    ?assertError({invalid_grpc_opts, #{}}, ?M:routes(#{})),
    ?assertError({invalid_grpc_opts, #{services := x}}, ?M:routes(#{services => x})),
    ?assertError({invalid_grpc_opt, services, [nope]}, ?M:routes(#{services => [nope]})),
    ?assertError({invalid_grpc_opt, services, ["x"]}, ?M:routes(#{services => ["x"]})).

%% A codec module that does not exist, and a service whose rpcs/0 is not a
%% map, are refused.
init_route_missing_codec_and_bad_rpcs_test() ->
    ?assertError(
        {invalid_grpc_opt, codecs, [nope]}, ?M:init_route(#{service => ?SVC, codecs => [nope]})
    ),
    {module, _} = code:ensure_loaded(roadrunner_grpc_nomap_service),
    ?assertError(
        {invalid_grpc_opt, service, {roadrunner_grpc_nomap_service, []}},
        ?M:init_route(#{service => roadrunner_grpc_nomap_service})
    ).

init_route_test() ->
    _ = ?M:init_route(#{service => ?SVC}),
    _ = ?M:init_route(#{service => ?SVC, send_compression => gzip}),
    ?assertError(
        {invalid_grpc_opt, send_compression, brotli},
        ?M:init_route(#{service => ?SVC, send_compression => brotli})
    ),
    _ = ?M:init_route(#{
        service => ?SVC, codecs => [roadrunner_grpc_test_codec], max_message_size => 1
    }).

init_route_errors_test() ->
    ?assertError({unknown_grpc_opt, nope}, ?M:init_route(#{service => ?SVC, nope => 1})),
    ?assertError({invalid_grpc_opt, service, "x"}, ?M:init_route(#{service => "x"})),
    ?assertError({invalid_grpc_opts, #{}}, ?M:init_route(#{})),
    ?assertError({invalid_grpc_opts, x}, ?M:init_route(x)),
    ?assertError({invalid_grpc_opt, codecs, []}, ?M:init_route(#{service => ?SVC, codecs => []})),
    ?assertError(
        {invalid_grpc_opt, codecs, ["c"]}, ?M:init_route(#{service => ?SVC, codecs => ["c"]})
    ),
    ?assertError(
        {invalid_grpc_opt, max_message_size, 0},
        ?M:init_route(#{service => ?SVC, max_message_size => 0})
    ),
    ?assertError(
        {invalid_grpc_opt, service, no_such_module}, ?M:init_route(#{service => no_such_module})
    ),
    Raw = roadrunner_grpc_codec_raw,
    ?assertError(
        {invalid_grpc_opt, codecs, [Raw, Raw]},
        ?M:init_route(#{service => ?SVC, codecs => [Raw, Raw]})
    ),
    ?assertError(
        {invalid_grpc_opt, codecs, [?MODULE]},
        ?M:init_route(#{service => ?SVC, codecs => [?MODULE]})
    ).

%% Used as a codec whose subtype is not a binary.
subtype() -> proto.

%% A method declared without a function, or with an unknown kind, is refused.
init_route_bad_rpc_test() ->
    {module, _} = code:ensure_loaded(roadrunner_grpc_bad_service),
    ?assertError(
        {invalid_grpc_opt, service, {roadrunner_grpc_bad_service, ~"Bad", #{kind := sideways}}},
        ?M:init_route(#{service => roadrunner_grpc_bad_service})
    ),
    %% A method whose function the service does not export.
    {module, _} = code:ensure_loaded(roadrunner_grpc_unexported_service),
    ?assertError(
        {invalid_grpc_opt, service, {roadrunner_grpc_unexported_service, ~"Gone", _}},
        ?M:init_route(#{service => roadrunner_grpc_unexported_service})
    ).
