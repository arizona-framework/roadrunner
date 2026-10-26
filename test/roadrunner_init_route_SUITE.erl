-module(roadrunner_init_route_SUITE).
-moduledoc """
A handler's `init_route/1` on a real listener: it runs once per route when the
listener starts and again on `reload_routes/2`, its return is the state the
handler sees on a request, a raise stops the listener from starting, and the
single-handler `routes` forms run it too. The fixture
(`roadrunner_init_route_handler`) is also a `roadrunner_ws_handler`, so the
suite checks that its WebSocket `init/1` still runs only on an upgrade.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, end_per_testcase/2]).
-export([
    runs_once_per_route_at_start/1,
    runs_again_on_reload/1,
    raise_stops_the_listener_from_starting/1,
    raise_on_reload_keeps_the_old_routes/1,
    single_handler_forms_run_it/1,
    single_handler_raise_stops_the_listener/1,
    ws_init_still_runs_on_upgrade/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        runs_once_per_route_at_start,
        runs_again_on_reload,
        raise_stops_the_listener_from_starting,
        raise_on_reload_keeps_the_old_routes,
        single_handler_forms_run_it,
        single_handler_raise_stops_the_listener,
        ws_init_still_runs_on_upgrade
    ].

end_per_testcase(_Case, _Config) ->
    case whereis(?MODULE) of
        undefined -> ok;
        _Pid -> ok = roadrunner_listener:stop(?MODULE)
    end.

runs_once_per_route_at_start(_Config) ->
    A = #{notify => self(), route => a},
    B = #{notify => self(), route => b},
    Port = start(#{
        routes => [
            {~"/a", roadrunner_init_route_handler, A},
            #{path => ~"/b", handler => roadrunner_init_route_handler, state => B},
            {~"/plain", roadrunner_hello_handler}
        ]
    }),
    ?assertEqual([A, B], runs()),
    ?assertEqual({routed, A}, get_state(Port, ~"/a")),
    ?assertEqual({routed, B}, get_state(Port, ~"/b")),
    %% Requests reuse the state: nothing runs per request.
    ?assertEqual({routed, A}, get_state(Port, ~"/a")),
    ?assertEqual([], runs()).

runs_again_on_reload(_Config) ->
    Old = #{notify => self(), gen => 1},
    New = #{notify => self(), gen => 2},
    Port = start(#{routes => [{~"/a", roadrunner_init_route_handler, Old}]}),
    ?assertEqual([Old], runs()),
    ok = roadrunner_listener:reload_routes(?MODULE, [{~"/a", roadrunner_init_route_handler, New}]),
    ?assertEqual([New], runs()),
    ?assertEqual({routed, New}, get_state(Port, ~"/a")),
    %% A table `validate/1` refuses never reaches the hook.
    ?assertMatch(
        {error, {unreachable_route, 2, ~"/a", _}},
        roadrunner_listener:reload_routes(?MODULE, [
            {~"/a", roadrunner_init_route_handler, New},
            {~"/a", roadrunner_init_route_handler, New}
        ])
    ),
    ?assertEqual([], runs()).

raise_stops_the_listener_from_starting(_Config) ->
    process_flag(trap_exit, true),
    ?assertMatch(
        {error, {{init_route_failed, ~"/b", roadrunner_init_route_handler, bad_option}, _}},
        roadrunner_listener:start_link(?MODULE, #{
            port => 0,
            routes => [
                {~"/a", roadrunner_hello_handler},
                {~"/b", roadrunner_init_route_handler, #{raise => bad_option}}
            ]
        })
    ).

raise_on_reload_keeps_the_old_routes(_Config) ->
    %% A hook that fails for the new table refuses the reload: the caller gets
    %% the reason and the listener keeps serving the routes it had.
    Port = start(#{routes => [{~"/a", roadrunner_init_route_handler, #{v => old}}]}),
    Before = get_state(Port, ~"/a"),
    ?assertMatch(
        {error,
            {init_failed, {init_route_failed, ~"/a", roadrunner_init_route_handler, bad_option}}},
        roadrunner_listener:reload_routes(?MODULE, [
            {~"/a", roadrunner_init_route_handler, #{raise => bad_option}}
        ])
    ),
    ?assertEqual(Before, get_state(Port, ~"/a")).

single_handler_forms_run_it(_Config) ->
    State = #{notify => self()},
    Forms = [
        roadrunner_init_route_handler,
        {roadrunner_init_route_handler, State},
        #{handler => roadrunner_init_route_handler, state => State},
        #{handler => roadrunner_init_route_handler}
    ],
    Seen = [
        begin
            Port = start(#{routes => Form}),
            Got = get_state(Port, ~"/anything"),
            ok = roadrunner_listener:stop(?MODULE),
            Got
        end
     || Form <- Forms
    ],
    ?assertEqual(
        [{routed, undefined}, {routed, State}, {routed, State}, {routed, undefined}], Seen
    ),
    ?assertEqual([State, State], runs()).

single_handler_raise_stops_the_listener(_Config) ->
    process_flag(trap_exit, true),
    ?assertMatch(
        {error, {{init_route_failed, undefined, roadrunner_init_route_handler, bad_option}, _}},
        roadrunner_listener:start_link(?MODULE, #{
            port => 0,
            routes => {roadrunner_init_route_handler, #{raise => bad_option}}
        })
    ).

ws_init_still_runs_on_upgrade(_Config) ->
    State = #{notify => self()},
    Port = start(#{routes => [{~"/ws", roadrunner_init_route_handler, State}]}),
    ?assertEqual([State], runs()),
    %% The route compiled without touching the WebSocket `init/1`.
    receive
        {ws_init, _} -> error(ws_init_ran_at_compile)
    after 0 -> ok
    end,
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    ok = gen_tcp:send(Sock, [
        ~"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
        ~"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    ]),
    {ok, <<"HTTP/1.1 101 ", _/binary>> = Reply} = recv_until(Sock, <<>>, ~"ws-init"),
    ?assertNotEqual(nomatch, binary:match(Reply, ~"ws-init")),
    receive
        {ws_init, {routed, State}} -> ok
    end,
    ok = gen_tcp:close(Sock).

%% --- helpers ---

start(Opts) ->
    {ok, _} = roadrunner_listener:start_link(?MODULE, Opts#{port => 0}),
    roadrunner_listener:port(?MODULE).

%% The states `init_route/1` reported, in order.
runs() ->
    receive
        {init_route, State} -> [State | runs()]
    after 0 -> []
    end.

get_state(Port, Path) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    ok = gen_tcp:send(Sock, [~"GET ", Path, ~" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"]),
    {ok, Reply} = recv_until(Sock, <<>>, closed),
    ok = gen_tcp:close(Sock),
    [<<"HTTP/1.1 200 ", _/binary>>, Body] = binary:split(Reply, ~"\r\n\r\n"),
    binary_to_term(Body).

%% Read until `Marker` shows up in what arrived, or until the peer closes when
%% `Marker` is `closed`.
recv_until(Sock, Acc, Marker) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} ->
            Acc1 = <<Acc/binary, Data/binary>>,
            case Marker =/= closed andalso binary:match(Acc1, Marker) =/= nomatch of
                true -> {ok, Acc1};
                false -> recv_until(Sock, Acc1, Marker)
            end;
        {error, closed} when Marker =:= closed ->
            {ok, Acc}
    end.
