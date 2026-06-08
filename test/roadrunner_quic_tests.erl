-module(roadrunner_quic_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic).

%% The control API is a make_ref round-trip over the connection's
%% {quic_call}/{quic_send} wire, so a fake connection that speaks that wire
%% covers it without a full handshake (the real connection's replies are tested
%% in roadrunner_quic_conn_state_tests).

peername_round_trips_test() ->
    Conn = replier({ok, {{127, 0, 0, 1}, 443}}),
    ?assertEqual({ok, {{127, 0, 0, 1}, 443}}, ?M:peername(Conn)),
    ?assertEqual(peername, recv_request()).

open_unidirectional_stream_round_trips_test() ->
    Conn = replier({ok, 3}),
    ?assertEqual({ok, 3}, ?M:open_unidirectional_stream(Conn)),
    ?assertEqual(open_uni, recv_request()).

send_data_round_trips_test() ->
    Conn = replier(ok),
    ?assertEqual(ok, ?M:send_data(Conn, 4, ~"frames", true)),
    ?assertEqual({send, 4, ~"frames", true}, recv_request()).

%% send_data relays whatever the connection replies, including an error (a
%% draining connection rejecting the write).
send_data_relays_error_test() ->
    Conn = replier({error, {invalid_state, draining}}),
    ?assertEqual({error, {invalid_state, draining}}, ?M:send_data(Conn, 4, ~"x", false)),
    %% Drain the request report so it does not bleed into the next test.
    ?assertEqual({send, 4, ~"x", false}, recv_request()).

reset_stream_round_trips_test() ->
    Conn = replier(ok),
    ?assertEqual(ok, ?M:reset_stream(Conn, 0, 16#0100)),
    ?assertEqual({reset_stream, 0, 16#0100}, recv_request()).

stop_sending_round_trips_test() ->
    Conn = replier(ok),
    ?assertEqual(ok, ?M:stop_sending(Conn, 0, 16#0100)),
    ?assertEqual({stop_sending, 0, 16#0100}, recv_request()).

close_round_trips_test() ->
    Conn = replier(ok),
    ?assertEqual(ok, ?M:close(Conn, 16#0100)),
    ?assertEqual({close, 16#0100}, recv_request()).

close_with_reason_round_trips_test() ->
    Conn = replier(ok),
    ?assertEqual(ok, ?M:close(Conn, 16#0100, ~"bye")),
    ?assertEqual({close, 16#0100, ~"bye"}, recv_request()).

%% A connection that dies before replying exits the caller with
%% {quic_conn_down, _} (gen_statem:call semantics for a dead callee).
conn_down_exits_caller_test() ->
    Dead = dead_pid(),
    {_Pid, Mon} = spawn_monitor(fun() -> ?M:peername(Dead) end),
    receive
        {'DOWN', Mon, process, _, Reason} ->
            ?assertMatch({quic_conn_down, _}, Reason)
    after 1000 ->
        error(caller_did_not_exit)
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

%% A one-shot fake connection: reports the request it received to the test, then
%% answers with `Result`.
replier(Result) ->
    Test = self(),
    spawn(fun() ->
        receive
            {quic_call, From, Ref, Request} ->
                Test ! {request, Request},
                From ! {quic_reply, Ref, Result};
            {quic_send, From, Ref, StreamId, IoData, Fin} ->
                Test ! {request, {send, StreamId, IoData, Fin}},
                From ! {quic_reply, Ref, Result}
        end
    end).

recv_request() ->
    receive
        {request, Request} -> Request
    after 1000 ->
        timeout
    end.

dead_pid() ->
    {Pid, Mon} = spawn_monitor(fun() -> ok end),
    receive
        {'DOWN', Mon, process, Pid, _} -> ok
    end,
    Pid.
