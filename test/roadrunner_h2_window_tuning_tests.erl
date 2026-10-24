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
        fun default_advertises_100_max_concurrent_streams/0,
        fun custom_max_concurrent_streams_advertised/0,
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
    %% With this module's RFC-baseline windows (65535, see `start_conn/1`)
    %% the handshake emits no INITIAL_WINDOW_SIZE entry and no early
    %% WINDOW_UPDATE. The shipped defaults are covered by
    %% `roadrunner_conn_loop_http2_tests:default_receive_windows_advertised/0`.
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
    %% stream_window = 4M is a peak streams grow to, not advertised: the
    %% SETTINGS carries no id 4, so streams open at the RFC's 65535.
    StreamPeak = 4 * 1024 * 1024,
    {Pid, Ref} = start_conn(#{stream_window => StreamPeak}),
    Settings = expect_send(),
    {ok, {settings, 0, Entries}, _} = roadrunner_http2_frame:parse(Settings, 16384),
    ?assertEqual(false, lists:keymember(4, 1, Entries)),
    ?assertEqual(no_send, drain_send(100)),
    cleanup(Pid, Ref).

bumped_both_emits_settings_with_size_then_window_update() ->
    %% 16M / 4M: SETTINGS carries no id 4 (the stream peak is reached by
    %% refills); WINDOW_UPDATE(0, 16M - 65535) follows.
    ConnPeak = 16 * 1024 * 1024,
    StreamPeak = 4 * 1024 * 1024,
    {Pid, Ref} = start_conn(#{
        conn_window => ConnPeak,
        stream_window => StreamPeak
    }),
    Settings = expect_send(),
    {ok, {settings, 0, Entries}, _} = roadrunner_http2_frame:parse(Settings, 16384),
    ?assertEqual(false, lists:keymember(4, 1, Entries)),
    WindowUpdate = expect_send(),
    {ok, {window_update, 0, Inc}, _} = roadrunner_http2_frame:parse(WindowUpdate, 16384),
    ?assertEqual(ConnPeak - 65535, Inc),
    cleanup(Pid, Ref).

custom_threshold_changes_refill_trigger() ->
    %% Set the recv-window peaks to 100 KB and the threshold to 50 KB,
    %% for both windows: each refills to its peak once below it, not
    %% below half its own peak (also 50 KB here, so the stream's
    %% refill point at 45535 left proves nothing alone; the connection
    %% one, at 40 KB left after 60 KB, is the configured threshold).
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
    %% 10 KB DATA frames, each below the MAX_FRAME_SIZE cap of 16384. The
    %% stream opens at the RFC's 65535: after two frames it has 45535
    %% left, below the 50 KB threshold, and refills to its 100 KB peak.
    Chunk = binary:copy(<<"x">>, 10_000),
    Data = iolist_to_binary(roadrunner_http2_frame:encode({data, 1, 0, Chunk})),
    [serve_recv(Pid, Data) || _ <- [1, 2]],
    {ok, {window_update, 1, 54_465}, <<>>} = roadrunner_http2_frame:parse(expect_send(), 16384),
    %% Four more: 60 KB in, the connection window drops from 100 KB to
    %% 40 KB, below the threshold, and refills by exactly 60 KB.
    [serve_recv(Pid, Data) || _ <- [3, 4, 5, 6]],
    {ok, {window_update, 0, 60_000}, <<>>} = roadrunner_http2_frame:parse(expect_send(), 16384),
    cleanup(Pid, Ref).

default_advertises_100_max_concurrent_streams() ->
    %% With no override the handshake SETTINGS advertises
    %% MAX_CONCURRENT_STREAMS (id 3) = 100, the default.
    {Pid, Ref} = start_conn(#{}),
    Settings = expect_send(),
    {ok, {settings, 0, Entries}, _} = roadrunner_http2_frame:parse(Settings, 16384),
    ?assertEqual(100, proplists:get_value(3, Entries)),
    cleanup(Pid, Ref).

custom_max_concurrent_streams_advertised() ->
    %% max_concurrent_streams = 250 must be advertised as id 3 = 250.
    {Pid, Ref} = start_conn(#{max_concurrent_streams => 250}),
    Settings = expect_send(),
    {ok, {settings, 0, Entries}, _} = roadrunner_http2_frame:parse(Settings, 16384),
    ?assertEqual(250, proplists:get_value(3, Entries)),
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
                window_refill_threshold => 65_536,
                max_concurrent_streams => 250,
                max_header_block => 32_768
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
    {ok, _} = roadrunner_test_event_handler:start(),
    Self = self(),
    Counter = counters:new(1, [write_concurrency]),
    ok = counters:add(Counter, 1, 1),
    ProtoOpts = #{
        max_concurrent_requests => infinity,
        client_counter => Counter,
        listener_name => h2_window_test,
        dispatch =>
            {handler, roadrunner_hello_handler, fun roadrunner_hello_handler:handle/1, undefined},
        middlewares => [],
        handler_spawn_opts => [{fullsweep_after, 0}],
        tls_handshake_timeout => 5000,
        handler_start_timeout => infinity,
        protocols => [http2],
        http2_conn_window => maps:get(conn_window, H2Opts, 65535),
        http2_stream_window => maps:get(stream_window, H2Opts, 65535),
        http2_window_refill_threshold => maps:get(window_refill_threshold, H2Opts, 32768),
        http2_max_concurrent_streams => maps:get(max_concurrent_streams, H2Opts, 100)
    },
    Sock = {fake, Self},
    Pid = spawn(fun() ->
        receive
            ready -> ok
        end,
        roadrunner_conn_loop_http2:enter(
            Sock,
            ProtoOpts,
            h2_window_test,
            undefined,
            {erlang:monotonic_time(), h2_window_test, undefined},
            <<>>
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
