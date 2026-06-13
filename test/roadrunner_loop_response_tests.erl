-module(roadrunner_loop_response_tests).

-include_lib("eunit/include/eunit.hrl").

-behaviour(roadrunner_handler).
-export([handle/1, handle_info/3]).

%% Test handler: forwards every received message to a probe pid (held
%% in State) and stops on the `done` atom.
handle(Req) ->
    {{200, [], ~""}, Req}.

handle_info(done, _Push, State) ->
    {stop, State};
handle_info(Msg, _Push, ProbePid) ->
    ProbePid ! {handler_got, Msg},
    {ok, ProbePid}.

%% `info_loop/4` must NOT deliver `{system, _, _}`,
%% `{'$gen_call', _, _}`, or `{'$gen_cast', _}` to the handler.
%% Those shapes are answered by `roadrunner_loop_sys` (the dedicated
%% behaviour tests below cover the answers); the handler only ever sees
%% the user-bound messages.
loop_skips_otp_internal_messages_test() ->
    Tag = make_ref(),
    Self = self(),
    Sink = spawn_send_log_sink(Self, Tag),
    Probe = self(),
    %% Run the loop in a dedicated worker so we can observe its
    %% mailbox via the messages it forwards to Probe.
    Worker = spawn(fun() ->
        roadrunner_loop_response:run({fake, Sink}, 200, [], ?MODULE, Probe),
        Self ! {worker_done, self()}
    end),
    %% Send a mix of OTP-internal and user-bound messages.
    Worker ! {system, {self(), make_ref()}, get_state},
    Worker ! {'$gen_call', {self(), make_ref()}, hello},
    Worker ! {'$gen_cast', hello},
    Worker ! user_msg_1,
    Worker ! user_msg_2,
    Worker ! done,
    %% Wait for worker to finish.
    receive
        {worker_done, Worker} -> ok
    after 1000 -> error(worker_did_not_finish)
    end,
    Sink ! stop,
    Got = collect_handler_msgs([], 100),
    %% The handler must see the two user messages in order, and
    %% nothing else.
    ?assertEqual([user_msg_1, user_msg_2], Got).

%% A peer close (the transport's `closed` tag) delivers one
%% `{roadrunner_disconnect, closed}` to the handler and ends the loop
%% without writing the chunked terminator.
loop_delivers_disconnect_on_close_test_() ->
    {spawn, fun() ->
        {Worker, Sink, Tag} = start_disconnect_worker(),
        Worker ! {roadrunner_fake_closed, fake_sock},
        await_worker_done(Worker),
        Sink ! stop,
        ?assertEqual([{roadrunner_disconnect, closed}], collect_handler_msgs([], 100)),
        ?assertNot(lists:member(~"0\r\n\r\n", collect_sent([], Tag, 100)))
    end}.

%% A transport error (the transport's `error` tag) is treated the same
%% as a close: one `{roadrunner_disconnect, closed}`, no terminator.
loop_delivers_disconnect_on_error_test_() ->
    {spawn, fun() ->
        {Worker, Sink, Tag} = start_disconnect_worker(),
        Worker ! {roadrunner_fake_error, fake_sock, econnreset},
        await_worker_done(Worker),
        Sink ! stop,
        ?assertEqual([{roadrunner_disconnect, closed}], collect_handler_msgs([], 100)),
        ?assertNot(lists:member(~"0\r\n\r\n", collect_sent([], Tag, 100)))
    end}.

%% Inbound bytes on the (unidirectional) streaming socket are discarded
%% and the loop keeps running — the handler never sees them, and a later
%% `done` still stops cleanly with the chunked terminator.
loop_discards_inbound_data_and_continues_test_() ->
    {spawn, fun() ->
        {Worker, Sink, Tag} = start_disconnect_worker(),
        Worker ! {roadrunner_fake_data, fake_sock, ~"junk"},
        Worker ! user_msg_1,
        Worker ! done,
        await_worker_done(Worker),
        Sink ! stop,
        ?assertEqual([user_msg_1], collect_handler_msgs([], 100)),
        ?assert(await_sent(~"0\r\n\r\n", Tag, 2000))
    end}.

%% If arming `{active, once}` fails (socket already gone), the loop
%% delivers the disconnect immediately rather than blocking forever.
loop_arm_failure_delivers_disconnect_test_() ->
    {spawn, fun() ->
        Self = self(),
        DeadSink = spawn(fun() -> ok end),
        DeadRef = monitor(process, DeadSink),
        receive
            {'DOWN', DeadRef, process, DeadSink, _} -> ok
        after 1000 -> error(sink_not_dead)
        end,
        Probe = self(),
        Worker = spawn(fun() ->
            roadrunner_loop_response:run({fake, DeadSink}, 200, [], ?MODULE, Probe),
            Self ! {worker_done, self()}
        end),
        await_worker_done(Worker),
        ?assertEqual([{roadrunner_disconnect, closed}], collect_handler_msgs([], 100))
    end}.

%% A `gen_server:call/2,3` against the loop replies `{error, not_supported}`
%% instead of hanging.
loop_gen_call_replies_not_supported_test() ->
    {Worker, Ref} = start_loop_worker(some_state),
    ?assertEqual({error, not_supported}, gen_server:call(Worker, ping)),
    stop_loop_worker(Worker, Ref).

%% `sys:get_state/1` returns the handler's loop state.
loop_sys_get_state_returns_state_test() ->
    {Worker, Ref} = start_loop_worker({loop_state, 42}),
    ?assertEqual({loop_state, 42}, sys:get_state(Worker)),
    stop_loop_worker(Worker, Ref).

%% `sys:replace_state/2` swaps the loop state in place.
loop_sys_replace_state_test() ->
    {Worker, Ref} = start_loop_worker(0),
    ?assertEqual(1, sys:replace_state(Worker, fun(N) -> N + 1 end)),
    ?assertEqual(1, sys:get_state(Worker)),
    stop_loop_worker(Worker, Ref).

%% `sys:terminate/2` stops the loop with the given reason.
loop_sys_terminate_stops_worker_test() ->
    {Worker, Ref} = start_loop_worker(some_state),
    ok = sys:terminate(Worker, shutdown),
    receive
        {'DOWN', Ref, process, Worker, shutdown} -> ok
    after 1000 -> error(worker_not_terminated)
    end.

%% Spawn the loop in a monitored worker over a fake socket. No user
%% messages are sent in the sys/gen tests, so the handler's forward
%% logic is never exercised and the loop state can be any term.
stop_loop_worker(Worker, Ref) ->
    ok = sys:terminate(Worker, normal),
    _ = erlang:demonitor(Ref, [flush]),
    ok.

start_loop_worker(State) ->
    Sink = spawn_send_log_sink(self(), make_ref()),
    spawn_monitor(fun() ->
        roadrunner_loop_response:run({fake, Sink}, 200, [], ?MODULE, State)
    end).

collect_handler_msgs(Acc, Timeout) ->
    receive
        {handler_got, Msg} -> collect_handler_msgs([Msg | Acc], 0)
    after Timeout ->
        lists:reverse(Acc)
    end.

%% Spawn the loop over a fresh send-logging sink, forwarding handler
%% messages and finish notifications to the test process. Returns the
%% worker pid, the sink pid, and the send-log tag.
start_disconnect_worker() ->
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_send_log_sink(Self, Tag),
    Worker = spawn(fun() ->
        roadrunner_loop_response:run({fake, Sink}, 200, [], ?MODULE, Self),
        Self ! {worker_done, self()}
    end),
    {Worker, Sink, Tag}.

await_worker_done(Worker) ->
    receive
        {worker_done, Worker} -> ok
    after 1000 -> error(worker_did_not_finish)
    end.

collect_sent(Acc, Tag, Timeout) ->
    receive
        {sent, Tag, Data} -> collect_sent([iolist_to_binary(Data) | Acc], Tag, 0)
    after Timeout ->
        lists:reverse(Acc)
    end.

%% Wait up to TimeoutMs for a specific chunk to be sent, returning as soon
%% as it arrives. The loop process flushes through the fake sink
%% asynchronously, so a chunk can land shortly after the worker signals
%% done; polling for the exact chunk is reliable where reading a fixed
%% time window races the flush under load (collecting on a 0-timeout drain
%% misses a chunk that arrives a moment later).
await_sent(Target, Tag, TimeoutMs) ->
    receive
        {sent, Tag, Data} ->
            case iolist_to_binary(Data) of
                Target -> true;
                _ -> await_sent(Target, Tag, TimeoutMs)
            end
    after TimeoutMs ->
        false
    end.

%% --- helpers ---

spawn_send_log_sink(Logger, Tag) ->
    spawn(fun() -> sink_loop(Logger, Tag) end).

sink_loop(Logger, Tag) ->
    receive
        stop ->
            ok;
        {roadrunner_fake_send, _Pid, Data} ->
            Logger ! {sent, Tag, Data},
            sink_loop(Logger, Tag);
        {roadrunner_fake_recv, ConnPid, _Len, _Timeout} ->
            ConnPid ! {roadrunner_fake_recv_reply, {error, closed}},
            sink_loop(Logger, Tag);
        _ ->
            sink_loop(Logger, Tag)
    end.
