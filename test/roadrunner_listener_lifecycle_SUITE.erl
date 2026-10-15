-module(roadrunner_listener_lifecycle_SUITE).
-moduledoc """
How a listener under `roadrunner_sup` ends: stopped, drained, failing to
start, or taken down by a linked process. Each way leaves nothing published
behind, an abnormal exit of a linked process still restarts the listener,
and a drained listener stays down until started again.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([
    stop_listener_erases_published_terms/1,
    failed_start_erases_published_terms/1,
    crashed_acceptor_restarts_the_listener/1,
    normal_exit_of_a_linked_process_is_ignored/1,
    drained_listener_stays_down/1,
    drained_listener_starts_again/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        stop_listener_erases_published_terms,
        failed_start_erases_published_terms,
        crashed_acceptor_restarts_the_listener,
        normal_exit_of_a_linked_process_is_ignored,
        drained_listener_stays_down,
        drained_listener_starts_again
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(roadrunner),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(roadrunner).

stop_listener_erases_published_terms(_Config) ->
    {ok, _} = roadrunner:start_listener(lifecycle_stop, opts(0)),
    ?assertEqual(2, length(published(lifecycle_stop))),
    ok = roadrunner:stop_listener(lifecycle_stop),
    ?assertEqual([], published(lifecycle_stop)).

failed_start_erases_published_terms(_Config) ->
    %% The port is taken, so the listen fails after the routes went out.
    {ok, Taken} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(Taken),
    try
        ?assertMatch({error, _}, roadrunner:start_listener(lifecycle_taken, opts(Port))),
        ?assertEqual([], published(lifecycle_taken))
    after
        ok = gen_tcp:close(Taken)
    end.

crashed_acceptor_restarts_the_listener(_Config) ->
    %% The listener shares its acceptors' fate: one crashing takes it down,
    %% through its cleanup, and its supervisor starts it again.
    {ok, Pid} = roadrunner:start_listener(lifecycle_crash, opts(0)),
    Mon = monitor(process, Pid),
    exit(acceptor(Pid), crash),
    receive
        {'DOWN', Mon, process, Pid, Reason} -> ?assertEqual(crash, Reason)
    end,
    [Restarted] = [P || {lifecycle_crash, P, _, _} <- supervisor:which_children(roadrunner_sup)],
    ?assertNotEqual(Pid, Restarted),
    ?assertEqual(2, length(published(lifecycle_crash))),
    ok = roadrunner:stop_listener(lifecycle_crash).

normal_exit_of_a_linked_process_is_ignored(_Config) ->
    {ok, Pid} = roadrunner:start_listener(lifecycle_normal, opts(0)),
    Pid ! {'EXIT', acceptor(Pid), normal},
    ?assertEqual(Pid, whereis(lifecycle_normal)),
    ?assert(is_integer(roadrunner_listener:port(lifecycle_normal))),
    ok = roadrunner:stop_listener(lifecycle_normal).

drained_listener_stays_down(_Config) ->
    %% Drain ends the listener normally, so its supervisor leaves it down.
    {ok, Pid} = roadrunner:start_listener(lifecycle_drain, opts(0)),
    Mon = monitor(process, Pid),
    ?assertEqual({ok, drained}, roadrunner_listener:drain(lifecycle_drain, 1000)),
    receive
        {'DOWN', Mon, process, Pid, Reason} -> ?assertEqual(normal, Reason)
    end,
    ?assertMatch(
        [undefined], [P || {lifecycle_drain, P, _, _} <- supervisor:which_children(roadrunner_sup)]
    ),
    ?assertEqual(undefined, whereis(lifecycle_drain)),
    ?assertNot(lists:member(lifecycle_drain, roadrunner:listeners())),
    ?assertEqual([], published(lifecycle_drain)),
    ok = roadrunner:stop_listener(lifecycle_drain),
    ?assertEqual({error, not_found}, roadrunner:stop_listener(lifecycle_drain)).

drained_listener_starts_again(_Config) ->
    {ok, Pid} = roadrunner:start_listener(lifecycle_redrain, opts(0)),
    Mon = monitor(process, Pid),
    ?assertEqual({ok, drained}, roadrunner_listener:drain(lifecycle_redrain, 1000)),
    receive
        {'DOWN', Mon, process, Pid, _} -> ok
    end,
    {ok, Again} = roadrunner:start_listener(lifecycle_redrain, opts(0)),
    ?assertNotEqual(Pid, Again),
    ?assertEqual(Again, whereis(lifecycle_redrain)),
    ?assert(lists:member(lifecycle_redrain, roadrunner:listeners())),
    ok = roadrunner:stop_listener(lifecycle_redrain).

%% --- helpers ---

%% A route with its own `rate_limit`, so the listener publishes both its
%% routes and its route bucket store.
opts(Port) ->
    #{
        port => Port,
        routes => [
            #{path => ~"/", handler => roadrunner_hello_handler, rate_limit => #{rate => 1}}
        ]
    }.

published(Name) ->
    [K || {{_, N} = K, _} <- persistent_term:get(), N =:= Name].

%% One of the listener's linked acceptors.
acceptor(ListenerPid) ->
    {links, Links} = process_info(ListenerPid, links),
    hd([P || P <- Links, is_pid(P), acceptor_label(P)]).

acceptor_label(Pid) ->
    case proc_lib:get_label(Pid) of
        {roadrunner_acceptor, _, _} -> true;
        _ -> false
    end.
