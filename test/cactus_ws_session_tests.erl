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

%% =============================================================================
%% Active-mode frame_loop — hibernate, transport error, and stray-info
%% paths. Drives the gen_statem directly (skipping the run/4 launcher)
%% with a script-driven fake sink that delivers `cactus_fake_data`
%% messages on `setopts({active, once})`.
%% =============================================================================

frame_loop_hibernates_when_handler_returns_hibernate_opt_test() ->
    %% Send a text frame; handler returns {reply, _, _, [hibernate]}.
    %% After processing the frame, the gen_statem must hibernate —
    %% verified via `process_info(Pid, status) =:= waiting` and
    %% `total_heap_size` shrunk to the OTP hibernation minimum
    %% (~233 words; we cap at 256 to absorb future drift).
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink(Self, Tag, [
        {recv, frame(text, ~"hello")}
    ]),
    {ok, Pid} = gen_statem:start(
        cactus_ws_session,
        {{fake, Sink}, cactus_ws_hibernate_handler, undefined, ws_ctx()},
        []
    ),
    Pid ! socket_ready,
    %% Wait for the echo reply to come back (= handler ran).
    Sent = iolist_to_binary(collect_sends(Tag, 200)),
    ?assertNotEqual(nomatch, binary:match(Sent, ~"hello")),
    %% Process must be hibernated.
    ?assert(is_hibernating(Pid, 200)),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

frame_loop_hibernates_on_ok_opt_variant_test() ->
    %% Binary frame → {ok, _, [hibernate]} → no reply but hibernate.
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink(Self, Tag, [
        {recv, frame(binary, ~"data")}
    ]),
    {ok, Pid} = gen_statem:start(
        cactus_ws_session,
        {{fake, Sink}, cactus_ws_hibernate_handler, undefined, ws_ctx()},
        []
    ),
    Pid ! socket_ready,
    ?assert(is_hibernating(Pid, 500)),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

frame_loop_no_hibernate_for_3_tuple_returns_test() ->
    %% Echo handler uses 3-tuple `{reply, _, _}`; without the opt the
    %% session must NOT hibernate.
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink(Self, Tag, [
        {recv, frame(text, ~"hello")}
    ]),
    {ok, Pid} = gen_statem:start(
        cactus_ws_session,
        {{fake, Sink}, cactus_ws_echo_handler, undefined, ws_ctx()},
        []
    ),
    Pid ! socket_ready,
    Sent = iolist_to_binary(collect_sends(Tag, 200)),
    ?assertNotEqual(nomatch, binary:match(Sent, ~"hello")),
    %% After echo, gen_statem is waiting for the next frame in active
    %% mode — but NOT hibernating. current_function should not be
    %% erlang:hibernate.
    timer:sleep(50),
    ?assertNotEqual({erlang, hibernate, 3}, current_function(Pid)),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

frame_loop_stops_on_transport_error_event_test() ->
    %% A `{cactus_fake_error, _, _}` info event ends the session
    %% cleanly with `normal` exit (parity with `{tcp_error, _, _}`).
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink(Self, Tag, [{error, econnreset}]),
    {ok, Pid} = gen_statem:start(
        cactus_ws_session,
        {{fake, Sink}, cactus_ws_echo_handler, undefined, ws_ctx()},
        []
    ),
    Ref = monitor(process, Pid),
    Pid ! socket_ready,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 1000 -> error(no_normal_exit)
    end,
    Sink ! stop.

frame_loop_drops_unexpected_info_event_test() ->
    %% A stray info message that doesn't match any of the transport
    %% tags gets dropped and the session re-arms the socket; verified
    %% by the session still being alive afterwards.
    Self = self(),
    Tag = make_ref(),
    Sink = spawn_active_sink(Self, Tag, []),
    {ok, Pid} = gen_statem:start(
        cactus_ws_session,
        {{fake, Sink}, cactus_ws_echo_handler, undefined, ws_ctx()},
        []
    ),
    Pid ! socket_ready,
    %% Let frame_loop arm the socket, then deliver a stray info.
    timer:sleep(20),
    Pid ! {stray, make_ref()},
    timer:sleep(20),
    ?assert(is_process_alive(Pid)),
    Sink ! stop,
    ok = gen_statem:stop(Pid).

%% --- helpers ---

ws_ctx() ->
    #{
        listener_name => probe_ws,
        peer => undefined,
        request_id => undefined,
        module => cactus_ws_echo_handler
    }.

%% A minimal text/binary single-fragment unmasked frame. Server-side
%% receives masked frames per the WebSocket spec, so we mark fin=true
%% and apply a XOR mask to the payload via cactus_ws.
frame(Opcode, Payload) ->
    Masked = mask(Payload, <<1, 2, 3, 4>>),
    Len = byte_size(Payload),
    OpcodeByte =
        case Opcode of
            text -> 16#81;
            binary -> 16#82
        end,
    <<OpcodeByte, (16#80 bor Len), 1, 2, 3, 4, Masked/binary>>.

mask(Bin, Key) ->
    KeyBin = binary:copy(Key, (byte_size(Bin) div 4) + 1),
    <<KeySlice:(byte_size(Bin))/binary, _/binary>> = KeyBin,
    crypto:exor(Bin, KeySlice).

is_hibernating(Pid, TimeoutMs) ->
    is_hibernating_loop(Pid, erlang:monotonic_time(millisecond) + TimeoutMs).

%% A hibernated process is in `status =:= waiting` AND has had its
%% heap shrunk to its minimum (typically 233 words on default OTP).
%% `current_function` for a process resumed from hibernation is the
%% M:F:A it'll re-enter when woken (so we can't rely on it being
%% `{erlang, hibernate, _}`).
is_hibernating_loop(Pid, Deadline) ->
    case process_info(Pid, [status, total_heap_size, message_queue_len]) of
        [{status, waiting}, {total_heap_size, H}, {message_queue_len, 0}] when
            H =< 256
        ->
            true;
        _ ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    false;
                false ->
                    timer:sleep(10),
                    is_hibernating_loop(Pid, Deadline)
            end
    end.

current_function(Pid) ->
    case process_info(Pid, current_function) of
        {current_function, MFA} -> MFA;
        undefined -> undefined
    end.

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

%% Active-mode sink: when the conn arms `setopts({active, once})`, the
%% sink dispatches the next script step (data | closed | error) to
%% the conn pid using the cactus_fake_* message tags from
%% `cactus_transport:messages/1`.
spawn_active_sink(Logger, Tag, Script) ->
    spawn(fun() -> active_sink_loop(Logger, Tag, Script) end).

active_sink_loop(Logger, Tag, Script) ->
    receive
        stop ->
            ok;
        {cactus_fake_send, _Pid, Data} ->
            Logger ! {sent, Tag, Data},
            active_sink_loop(Logger, Tag, Script);
        {cactus_fake_setopts, ConnPid, _Opts} ->
            case Script of
                [{recv, Bytes} | Rest] ->
                    ConnPid ! {cactus_fake_data, self(), Bytes},
                    active_sink_loop(Logger, Tag, Rest);
                [{error, closed} | Rest] ->
                    ConnPid ! {cactus_fake_closed, self()},
                    active_sink_loop(Logger, Tag, Rest);
                [{error, Reason} | Rest] ->
                    ConnPid ! {cactus_fake_error, self(), Reason},
                    active_sink_loop(Logger, Tag, Rest);
                [] ->
                    %% No more script — leave the session armed and
                    %% silently dormant; the test will stop the
                    %% gen_statem itself.
                    active_sink_loop(Logger, Tag, [])
            end;
        _ ->
            active_sink_loop(Logger, Tag, Script)
    end.

collect_sends(Tag, Timeout) ->
    collect_sends_loop(Tag, [], Timeout).

collect_sends_loop(Tag, Acc, Timeout) ->
    receive
        {sent, Tag, Data} -> collect_sends_loop(Tag, [Data | Acc], 0)
    after Timeout ->
        lists:reverse(Acc)
    end.
