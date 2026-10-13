-module(roadrunner_listener_lifecycle_SUITE).
-moduledoc """
How a listener under `roadrunner_sup` ends: stopped, failing to start, or
taken down by a linked process. Each way leaves nothing published behind,
and an abnormal exit of a linked process still restarts the listener.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([
    stop_listener_erases_published_terms/1,
    failed_start_erases_published_terms/1,
    crashed_acceptor_restarts_the_listener/1,
    normal_exit_of_a_linked_process_is_ignored/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        stop_listener_erases_published_terms,
        failed_start_erases_published_terms,
        crashed_acceptor_restarts_the_listener,
        normal_exit_of_a_linked_process_is_ignored
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
