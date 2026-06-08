-module(roadrunner_quic_test_h3_SUITE).
-moduledoc false.

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([native_client_get/1, native_client_post/1]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [native_client_get, native_client_post].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(ssl),
    %% The h3 listener's drain group lives in the default `pg` scope; start it
    %% unlinked so it outlives this transient process. Neither the native
    %% server nor the native client needs the `quic` app.
    ok = ensure_pg_started(),
    Config.

end_per_suite(_Config) ->
    ok.

%% A default single-handler h3 listener per testcase (start_link binds it to
%% the testcase process, RFC-legal h3 responses only).
init_per_testcase(_Case, Config) ->
    {ok, _} = roadrunner_listener:start_link(?MODULE, #{
        port => 0,
        protocols => [http3],
        tls => roadrunner_test_certs:server_opts(),
        routes => roadrunner_h3_test_handler
    }),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    _ = roadrunner_listener:stop(?MODULE),
    ok.

%% =============================================================================
%% The native HTTP/3 client drives the native h3 server end to end, no dep.
%% =============================================================================

native_client_get(Config) ->
    Port = ?config(port, Config),
    {ok, Conn} = roadrunner_quic_test_h3:connect({127, 0, 0, 1}, Port),
    {Status, _Headers, Body} = roadrunner_quic_test_h3:get(Conn, ~"/method"),
    ok = roadrunner_quic_test_h3:close(Conn),
    ?assertEqual(200, Status),
    ?assertEqual(~"GET", Body).

native_client_post(Config) ->
    Port = ?config(port, Config),
    {ok, Conn} = roadrunner_quic_test_h3:connect({127, 0, 0, 1}, Port),
    {Status, _Headers, Body} = roadrunner_quic_test_h3:post(Conn, ~"/echo", ~"hello there"),
    ok = roadrunner_quic_test_h3:close(Conn),
    ?assertEqual(200, Status),
    ?assertEqual(~"hello there", Body).

%% =============================================================================
%% Helpers
%% =============================================================================

ensure_pg_started() ->
    case whereis(pg) of
        undefined ->
            case pg:start_link() of
                {ok, Pid} ->
                    _ = unlink(Pid),
                    ok;
                {error, {already_started, _}} ->
                    ok
            end;
        _ ->
            ok
    end.
