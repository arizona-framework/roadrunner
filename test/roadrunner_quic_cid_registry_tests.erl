-module(roadrunner_quic_cid_registry_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_cid_registry).

register_pair_routes_both_ids_test() ->
    %% Both the client DCID and the server SCID route to the connection pid.
    Table = ?M:new(),
    Pid = self(),
    ok = ?M:register_pair(Table, ~"client-dcid", ~"server-scid", Pid),
    ?assertEqual({ok, Pid}, ?M:lookup(Table, ~"client-dcid")),
    ?assertEqual({ok, Pid}, ?M:lookup(Table, ~"server-scid")).

lookup_unknown_cid_is_error_test() ->
    Table = ?M:new(),
    ?assertEqual(error, ?M:lookup(Table, ~"never-registered")).

delete_pid_drops_all_its_ids_test() ->
    %% Ending a connection removes every id that routed to it, leaving other
    %% connections' ids intact.
    Table = ?M:new(),
    Gone = spawn(fun() -> ok end),
    Kept = self(),
    ok = ?M:register_pair(Table, ~"gone-dcid", ~"gone-scid", Gone),
    ok = ?M:register_pair(Table, ~"kept-dcid", ~"kept-scid", Kept),
    ok = ?M:delete_pid(Table, Gone),
    ?assertEqual(error, ?M:lookup(Table, ~"gone-dcid")),
    ?assertEqual(error, ?M:lookup(Table, ~"gone-scid")),
    ?assertEqual({ok, Kept}, ?M:lookup(Table, ~"kept-dcid")),
    ?assertEqual({ok, Kept}, ?M:lookup(Table, ~"kept-scid")).
