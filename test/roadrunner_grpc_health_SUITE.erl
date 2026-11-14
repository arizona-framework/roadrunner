-module(roadrunner_grpc_health_SUITE).
-moduledoc """
gRPC's health service (`roadrunner_grpc_health`) over HTTP/2: `Check`,
`List` and `Watch`, with statuses set by `roadrunner_grpc_health:set_status/2`.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    check_answers_the_status/1,
    check_unknown_is_not_found/1,
    list_answers_every_status/1,
    watch_sends_each_change/1,
    watch_ends_when_the_connection_goes/1,
    malformed_request_is_internal/1,
    watch_ends_on_drain/1,
    watch_ends_when_the_store_restarts/1,
    store_drops_stray_messages/1,
    watch_over_http3_ends_when_cancelled/1,
    watchers_of_one_service/1
]).
-export([init_per_group/2, end_per_group/2, groups/0]).

-define(PATH, ~"/grpc.health.v1.Health/").
-define(SVC, ~"test.Svc").

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        check_answers_the_status,
        check_unknown_is_not_found,
        list_answers_every_status,
        watch_sends_each_change,
        watch_ends_when_the_connection_goes,
        malformed_request_is_internal,
        watch_ends_on_drain,
        watch_ends_when_the_store_restarts,
        store_drops_stray_messages,
        watchers_of_one_service,
        {group, http3}
    ].

groups() ->
    [{http3, [], [watch_over_http3_ends_when_cancelled]}].

init_per_group(http3, Config) ->
    [{protocols, [http3]} | Config].

end_per_group(http3, _Config) ->
    ok.

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(roadrunner),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    Protocols = proplists:get_value(protocols, Config, [http2]),
    Tls =
        case Protocols of
            [http3] -> #{tls => roadrunner_test_certs:server_opts()};
            _ -> #{}
        end,
    {ok, _} = roadrunner_listener:start_link(?MODULE, Tls#{
        port => 0,
        protocols => Protocols,
        body_buffering => manual,
        routes => roadrunner_grpc:routes(#{services => [], health => true})
    }),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_grpc_health:set_status(?SVC, unknown),
    ok = roadrunner_grpc_health:set_status(~"", serving),
    case whereis(?MODULE) of
        undefined -> ok;
        _Listener -> ok = roadrunner_listener:stop(?MODULE)
    end.

check_answers_the_status(Config) ->
    %% The server's own status starts serving.
    ?assertEqual({ok, <<8, 1>>}, check(Config, <<>>)),
    ok = roadrunner_grpc_health:set_status(?SVC, not_serving),
    ?assertEqual({ok, <<8, 2>>}, check(Config, ?SVC)),
    ok = roadrunner_grpc_health:set_status(?SVC, serving),
    ?assertEqual({ok, <<8, 1>>}, check(Config, ?SVC)).

check_unknown_is_not_found(Config) ->
    ?assertEqual({status, ~"5"}, check(Config, ?SVC)),
    ok = roadrunner_grpc_health:set_status(?SVC, serving),
    ok = roadrunner_grpc_health:set_status(?SVC, unknown),
    ?assertEqual({status, ~"5"}, check(Config, ?SVC)).

list_answers_every_status(Config) ->
    ok = roadrunner_grpc_health:set_status(?SVC, not_serving),
    {_, [Reply], _, _} = roadrunner_grpc_test_client:call(
        open(Config), 1, <<?PATH/binary, "List">>, [<<>>]
    ),
    ?assertEqual(
        lists:sort([{<<>>, <<8, 1>>}, {?SVC, <<8, 2>>}]), lists:sort(list_entries(Reply))
    ).

%% Watch answers SERVICE_UNKNOWN for a service with no status, then each
%% change once, ignores other messages, and ends when the client resets.
watch_sends_each_change(Config) ->
    C0 = watch(Config, ?SVC),
    {<<8, 3>>, C1} = next_message(C0),
    Watcher = watcher(?SVC),
    MonRef = monitor(process, Watcher),
    Watcher ! unrelated,
    ok = roadrunner_grpc_health:set_status(?SVC, serving),
    {<<8, 1>>, C2} = next_message(C1),
    ok = roadrunner_grpc_health:set_status(?SVC, serving),
    ok = roadrunner_grpc_health:set_status(?SVC, not_serving),
    {<<8, 2>>, C3} = next_message(C2),
    _ = roadrunner_grpc_test_client:reset(C3, 1),
    receive
        {'DOWN', MonRef, process, Watcher, _} -> ok
    after 5000 -> ct:fail(watch_kept_running)
    end.

%% A watcher whose client's connection goes away ends too.
watch_ends_when_the_connection_goes(Config) ->
    #{sock := Sock} = C0 = watch(Config, ?SVC),
    {<<8, 3>>, _} = next_message(C0),
    Watcher = watcher(?SVC),
    MonRef = monitor(process, Watcher),
    ok = gen_tcp:close(Sock),
    receive
        {'DOWN', MonRef, process, Watcher, _} -> ok
    after 5000 -> ct:fail(watch_kept_running)
    end.

malformed_request_is_internal(Config) ->
    ?assertEqual({status, ~"13"}, check(Config, {raw, <<10, 9, "ab">>})),
    C = watch(Config, {raw, <<10, 9, "ab">>}),
    {Headers, [], trailers_only, _} = roadrunner_grpc_test_client:response(C, 1),
    ?assertEqual(~"13", proplists:get_value(~"grpc-status", Headers)).

%% A listener that drains has a Watch send NOT_SERVING and end, so the
%% drain does not wait out its timeout.
watch_ends_on_drain(Config) ->
    %% A watcher of a service with no status is not told NOT_SERVING: its
    %% call just ends.
    Unknown = watch(Config, ?SVC),
    {<<8, 3>>, Unknown1} = next_message(Unknown),
    %% Nor is one that was sent NOT_SERVING already.
    ok = roadrunner_grpc_health:set_status(~"test.Down", not_serving),
    Down = watch(Config, ~"test.Down"),
    {<<8, 2>>, Down1} = next_message(Down),
    C0 = watch(Config, <<>>),
    {<<8, 1>>, C1} = next_message(C0),
    Self = self(),
    _ = spawn(fun() -> Self ! {drained, roadrunner_listener:drain(?MODULE, 10_000)} end),
    {<<8, 2>>, _} = next_message(C1),
    {Trailers, _} = roadrunner_grpc_test_client:trailers(Unknown1, 1),
    ?assertEqual(~"0", proplists:get_value(~"grpc-status", Trailers)),
    {DownTrailers, _} = roadrunner_grpc_test_client:trailers(Down1, 1),
    ?assertEqual(~"0", proplists:get_value(~"grpc-status", DownTrailers)),
    ok = roadrunner_grpc_health:set_status(~"test.Down", unknown),
    receive
        {drained, Result} -> ?assertEqual({ok, drained}, Result)
    after 5000 -> ct:fail(drain_waited)
    end.

%% The statuses go with their store: a Watch ends UNAVAILABLE, and the
%% restarted store starts over with the server serving.
watch_ends_when_the_store_restarts(Config) ->
    ok = roadrunner_grpc_health:set_status(?SVC, not_serving),
    C0 = watch(Config, ?SVC),
    {<<8, 2>>, C1} = next_message(C0),
    Store = whereis(roadrunner_grpc_health_store),
    StoreRef = monitor(process, Store),
    true = exit(Store, kill),
    receive
        {'DOWN', StoreRef, process, Store, _} -> ok
    end,
    {Trailers, _} = roadrunner_grpc_test_client:trailers(C1, 1),
    ?assertEqual(~"14", proplists:get_value(~"grpc-status", Trailers)),
    ok = wait_for_store(),
    ?assertEqual({ok, <<8, 1>>}, check(Config, <<>>)),
    ?assertEqual({status, ~"5"}, check(Config, ?SVC)).

%% Anything else sent to the store is dropped; it keeps its statuses.
store_drops_stray_messages(Config) ->
    ok = roadrunner_grpc_health:set_status(?SVC, not_serving),
    Store = whereis(roadrunner_grpc_health_store),
    Store ! stray,
    Store ! {'DOWN', make_ref(), process, self(), normal},
    ok = gen_server:cast(Store, stray),
    %% A call answers once the store handled all three before it.
    _ = sys:get_state(Store),
    ?assertEqual(Store, whereis(roadrunner_grpc_health_store)),
    ?assertEqual({ok, <<8, 2>>}, check(Config, ?SVC)).

%% Over HTTP/3, a Watch the client cancels (RESET_STREAM and STOP_SENDING)
%% ends.
watch_over_http3_ends_when_cancelled(Config) ->
    {ok, Conn} = roadrunner_quic_test_h3:connect({127, 0, 0, 1}, ?config(port, Config)),
    Fields = [
        {~":method", ~"POST"},
        {~":scheme", ~"https"},
        {~":authority", ~"localhost"},
        {~":path", <<?PATH/binary, "Watch">>},
        {~"content-type", ~"application/grpc"},
        {~"te", ~"trailers"}
    ],
    {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, Fields, false),
    ok = roadrunner_quic_test_h3:send_data(
        Conn, StreamId, iolist_to_binary(roadrunner_grpc_frame:encode(false, request(?SVC))), true
    ),
    receive
        {quic_test_stream, Conn, StreamId, _Bytes, false} -> ok
    after 5000 -> ct:fail(no_status)
    end,
    Watcher = watcher(?SVC),
    MonRef = monitor(process, Watcher),
    _ = roadrunner_quic_test_h3:cancel(Conn, StreamId),
    receive
        {'DOWN', MonRef, process, Watcher, _} -> ok
    after 5000 -> ct:fail(watch_kept_running)
    end,
    _ = roadrunner_quic_test_h3:close(Conn),
    ok.

%% Two watchers of one service: one ending leaves the other told.
watchers_of_one_service(Config) ->
    A = watch(Config, ?SVC),
    {<<8, 3>>, A1} = next_message(A),
    B = watch(Config, ?SVC),
    {<<8, 3>>, B1} = next_message(B),
    {store, #{?SVC := Of}, _} = sys:get_state(roadrunner_grpc_health_store),
    [First, Second] = maps:values(Of),
    MonRef = monitor(process, First),
    Second ! unrelated,
    _ = roadrunner_grpc_test_client:reset(A1, 1),
    _ = roadrunner_grpc_test_client:reset(B1, 1),
    receive
        {'DOWN', MonRef, process, First, _} -> ok
    after 5000 -> ct:fail(watch_kept_running)
    end,
    %% Both calls are reset; the store forgets each as it ends.
    SecondRef = monitor(process, Second),
    receive
        {'DOWN', SecondRef, process, Second, _} -> ok
    after 5000 -> ct:fail(watch_kept_running)
    end,
    _ = sys:get_state(roadrunner_grpc_health_store),
    {store, Watchers, Services} = sys:get_state(roadrunner_grpc_health_store),
    ?assertEqual({0, 0}, {map_size(Watchers), map_size(Services)}).

%% --- helpers ---

wait_for_store() ->
    %% The supervisor answers only after it handled the store's exit, so
    %% the restarted store is up by then.
    _ = sys:get_status(roadrunner_sup),
    true = is_pid(whereis(roadrunner_grpc_health_store)),
    ok.

open(Config) ->
    roadrunner_grpc_test_client:open(?config(port, Config)).

request({raw, Bytes}) -> Bytes;
request(<<>>) -> <<>>;
request(Service) -> <<10, (byte_size(Service)), Service/binary>>.

%% `{ok, Response}`, or `{status, Code}` for a call that failed.
check(Config, Service) ->
    case
        roadrunner_grpc_test_client:call(open(Config), 1, <<?PATH/binary, "Check">>, [
            request(Service)
        ])
    of
        {_, [Reply], _, _} -> {ok, Reply};
        {Headers, [], trailers_only, _} -> {status, proplists:get_value(~"grpc-status", Headers)}
    end.

watch(Config, Service) ->
    C0 = roadrunner_grpc_test_client:start(open(Config), 1, <<?PATH/binary, "Watch">>, []),
    C1 = roadrunner_grpc_test_client:send(
        C0, 1, iolist_to_binary(roadrunner_grpc_frame:encode(false, request(Service)))
    ),
    roadrunner_grpc_test_client:finish(C1, 1).

next_message(C) ->
    case roadrunner_grpc_test_client:next_frame(C) of
        {{data, 1, _, Data, _}, C1} ->
            {ok, false, Message, <<>>} = roadrunner_grpc_frame:decode(Data, 1024),
            {Message, C1};
        {_Other, C1} ->
            next_message(C1)
    end.

%% The process watching `Service`, from the store's watchers.
watcher(Service) ->
    {store, #{Service := Of}, _} = sys:get_state(roadrunner_grpc_health_store),
    [Pid] = maps:values(Of),
    Pid.

%% HealthListResponse's entries, as {Service, HealthCheckResponse}.
list_entries(<<10, Len, Entry:Len/binary, Rest/binary>>) ->
    <<10, KeyLen, Key:KeyLen/binary, 18, ValLen, Val:ValLen/binary>> = Entry,
    [{Key, Val} | list_entries(Rest)];
list_entries(<<>>) ->
    [].
