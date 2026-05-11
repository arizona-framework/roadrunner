-module(roadrunner_http2_loop_response_tests).

-include_lib("eunit/include/eunit.hrl").

-behaviour(roadrunner_handler).
-export([handle/1, handle_info/3]).

%% Test handler. State is a list of `{push, IoData} | stop` directives;
%% each handle_info pops one directive and acts on it.
handle(Req) ->
    {{200, [], ~""}, Req}.

handle_info(go, Push, [{push, Data} | Rest]) ->
    ok = Push(Data),
    self() ! go,
    {ok, Rest};
handle_info(go, _Push, [stop | _]) ->
    {stop, undefined}.

%% --- empty push is a no-op ---

empty_push_skips_data_frame_test() ->
    %% `make_push(_, _)/1` short-circuits on empty data: pushing <<>>
    %% must not trigger an `h2_send_data` request to the conn.
    %% Sequence: handler pushes <<>>, then non-empty ~"x", then stops.
    %% The fake conn logs send events; we expect:
    %%   - 1 send_headers (run/5 prelude)
    %%   - 1 send_data carrying ~"x" (the non-empty push)
    %%   - 1 send_data carrying <<>> with END_STREAM (the stop)
    {FakeConn, Worker} = spawn_loop([{push, <<>>}, {push, ~"x"}, stop]),
    Worker ! go,
    ok = wait_for_exit(Worker, 1000),
    Sends = collect_sends(FakeConn),
    ?assertEqual(
        [
            {send_headers, 1, 200, [], false},
            {send_data, 1, ~"x", false},
            {send_data, 1, <<>>, true}
        ],
        Sends
    ),
    FakeConn ! stop.

%% --- sync exits on h2_stream_reset ---

sync_exits_on_stream_reset_test() ->
    %% When the conn replies `{h2_stream_reset, StreamId}` instead of
    %% `{h2_send_ack, Ref}`, `sync/1` raises `exit(stream_reset)`. The
    %% conn drives this when the peer has cancelled the stream.
    {FakeConn, Worker} = spawn_loop([{push, ~"hi"}, stop]),
    %% Tell the fake conn to RST_STREAM the next send_data instead of
    %% acking.
    FakeConn ! {reset_next, 1},
    MRef = erlang:monitor(process, Worker),
    Worker ! go,
    receive
        {'DOWN', MRef, process, Worker, Reason} ->
            ?assertEqual(stream_reset, Reason)
    after 1000 ->
        error(worker_did_not_exit)
    end,
    FakeConn ! stop.

%% --- helpers ---

spawn_loop(Directives) ->
    Self = self(),
    FakeConn = spawn(fun() -> fake_conn_loop(Self, []) end),
    Worker = spawn(fun() ->
        roadrunner_http2_loop_response:run(FakeConn, 1, 200, [], {?MODULE, Directives})
    end),
    {FakeConn, Worker}.

fake_conn_loop(Reporter, Sends) ->
    fake_conn_loop(Reporter, Sends, undefined).

%% ResetStreamId = undefined means ack every h2_send_data normally;
%% set to a stream id by `{reset_next, _}` to make the next matching
%% h2_send_data reply with `{h2_stream_reset, StreamId}` instead.
fake_conn_loop(Reporter, Sends, ResetStreamId) ->
    receive
        stop ->
            Reporter ! {sends, lists:reverse(Sends)};
        {dump, From} ->
            From ! {sends, lists:reverse(Sends)},
            fake_conn_loop(Reporter, Sends, ResetStreamId);
        {reset_next, StreamId} ->
            fake_conn_loop(Reporter, Sends, StreamId);
        {h2_send_headers, From, Ref, StreamId, Status, Headers, EndStream} ->
            From ! {h2_send_ack, Ref},
            fake_conn_loop(
                Reporter,
                [{send_headers, StreamId, Status, Headers, EndStream} | Sends],
                ResetStreamId
            );
        {h2_send_data, From, _Ref, StreamId, _Bin, _EndStream} when
            StreamId =:= ResetStreamId
        ->
            From ! {h2_stream_reset, StreamId},
            %% Worker exits via sync/1; revert to normal mode in case
            %% more messages arrive (they should not).
            fake_conn_loop(Reporter, Sends, undefined);
        {h2_send_data, From, Ref, StreamId, Bin, EndStream} ->
            From ! {h2_send_ack, Ref},
            fake_conn_loop(
                Reporter, [{send_data, StreamId, Bin, EndStream} | Sends], ResetStreamId
            )
    end.

wait_for_exit(Pid, Timeout) ->
    MRef = erlang:monitor(process, Pid),
    receive
        {'DOWN', MRef, process, Pid, _} -> ok
    after Timeout ->
        error(worker_did_not_finish)
    end.

collect_sends(FakeConn) ->
    FakeConn ! {dump, self()},
    receive
        {sends, Sends} -> Sends
    after 1000 ->
        error(no_sends_received)
    end.
