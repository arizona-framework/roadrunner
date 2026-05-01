-module(cactus_ws_session_tests).

-include_lib("eunit/include/eunit.hrl").

%% `cactus_ws_session:run/4` must start the gen_statem **before** the
%% 101 upgrade response is written. If `gen_statem:start/3` fails
%% (here forced via an unknown handler module — `init/1` rejects it,
%% turning into `{error, _}` from start), the 101 must never reach
%% the wire and a 500 fallback must be sent instead.
run_with_unloadable_handler_sends_500_and_no_101_test() ->
    Tag = make_ref(),
    Self = self(),
    Sink = spawn_send_log_sink(Self, Tag),
    Headers = [
        {~"upgrade", ~"websocket"},
        {~"connection", ~"Upgrade"},
        {~"sec-websocket-key", ~"dGhlIHNhbXBsZSBub25jZQ=="},
        {~"sec-websocket-version", ~"13"}
    ],
    Req = #{
        headers => Headers,
        peer => undefined,
        listener_name => undefined,
        request_id => undefined
    },
    ok = cactus_ws_session:run(
        {fake, Sink}, Req, this_module_does_not_exist_xyz_42, undefined
    ),
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    Sink ! stop,
    ?assertEqual(nomatch, binary:match(Sent, ~"101")),
    ?assertNotEqual(nomatch, binary:match(Sent, ~"500")).

run_with_bad_handshake_still_returns_400_test() ->
    %% Regression check: bad handshake path is unchanged.
    Tag = make_ref(),
    Self = self(),
    Sink = spawn_send_log_sink(Self, Tag),
    Req = #{
        headers => [{~"host", ~"x"}],
        peer => undefined,
        listener_name => undefined,
        request_id => undefined
    },
    ok = cactus_ws_session:run({fake, Sink}, Req, cactus_ws_echo_handler, undefined),
    Sent = iolist_to_binary(collect_sends(Tag, 100)),
    Sink ! stop,
    ?assertNotEqual(nomatch, binary:match(Sent, ~"400")),
    ?assertEqual(nomatch, binary:match(Sent, ~"101")).

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

collect_sends(Tag, Timeout) ->
    collect_sends_loop(Tag, [], Timeout).

collect_sends_loop(Tag, Acc, Timeout) ->
    receive
        {sent, Tag, Data} -> collect_sends_loop(Tag, [Data | Acc], 0)
    after Timeout ->
        lists:reverse(Acc)
    end.
