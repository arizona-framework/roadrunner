-module(roadrunner_h3_listener_pool_tests).
-include_lib("eunit/include/eunit.hrl").

%% Tests the listener-level HTTP/3 sub-opts, nested under
%% `protocols => [{http3, #{...}}]`: the reuseport-pool `listeners` knob
%% and the `max_streams_bidi` cap. Covers the validator's reject path (a
%% bad value fails listener start fast), the accept path (a tuned value
%% boots a listener cleanly), and that a custom `max_streams_bidi`
%% threads through to proto_opts. The pooling behaviour itself (parallel
%% inbound demux) is a perf property measured by the bench, not asserted
%% here.

all_test_() ->
    Tests = [
        fun invalid_listeners_opt_fails_listener_start/0,
        fun valid_listeners_opt_lets_listener_boot/0,
        fun custom_max_streams_bidi_threads_into_proto_opts/0
    ],
    [{spawn, T} || T <- Tests].

invalid_listeners_opt_fails_listener_start() ->
    %% A non-positive / non-integer / over-cap `listeners`, or an unknown
    %% sub-opt, surfaces at listener init/1 as
    %% `{invalid_listener_opt, protocols, _}`. The validator runs before
    %% the TLS-required check, so these need no `tls`.
    process_flag(trap_exit, true),
    BadCases = [
        #{listeners => 0},
        #{listeners => -1},
        #{listeners => 16#80000000},
        #{listeners => not_an_integer},
        #{unknown_h3_opt => 1}
    ],
    [
        ?assertMatch(
            {error, {{invalid_listener_opt, protocols, _}, _}},
            roadrunner_listener:start_link(
                list_to_atom(
                    "h3_pool_test_invalid_" ++
                        integer_to_list(erlang:unique_integer([positive]))
                ),
                #{port => 0, protocols => [{http3, H3}]}
            )
        )
     || H3 <- BadCases
    ],
    ok.

valid_listeners_opt_lets_listener_boot() ->
    %% The validator's success path (an in-range count) plus the
    %% non-default pool wiring: boot a listener with a tuned `{http3, _}`
    %% entry. It comes up clean and stops clean.
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(quic),
    ensure_pg(),
    Name = list_to_atom(
        "h3_pool_test_valid_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0,
        protocols => [{http3, #{listeners => 2}}],
        tls => roadrunner_test_certs:server_opts(),
        routes => roadrunner_keepalive_handler
    }),
    ok = roadrunner_listener:stop(Name).

custom_max_streams_bidi_threads_into_proto_opts() ->
    %% A tuned `max_streams_bidi` flattens to the `http3_max_streams_bidi`
    %% proto_opts key the QUIC pool reads when advertising the peer's
    %% bidirectional-stream cap in the transport parameters.
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(quic),
    ensure_pg(),
    Name = list_to_atom(
        "h3_max_streams_bidi_test_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    {ok, ListenerPid} = roadrunner_listener:start_link(Name, #{
        port => 0,
        protocols => [{http3, #{max_streams_bidi => 256}}],
        tls => roadrunner_test_certs:server_opts(),
        routes => roadrunner_keepalive_handler
    }),
    State = sys:get_state(ListenerPid),
    ProtoOpts = element(4, State),
    ?assertEqual(256, maps:get(http3_max_streams_bidi, ProtoOpts)),
    ok = roadrunner_listener:stop(Name).

ensure_pg() ->
    case whereis(pg) of
        undefined ->
            {ok, _} = pg:start_link(),
            ok;
        _ ->
            ok
    end.
