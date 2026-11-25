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
                methods => [~"POST"],
                max_content_length => infinity,
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
    ?assertError({invalid_grpc_opt, services, ["x"]}, ?M:routes(#{services => ["x"]})),
    ?assertMatch(
        [#{path := ~"/test.Runtime/:method", state := #{service := #{module := ?SVC}}}],
        ?M:routes(#{services => [descriptor()]})
    ),
    Unnamed = maps:remove(name, descriptor()),
    ?assertError({invalid_grpc_opt, services, [Unnamed]}, ?M:routes(#{services => [Unnamed]})),
    Extra = (descriptor())#{nope => 1},
    ?assertError({invalid_grpc_opt, services, [Extra]}, ?M:routes(#{services => [Extra]})).

descriptor() ->
    #{
        name => ~"test.Runtime",
        module => ?SVC,
        rpcs => #{~"Echo" => #{function => unary, kind => unary, input => in, output => out}}
    }.

%% A descriptor's methods are checked against its module like a service
%% module's; a descriptor without a name, with a key it does not know, with
%% a module that does not exist or with methods that are not a map is
%% refused.
init_route_descriptor_test() ->
    _ = ?M:init_route(#{service => descriptor()}),
    Unnamed = maps:remove(name, descriptor()),
    ?assertError({invalid_grpc_opt, service, Unnamed}, ?M:init_route(#{service => Unnamed})),
    Extra = (descriptor())#{nope => 1},
    ?assertError({invalid_grpc_opt, service, Extra}, ?M:init_route(#{service => Extra})),
    Missing = (descriptor())#{module := no_such_module},
    ?assertError({invalid_grpc_opt, service, Missing}, ?M:init_route(#{service => Missing})),
    ?assertError(
        {invalid_grpc_opt, service, {?SVC, []}},
        ?M:init_route(#{service => (descriptor())#{rpcs := []}})
    ),
    ?assertError(
        {invalid_grpc_opt, service, {?SVC, ~"Echo", _}},
        ?M:init_route(#{
            service => (descriptor())#{
                rpcs := #{~"Echo" => #{function => nope, kind => unary, input => in, output => out}}
            }
        })
    ).

%% `health => true` adds the health service's route, with no codecs of
%% the services' own; `false`, the default, none.
routes_health_test() ->
    ?assertEqual(
        [
            #{
                path => ~"/grpc.health.v1.Health/:method",
                handler => ?M,
                methods => [~"POST"],
                state => #{service => roadrunner_grpc_health}
            }
        ],
        ?M:routes(#{services => [], health => true})
    ),
    ?assertEqual([], ?M:routes(#{services => [], health => false})),
    ?assertError({invalid_grpc_opt, health, yes}, ?M:routes(#{services => [], health => yes})).

%% `reflection => true` adds reflection's two routes, after the health
%% service's, each answering from every service, the health service and
%% its own among them; `false`, the default, none.
routes_reflection_test() ->
    [V1, V1Alpha] = Own = roadrunner_grpc_reflection:services(),
    Described = [?SVC, roadrunner_grpc_health | Own],
    ?assertMatch(
        [
            #{state := #{service := roadrunner_grpc_health}},
            #{
                path := ~"/grpc.reflection.v1.ServerReflection/:method",
                handler := ?M,
                state := #{service := V1, reflection := Described}
            },
            #{
                path := ~"/grpc.reflection.v1alpha.ServerReflection/:method",
                state := #{service := V1Alpha, reflection := Described}
            },
            #{state := #{service := ?SVC}}
        ],
        ?M:routes(#{services => [?SVC], health => true, reflection => true})
    ),
    ?assertMatch(
        [_, _], ?M:routes(#{services => [], reflection => true})
    ),
    ?assertEqual([], ?M:routes(#{services => [], reflection => false})),
    ?assertError(
        {invalid_grpc_opt, reflection, yes}, ?M:routes(#{services => [], reflection => yes})
    ),
    %% The routes compile, the index built from the services' files.
    _ = [
        ?M:init_route(State)
     || #{state := State} <- ?M:routes(#{services => [?SVC], health => true, reflection => true})
    ],
    ok.

%% A descriptor's `files` are FileDescriptorProtos: not a list of binaries,
%% the routes refuse it; bytes that do not read as one, the reflection
%% route does. A reflection route's services that are not a list, it
%% refuses too.
reflection_files_test() ->
    WithFiles = (descriptor())#{files => [roadrunner_grpc_reflection_test_files:ext()]},
    ?assertMatch([_], ?M:routes(#{services => [WithFiles]})),
    _ = ?M:init_route(#{service => WithFiles}),
    NotList = (descriptor())#{files => x},
    ?assertError({invalid_grpc_opt, services, [NotList]}, ?M:routes(#{services => [NotList]})),
    ?assertError({invalid_grpc_opt, service, NotList}, ?M:init_route(#{service => NotList})),
    NotBinaries = (descriptor())#{files => [x]},
    ?assertError(
        {invalid_grpc_opt, services, [NotBinaries]}, ?M:routes(#{services => [NotBinaries]})
    ),
    Malformed = (descriptor())#{files => [<<10, 9, "ab">>]},
    [Own | _] = roadrunner_grpc_reflection:services(),
    ?assertError(
        {invalid_grpc_opt, service, Malformed},
        ?M:init_route(#{service => Own, reflection => [Malformed]})
    ),
    ?assertError(
        {invalid_grpc_opt, reflection, true}, ?M:init_route(#{service => Own, reflection => true})
    ),
    %% A service module without files/0 gives none.
    _ = ?M:init_route(#{service => Own, reflection => [roadrunner_grpc_unexported_service]}),
    ok.

%% A codec module that does not exist, a service whose rpcs/0 is not a map,
%% and a module with no name/0, are refused.
init_route_missing_codec_and_bad_rpcs_test() ->
    ?assertError({invalid_grpc_opt, service, lists}, ?M:init_route(#{service => lists})),
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

%% `middlewares` go on every route, the health and reflection ones among
%% them; one that is not a list is refused.
routes_middlewares_test() ->
    Mws = [roadrunner_compress],
    Routes = ?M:routes(#{
        services => [?SVC],
        health => true,
        reflection => true,
        middlewares => Mws,
        max_content_length => 7
    }),
    ?assertMatch(
        [
            #{middlewares := Mws, state := #{service := roadrunner_grpc_health}},
            #{middlewares := Mws},
            #{middlewares := Mws},
            #{middlewares := Mws, max_content_length := 7, state := #{service := ?SVC}}
        ],
        Routes
    ),
    [#{state := State} | _] = lists:reverse(Routes),
    ?assertNot(is_map_key(middlewares, State)),
    ?assertError(
        {invalid_grpc_opt, middlewares, x}, ?M:routes(#{services => [?SVC], middlewares => x})
    ).

%% A ceiling goes on each service's route, never on the health and
%% reflection ones, and stays out of the state.
routes_ceiling_test() ->
    Mode = {queue, #{max_queued => 4}},
    Routes = ?M:routes(#{
        services => [?SVC],
        health => true,
        reflection => true,
        max_concurrent_requests => 8,
        overload_mode => Mode
    }),
    [Service | Others] = lists:reverse(Routes),
    ?assertMatch(
        #{max_concurrent_requests := 8, overload_mode := Mode, state := #{service := ?SVC}},
        Service
    ),
    ?assertEqual(3, length(Others)),
    [
        ?assertNot(is_map_key(K, R))
     || R <- Others, K <- [max_concurrent_requests, overload_mode]
    ],
    #{state := State} = Service,
    ?assertNot(is_map_key(max_concurrent_requests, State)),
    ?assertNot(is_map_key(overload_mode, State)).

%% A middleware's rejection answers with the status in the headers alone,
%% under the request's gRPC `content-type`, or gRPC's own.
reject_test() ->
    Req = #{headers => [{~"content-type", ~"Application/GRPC+Test; x=1"}]},
    ?assertEqual(
        {
            {200,
                [
                    {~"content-type", ~"application/grpc+test"},
                    {~"grpc-status", ~"16"},
                    {~"grpc-message", ~"no key"}
                ],
                <<>>},
            Req
        },
        ?M:reject(unauthenticated, ~"no key", Req)
    ),
    ContentType = fun(Headers) ->
        {{200, [{~"content-type", Type} | _], <<>>}, _} =
            ?M:reject(permission_denied, <<>>, #{headers => Headers}),
        Type
    end,
    ?assertEqual(~"application/grpc", ContentType([{~"content-type", ~"application/grpc"}])),
    ?assertEqual(~"application/grpc", ContentType([{~"content-type", ~"application/grpcx"}])),
    ?assertEqual(~"application/grpc", ContentType([{~"content-type", ~"application/grpc+"}])),
    ?assertEqual(~"application/grpc", ContentType([{~"content-type", ~"application/grpc+ ;a=b"}])),
    ?assertEqual(~"application/grpc", ContentType([{~"content-type", ~"application/grpc+a b"}])),
    ?assertEqual(~"application/grpc", ContentType([{~"content-type", ~"application/grpc+a,b"}])),
    ?assertEqual(
        ~"application/grpc+x.y-z_1", ContentType([{~"content-type", ~"application/grpc+X.y-Z_1"}])
    ),
    ?assertEqual(~"application/grpc", ContentType([{~"content-type", ~"text/plain"}])),
    ?assertEqual(~"application/grpc", ContentType([])),
    ?assertMatch(
        {{200, [_, {~"grpc-status", ~"7"}], <<>>}, _},
        ?M:reject(permission_denied, <<>>, #{headers => []})
    ),
    ?assertError(function_clause, ?M:reject(ok, <<>>, #{headers => []})),
    ?assertError(function_clause, ?M:reject(nope, <<>>, #{headers => []})).

%% `reject/4` adds the status's details, a google.rpc.Status of the same
%% code and message, and trailers as `set_trailers/2` takes them.
reject_with_details_and_trailers_test() ->
    Details = [{~"t/a", ~"v"}],
    {{200, Headers, <<>>}, _} = ?M:reject(
        resource_exhausted,
        ~"slow down",
        #{details => Details, trailers => [{~"grpc-retry-pushback-ms", ~"500"}, {~"x-bin", <<0>>}]},
        #{headers => []}
    ),
    Encoded = base64:encode(
        iolist_to_binary(roadrunner_grpc_status_proto:status(8, ~"slow down", Details)),
        #{padding => false}
    ),
    ?assertEqual(
        [
            {~"content-type", ~"application/grpc"},
            {~"grpc-status", ~"8"},
            {~"grpc-message", ~"slow down"},
            {~"grpc-status-details-bin", Encoded},
            {~"grpc-retry-pushback-ms", ~"500"},
            {~"x-bin", ~"AA"}
        ],
        Headers
    ),
    ?assertEqual(
        ?M:reject(internal, ~"m", #{headers => []}),
        ?M:reject(internal, ~"m", #{}, #{headers => []})
    ),
    %% No details, no details header.
    ?assertEqual(
        ?M:reject(internal, ~"m", #{headers => []}),
        ?M:reject(internal, ~"m", #{details => []}, #{headers => []})
    ),
    %% The details header is the call's own to set.
    ?assertError(
        {invalid_metadata, ~"grpc-status-details-bin"},
        ?M:reject(
            internal, ~"m", #{trailers => [{~"grpc-status-details-bin", <<>>}]}, #{headers => []}
        )
    ).

%% Used as a handler of its own, outside `routes/1`, `handle/1` still
%% answers a method other than POST with 405 itself.
handle_other_method_test() ->
    Req = #{version => {2, 0}, method => ~"GET"},
    ?assertEqual({{405, [{~"allow", ~"POST"}], <<>>}, Req}, ?M:handle(Req)).

%% A reset that says why beats a `peer` one queued ahead of it, and every
%% queued reset is taken from the mailbox.
reset_why_prefers_a_specific_reason_test_() ->
    {spawn, fun() ->
        self() ! {h2_stream_reset, 1, peer},
        self() ! {h2_stream_reset, 1, send_stall},
        self() ! {roadrunner_stream_reset, 1, peer},
        ?assertEqual(send_stall, ?M:reset_why(peer)),
        ?assertEqual({messages, []}, process_info(self(), messages))
    end}.

%% A reason already said is kept over the queued ones.
reset_why_keeps_what_was_said_test_() ->
    {spawn, fun() ->
        self() ! {h2_stream_reset, 1, send_stall},
        ?assertEqual(connection_age_grace, ?M:reset_why(connection_age_grace)),
        ?assertEqual(peer, ?M:reset_why(peer))
    end}.
