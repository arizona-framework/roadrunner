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

add_and_remove_route_an_issued_id_test() ->
    %% A spare id the connection issued routes to it once added, and stops
    %% routing once removed (the peer retired it).
    Table = ?M:new(),
    Pid = self(),
    ok = ?M:add(Table, ~"spare-cid", Pid),
    ?assertEqual({ok, Pid}, ?M:lookup(Table, ~"spare-cid")),
    ok = ?M:remove(Table, ~"spare-cid", Pid),
    ?assertEqual(error, ?M:lookup(Table, ~"spare-cid")).

remove_leaves_another_owners_route_test() ->
    %% An id since taken over by another connection keeps routing there when
    %% its former owner removes it.
    Table = ?M:new(),
    Former = spawn(fun() -> ok end),
    Owner = self(),
    ok = ?M:add(Table, ~"cid", Former),
    ok = ?M:add(Table, ~"cid", Owner),
    ok = ?M:remove(Table, ~"cid", Former),
    ?assertEqual({ok, Owner}, ?M:lookup(Table, ~"cid")).

delete_pid_drops_added_ids_test() ->
    %% The listener's cleanup reaps the ids a connection added itself too.
    Table = ?M:new(),
    Gone = spawn(fun() -> ok end),
    ok = ?M:register_pair(Table, ~"dcid", ~"scid", Gone),
    ok = ?M:add(Table, ~"spare-cid", Gone),
    ok = ?M:delete_pid(Table, Gone),
    ?assertEqual(error, ?M:lookup(Table, ~"spare-cid")).

reset_token_test() ->
    %% RFC 9000 §10.3.2: a 16-byte token, the same for an id under one key
    %% (every listener of a pool derives it alike), different for another id
    %% or another key.
    Key = ?M:reset_key(?M:new()),
    ?assertEqual(32, byte_size(Key)),
    Token = ?M:reset_token(Key, ~"cid-one"),
    ?assertEqual(16, byte_size(Token)),
    ?assertEqual(Token, ?M:reset_token(Key, ~"cid-one")),
    ?assertNotEqual(Token, ?M:reset_token(Key, ~"cid-two")),
    ?assertNotEqual(Token, ?M:reset_token(?M:reset_key(?M:new()), ~"cid-one")),
    ?assertEqual(
        crypto:macN(hmac, sha256, Key, ~"cid-one", 16), Token
    ).

remove_all_drops_a_closing_connections_ids_test() ->
    %% A closing connection removes its own ids one by one, leaving any id
    %% another connection holds and every other connection's routes.
    Table = ?M:new(),
    Closing = spawn(fun() -> ok end),
    Other = self(),
    ok = ?M:register_pair(Table, ~"dcid", ~"scid", Closing),
    ok = ?M:add(Table, ~"spare-cid", Closing),
    ok = ?M:add(Table, ~"taken-cid", Other),
    ok = ?M:add(Table, ~"other-cid", Other),
    ok = ?M:remove_all(Table, [~"dcid", ~"scid", ~"spare-cid", ~"taken-cid"], Closing),
    ?assertEqual(error, ?M:lookup(Table, ~"dcid")),
    ?assertEqual(error, ?M:lookup(Table, ~"scid")),
    ?assertEqual(error, ?M:lookup(Table, ~"spare-cid")),
    ?assertEqual({ok, Other}, ?M:lookup(Table, ~"taken-cid")),
    ?assertEqual({ok, Other}, ?M:lookup(Table, ~"other-cid")).

secret_derives_the_reset_key_test() ->
    %% A namespace made from a secret derives the same reset key from it
    %% every time (so a restart, or another server given the secret, issues
    %% the same tokens), never the secret itself, and another secret gives
    %% another key. A random namespace gets a key of its own.
    Secret = <<42:256>>,
    Key = ?M:reset_key(?M:new(Secret)),
    ?assertEqual(Key, ?M:reset_key(?M:new(Secret))),
    ?assertEqual(32, byte_size(Key)),
    ?assertNotEqual(Secret, Key),
    ?assertNotEqual(Key, ?M:reset_key(?M:new(<<43:256>>))),
    ?assertNotEqual(Key, ?M:reset_key(?M:new())),
    %% A secret shorter than 32 bytes is refused.
    ?assertError(function_clause, ?M:new(<<1:248>>)).

client_reset_tokens_route_to_their_connection_test() ->
    %% A client's stateless reset token routes to the connection holding it
    %% until removed; a row since taken over by another connection keeps its
    %% route, and the tokens never route as connection ids.
    Table = ?M:new(),
    Pid = self(),
    Other = spawn(fun() -> ok end),
    ok = ?M:add_reset(Table, <<1:128>>, Pid),
    ok = ?M:add_reset(Table, <<2:128>>, Pid),
    ?assertEqual({ok, Pid}, ?M:lookup_reset(Table, <<1:128>>)),
    ?assertEqual(error, ?M:lookup(Table, <<1:128>>)),
    ?assertEqual(error, ?M:lookup_reset(Table, <<3:128>>)),
    ok = ?M:add_reset(Table, <<2:128>>, Other),
    ok = ?M:remove_resets(Table, [<<1:128>>, <<2:128>>], Pid),
    ?assertEqual(error, ?M:lookup_reset(Table, <<1:128>>)),
    ?assertEqual({ok, Other}, ?M:lookup_reset(Table, <<2:128>>)),
    %% The listener's cleanup of a crashed connection reaps its tokens too.
    ok = ?M:delete_pid(Table, Other),
    ?assertEqual(error, ?M:lookup_reset(Table, <<2:128>>)).
