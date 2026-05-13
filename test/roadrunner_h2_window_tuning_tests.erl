-module(roadrunner_h2_window_tuning_tests).
-include_lib("eunit/include/eunit.hrl").

%% Tests the listener-level h2 receive-window knobs (nested under
%% `protocols => [{http2, #{...}}]`):
%%   - `conn_window`               — connection-level recv peak
%%   - `stream_window`             — stream-level recv peak
%%   - `window_refill_threshold`   — refill trigger (not directly
%%                                   asserted here; covered by the
%%                                   conn loop's own flow-control
%%                                   tests)
%%
%% When `conn_window > 65535`, the conn emits an early
%% `WINDOW_UPDATE(0, peak - 65535)` right after the server SETTINGS
%% in the handshake (RFC 9113 §6.5.2: the conn-level recv window is
%% only tunable via `WINDOW_UPDATE`, not SETTINGS).
%%
%% When `stream_window > 65535`, the server SETTINGS frame includes
%% a `SETTINGS_INITIAL_WINDOW_SIZE` (id 4) entry advertising the
%% configured peak.
%%
%% Defaults match the RFC baseline (65535 / 65535) — neither extra
%% frame is emitted unless the user explicitly bumps the values.

all_test_() ->
    Tests = [
        fun default_opts_emit_only_basic_settings/0,
        fun bumped_conn_window_emits_window_update/0,
        fun bumped_stream_window_advertises_initial_window_size/0,
        fun bumped_both_emits_settings_with_size_then_window_update/0,
        fun custom_threshold_changes_refill_trigger/0,
        fun invalid_window_opt_fails_listener_start/0,
        fun valid_window_opts_let_listener_boot/0
    ],
    [
        {spawn, fun() ->
            drain_mailbox(),
            T()
        end}
     || T <- Tests
    ].

default_opts_emit_only_basic_settings() ->
    %% With default ProtoOpts (no h2_* override) the handshake emits
    %% the same SETTINGS frame it always did — no INITIAL_WINDOW_SIZE
    %% entry, no early WINDOW_UPDATE. Backward-compat guarantee.
    {Pid, Ref} = start_conn(#{}),
    Settings = expect_send(),
    {ok, {settings, 0, Entries}, _} = roadrunner_http2_frame:parse(Settings, 16384),
    %% No id-4 entry (INITIAL_WINDOW_SIZE).
    ?assertEqual(false, lists:keymember(4, 1, Entries)),
    %% No WINDOW_UPDATE follows — exhaust the mailbox window
    %% briefly to confirm.
    ?assertEqual(no_send, drain_send(100)),
    cleanup(Pid, Ref).

bumped_conn_window_emits_window_update() ->
    %% conn_window = 16M, stream stays default. Expect SETTINGS
    %% without id 4, then WINDOW_UPDATE(0, 16M - 65535).
    Peak = 16 * 1024 * 1024,
    {Pid, Ref} = start_conn(#{conn_window => Peak}),
    Settings = expect_send(),
    {ok, {settings, 0, Entries}, _} = roadrunner_http2_frame:parse(Settings, 16384),
    ?assertEqual(false, lists:keymember(4, 1, Entries)),
    WindowUpdate = expect_send(),
    {ok, {window_update, 0, Inc}, _} = roadrunner_http2_frame:parse(WindowUpdate, 16384),
    ?assertEqual(Peak - 65535, Inc),
    cleanup(Pid, Ref).

bumped_stream_window_advertises_initial_window_size() ->
    %% stream_window = 4M, conn stays default. Expect SETTINGS WITH
    %% id 4 = 4M, NO follow-up WINDOW_UPDATE.
    StreamPeak = 4 * 1024 * 1024,
    {Pid, Ref} = start_conn(#{stream_window => StreamPeak}),
    Settings = expect_send(),
    {ok, {settings, 0, Entries}, _} = roadrunner_http2_frame:parse(Settings, 16384),
    ?assertEqual(StreamPeak, proplists:get_value(4, Entries)),
    ?assertEqual(no_send, drain_send(100)),
    cleanup(Pid, Ref).

bumped_both_emits_settings_with_size_then_window_update() ->
    %% Mint-style defaults: 16M / 4M. SETTINGS includes id 4 = 4M;
    %% WINDOW_UPDATE(0, 16M - 65535) follows.
    ConnPeak = 16 * 1024 * 1024,
    StreamPeak = 4 * 1024 * 1024,
    {Pid, Ref} = start_conn(#{
        conn_window => ConnPeak,
        stream_window => StreamPeak
    }),
    Settings = expect_send(),
    {ok, {settings, 0, Entries}, _} = roadrunner_http2_frame:parse(Settings, 16384),
    ?assertEqual(StreamPeak, proplists:get_value(4, Entries)),
    WindowUpdate = expect_send(),
    {ok, {window_update, 0, Inc}, _} = roadrunner_http2_frame:parse(WindowUpdate, 16384),
    ?assertEqual(ConnPeak - 65535, Inc),
    cleanup(Pid, Ref).

custom_threshold_changes_refill_trigger() ->
    %% Set the recv-window peak to 100 KB and the threshold to 50 KB.
    %% A single 60 KB DATA frame drops both windows below threshold,
    %% so the conn must emit a WINDOW_UPDATE on stream 0 AND on the
    %% stream id refilling each back to its peak. With the default
    %% threshold (32 KB) and peak (65 KB) those refills wouldn't fire
    %% until 33 KB had been consumed — this test asserts that the
    %% configured threshold is the one in effect.
    Peak = 100_000,
    Threshold = 50_000,
    {Pid, Ref} = start_conn(#{
        conn_window => Peak,
        stream_window => Peak,
        window_refill_threshold => Threshold
    }),
    %% Drain handshake init (SETTINGS + early WINDOW_UPDATE for the
    %% bumped conn peak).
    _ = expect_send(),
    _ = expect_send(),
    %% Feed peer preface + empty SETTINGS, drain ACK.
    serve_recv(Pid, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>),
    serve_recv(Pid, <<0:24, 4, 0, 0:32>>),
    _ = expect_send(),
    %% Open stream 1 with HEADERS for POST /, no END_STREAM (body
    %% follows). Use HPACK to encode the pseudo-headers.
    Enc = roadrunner_http2_hpack:new_encoder(4096),
    {Hpack, _} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"POST"},
            {~":scheme", ~"https"},
            {~":authority", ~"x"},
            {~":path", ~"/"}
        ],
        Enc
    ),
    HpackBin = iolist_to_binary(Hpack),
    HeadersFrame = iolist_to_binary(
        roadrunner_http2_frame:encode({headers, 1, 16#04, undefined, HpackBin})
    ),
    serve_recv(Pid, HeadersFrame),
    %% Six 10 KB DATA frames = 60 KB total. Each below the
    %% MAX_FRAME_SIZE cap of 16384. Conn + stream recv windows drop
    %% from 100 KB → 40 KB which is < 50 KB threshold → both refill.
    Chunk = binary:copy(<<"x">>, 10_000),
    [
        serve_recv(Pid, iolist_to_binary(roadrunner_http2_frame:encode({data, 1, 0, Chunk})))
     || _ <- lists:seq(1, 6)
    ],
    %% Expect 2 WINDOW_UPDATE frames — conn (stream 0) and stream 1.
    %% The refill brings each window back to its peak, so the
    %% increment is the bytes consumed since last refill.
    Wu1 = expect_send(),
    {ok, {window_update, S1, Inc1}, _} =
        roadrunner_http2_frame:parse(Wu1, 16384),
    Wu2 = expect_send(),
    {ok, {window_update, S2, Inc2}, _} =
        roadrunner_http2_frame:parse(Wu2, 16384),
    %% Both updates fire (one for conn, one for stream); we don't
    %% care about order. After 60 KB consumed, the increment that
    %% restores the window to 100 KB is exactly 60 KB.
    ?assertEqual(lists:sort([0, 1]), lists:sort([S1, S2])),
    ?assertEqual(60_000, Inc1),
    ?assertEqual(60_000, Inc2),
    cleanup(Pid, Ref).

invalid_window_opt_fails_listener_start() ->
    %% A non-positive integer (or anything outside 1..2^31-1) should
    %% surface at listener init/1 rather than mid-handshake. Each
    %% bad-opt case fails fast with
    %% `{invalid_listener_opt, protocols, _}`.
    process_flag(trap_exit, true),
    BadCases = [
        #{conn_window => 0},
        #{conn_window => -1},
        #{stream_window => 16#80000000},
        #{window_refill_threshold => not_an_integer},
        #{unknown_h2_opt => 1}
    ],
    [
        ?assertMatch(
            {error, {{invalid_listener_opt, protocols, _}, _}},
            roadrunner_listener:start_link(
                list_to_atom(
                    "h2_window_test_invalid_" ++
                        integer_to_list(erlang:unique_integer([positive]))
                ),
                #{port => 0, protocols => [{http2, H2}]}
            )
        )
     || H2 <- BadCases
    ],
    ok.

valid_window_opts_let_listener_boot() ->
    %% Companion to `invalid_window_opt_fails_listener_start/0`:
    %% the validator's success path (in-range integers under all
    %% three nested keys) is exercised by booting a listener with a
    %% tuned `{http2, _}` entry. The listener comes up clean.
    Name = list_to_atom(
        "h2_window_test_valid_" ++
            integer_to_list(erlang:unique_integer([positive]))
    ),
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0,
        protocols => [
            {http2, #{
                conn_window => 1_048_576,
                stream_window => 524_288,
                window_refill_threshold => 65_536
            }}
        ],
        routes => roadrunner_hello_handler
    }),
    ok = roadrunner_listener:stop(Name).

%% --- helpers ---------------------------------------------------

start_conn(H2Opts) ->
    %% `H2Opts` is the user-facing sub-opts map (keys: `conn_window`,
    %% `stream_window`, `window_refill_threshold`). Translate to the
    %% flat `http2_` prefix the conn loop reads via single `maps:get/2`.
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    Counter = atomics:new(1, [{signed, false}]),
    ok = atomics:add(Counter, 1, 1),
    ProtoOpts = #{
        client_counter => Counter,
        listener_name => h2_window_test,
        dispatch => {handler, roadrunner_hello_handler},
        middlewares => [],
        protocols => [http2],
        http2_conn_window => maps:get(conn_window, H2Opts, 65535),
        http2_stream_window => maps:get(stream_window, H2Opts, 65535),
        http2_window_refill_threshold => maps:get(window_refill_threshold, H2Opts, 32768)
    },
    Sock = {fake, Self},
    Pid = spawn(fun() ->
        receive
            ready -> ok
        end,
        roadrunner_conn_loop_http2:enter(
            Sock, ProtoOpts, h2_window_test, undefined, erlang:monotonic_time()
        )
    end),
    Ref = monitor(process, Pid),
    Pid ! ready,
    {Pid, Ref}.

expect_send() ->
    receive
        {roadrunner_fake_send, _Pid, Data} -> iolist_to_binary(Data)
    after 500 -> error(no_send)
    end.

drain_send(Timeout) ->
    receive
        {roadrunner_fake_send, _Pid, Data} -> iolist_to_binary(Data)
    after Timeout -> no_send
    end.

serve_recv(ConnPid, Data) ->
    drain_setopts(),
    ConnPid ! {roadrunner_fake_data, {fake, self()}, iolist_to_binary([Data])},
    ok.

drain_setopts() ->
    receive
        {roadrunner_fake_setopts, _, _} -> drain_setopts()
    after 0 -> ok
    end.

drain_mailbox() ->
    receive
        _ -> drain_mailbox()
    after 0 -> ok
    end.

cleanup(Pid, Ref) ->
    exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 500 -> ok
    end,
    drain_mailbox().
