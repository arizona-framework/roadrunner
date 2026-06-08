-module(roadrunner_quic_listener_sup_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_listener_sup).
-define(REG, roadrunner_quic_cid_registry).

%% The pool-options -> per-listener-options translation and the child-spec build
%% are pure (given a registry / the supervisor init), so they are covered here;
%% the live pool (the reuseport bind, get_listeners, stop, a real handshake)
%% lives in roadrunner_quic_listener_sup_SUITE.

listener_opts_maps_pool_opts_test() ->
    Registry = ?REG:new(),
    Handler = fun(_ConnPid) -> {ok, self()} end,
    PoolOpts = #{
        cert => <<"leaf">>,
        key => fake_key,
        cert_chain => [<<"int1">>, <<"int2">>],
        alpn => [~"h3"],
        max_streams_bidi => 50,
        connection_handler => Handler,
        pool_size => 2
    },
    Opts = ?M:listener_opts(4433, PoolOpts, Registry, true),
    ?assertEqual(4433, maps:get(port, Opts)),
    %% The leaf is prepended to the intermediate chain (the listener takes the
    %% full chain leaf-first; pool_opts keeps them split).
    ?assertEqual([<<"leaf">>, <<"int1">>, <<"int2">>], maps:get(cert_chain, Opts)),
    ?assertEqual(fake_key, maps:get(priv_key, Opts)),
    %% The single negotiated ALPN is extracted from the list.
    ?assertEqual(~"h3", maps:get(alpn, Opts)),
    ?assertEqual(Handler, maps:get(connection_handler, Opts)),
    ?assertEqual(true, maps:get(reuseport, Opts)),
    ?assertEqual(Registry, maps:get(registry, Opts)),
    TP = maps:get(transport_params, Opts),
    ?assertEqual(50, maps:get(initial_max_streams_bidi, TP)),
    %% The fixed defaults (pending the flow-control opt wiring).
    ?assertEqual(1048576, maps:get(initial_max_data, TP)),
    ?assertEqual(262144, maps:get(initial_max_stream_data_bidi_local, TP)),
    ?assertEqual(262144, maps:get(initial_max_stream_data_bidi_remote, TP)),
    ?assertEqual(262144, maps:get(initial_max_stream_data_uni, TP)),
    ?assertEqual(100, maps:get(initial_max_streams_uni, TP)),
    ?assertEqual(30000, maps:get(max_idle_timeout, TP)),
    %% The base transport params carry no per-connection ids (filled at spawn).
    ?assertNot(maps:is_key(original_destination_connection_id, TP)),
    ?assertNot(maps:is_key(initial_source_connection_id, TP)).

%% A single-listener pool passes reuseport => false, and an empty intermediate
%% chain yields a one-element (leaf-only) chain.
listener_opts_single_listener_test() ->
    Registry = ?REG:new(),
    Opts = ?M:listener_opts(0, pool_opts(0), Registry, false),
    ?assertEqual(false, maps:get(reuseport, Opts)),
    ?assertEqual([<<"leaf">>], maps:get(cert_chain, Opts)).

%% init/1 builds `pool_size + 1` reuseport listeners that all share ONE registry
%% handle: the property the pool exists for, so a datagram fanned out to any
%% listener routes via the same table. A regression creating a fresh registry
%% per listener fails the usort assertion.
init_shares_one_registry_across_listeners_test() ->
    {ok, {_SupFlags, Specs}} = ?M:init({4433, pool_opts(3)}),
    ?assertEqual(4, length(Specs)),
    ?assertEqual(1, length(lists:usort([registry_of(Spec) || Spec <- Specs]))),
    ?assert(lists:all(fun(Spec) -> maps:get(reuseport, opts_of(Spec)) =:= true end, Specs)).

%% A single-listener pool is one listener with reuseport off.
init_single_listener_test() ->
    {ok, {_SupFlags, Specs}} = ?M:init({0, pool_opts(0)}),
    ?assertEqual(1, length(Specs)),
    [Spec] = Specs,
    ?assertEqual(false, maps:get(reuseport, opts_of(Spec))).

%% =============================================================================
%% Helpers
%% =============================================================================

registry_of(Spec) ->
    maps:get(registry, opts_of(Spec)).

opts_of(#{start := {roadrunner_quic_listener, start_link, [Opts]}}) ->
    Opts.

pool_opts(PoolSize) ->
    #{
        cert => <<"leaf">>,
        key => fake_key,
        cert_chain => [],
        alpn => [~"h3"],
        max_streams_bidi => 100,
        connection_handler => fun(_ConnPid) -> {ok, self()} end,
        pool_size => PoolSize
    }.
