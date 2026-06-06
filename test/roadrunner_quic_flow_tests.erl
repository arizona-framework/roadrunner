-module(roadrunner_quic_flow_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_flow).

%% =============================================================================
%% Initial state.
%% =============================================================================

new_defaults_test() ->
    Flow = ?M:new(#{}),
    ?assertEqual(786432, ?M:send_window(Flow)),
    ?assertEqual(786432, ?M:recv_window(Flow)),
    ?assertEqual(0, ?M:bytes_sent(Flow)),
    ?assertEqual(0, ?M:bytes_received(Flow)),
    ?assertNot(?M:send_blocked(Flow)).

%% =============================================================================
%% Send side (RFC 9000 §4): bounded by the peer's limit.
%% =============================================================================

send_side_test() ->
    Flow = ?M:new(#{peer_initial_max_data => 1000}),
    ?assert(?M:can_send(1000, Flow)),
    ?assertNot(?M:can_send(1001, Flow)),
    {ok, Flow1} = ?M:on_data_sent(400, Flow),
    ?assertEqual(600, ?M:send_window(Flow1)),
    ?assertEqual(400, ?M:bytes_sent(Flow1)),
    ?assertNot(?M:send_blocked(Flow1)),
    {blocked, Flow2} = ?M:on_data_sent(600, Flow1),
    ?assert(?M:send_blocked(Flow2)),
    ?assertEqual(0, ?M:send_window(Flow2)).

%% A received MAX_DATA raises the limit and clears the block; a lower value
%% is ignored (limits only increase).
max_data_raises_and_never_lowers_test() ->
    {blocked, Flow1} = ?M:on_data_sent(1000, ?M:new(#{peer_initial_max_data => 1000})),
    Flow2 = ?M:on_max_data_received(1500, Flow1),
    ?assertNot(?M:send_blocked(Flow2)),
    ?assertEqual(500, ?M:send_window(Flow2)),
    Flow3 = ?M:on_max_data_received(100, Flow2),
    ?assertEqual(500, ?M:send_window(Flow3)).

%% =============================================================================
%% Receive side (RFC 9000 §4.1): an overrun is a flow-control error.
%% =============================================================================

recv_side_rejects_overrun_test() ->
    Flow = ?M:new(#{initial_max_data => 1000}),
    {ok, Flow1} = ?M:on_data_received(1000, Flow),
    ?assertEqual(0, ?M:recv_window(Flow1)),
    ?assertEqual(1000, ?M:bytes_received(Flow1)),
    ?assertEqual({error, flow_control_error}, ?M:on_data_received(1, Flow1)),
    ?assertEqual({error, flow_control_error}, ?M:on_data_received(1001, Flow)).

%% A new limit is granted once more than a quarter of the window
%% (1000 - 1000*3/4 = 250) has been consumed.
should_send_max_data_threshold_test() ->
    Flow = ?M:new(#{initial_max_data => 1000}),
    {ok, Below} = ?M:on_data_received(250, Flow),
    ?assertNot(?M:should_send_max_data(Below)),
    {ok, Above} = ?M:on_data_received(251, Flow),
    ?assert(?M:should_send_max_data(Above)).

grant_extends_window_test() ->
    Flow = ?M:new(#{initial_max_data => 1000}),
    {ok, Flow1} = ?M:on_data_received(300, Flow),
    {NewMax, Flow2} = ?M:grant_max_data(Flow1),
    ?assertEqual(1300, NewMax),
    ?assertEqual(1000, ?M:recv_window(Flow2)),
    ?assertNot(?M:should_send_max_data(Flow2)).
