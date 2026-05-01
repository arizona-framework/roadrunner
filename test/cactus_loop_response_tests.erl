-module(cactus_loop_response_tests).

-include_lib("eunit/include/eunit.hrl").

-behaviour(cactus_handler).
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
%% `{'$gen_call', _, _}`, or `{'$gen_cast', _}` to the handler. They
%% stay in the conn process mailbox so the surrounding `gen_statem`
%% resumes their normal handling once the loop ends.
loop_skips_otp_internal_messages_test() ->
    Tag = make_ref(),
    Self = self(),
    Sink = spawn_send_log_sink(Self, Tag),
    Probe = self(),
    %% Run the loop in a dedicated worker so we can observe its
    %% mailbox via the messages it forwards to Probe.
    Worker = spawn(fun() ->
        cactus_loop_response:run({fake, Sink}, 200, [], ?MODULE, Probe),
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

collect_handler_msgs(Acc, Timeout) ->
    receive
        {handler_got, Msg} -> collect_handler_msgs([Msg | Acc], 0)
    after Timeout ->
        lists:reverse(Acc)
    end.

%% --- helpers ---

spawn_send_log_sink(Logger, Tag) ->
    spawn(fun() -> sink_loop(Logger, Tag) end).

sink_loop(Logger, Tag) ->
    receive
        stop ->
            ok;
        {cactus_fake_send, _Pid, Data} ->
            Logger ! {sent, Tag, Data},
            sink_loop(Logger, Tag);
        {cactus_fake_recv, ConnPid, _Len, _Timeout} ->
            ConnPid ! {cactus_fake_recv_reply, {error, closed}},
            sink_loop(Logger, Tag);
        _ ->
            sink_loop(Logger, Tag)
    end.
