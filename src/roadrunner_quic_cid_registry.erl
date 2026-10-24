-module(roadrunner_quic_cid_registry).
-moduledoc false.

%% The connection-id namespace of a native QUIC listener (or a SO_REUSEPORT
%% pool of them): the connection-id -> connection-pid routing table (an ETS
%% set) and the keys derived from the namespace's secret.
%%
%% A received datagram is routed to its owning connection by the Destination
%% Connection ID in its header. A connection is registered under BOTH the
%% client's original DCID (which the peer uses on its early Initials) and the
%% server's issued SCID (which the peer echoes once it learns it, and which
%% every fixed-length short-header 1-RTT packet carries), so either addressing
%% finds the connection (RFC 9000 §5.1). The connection adds the spare ids it
%% issues later with NEW_CONNECTION_ID (§5.1.1) itself, and removes each one
%% the peer retires (§19.16). The table is `public` so a SO_REUSEPORT pool can
%% share one manager-held table across its listeners, and a connection can
%% route its own ids.
%%
%% The same table also routes the client's stateless reset tokens (RFC 9000
%% §10.3.1): a client that has lost its state answers our packets with a
%% stateless reset whose leading bytes are random, so it routes by no
%% connection id, and the listener looks its last 16 bytes up here instead.
%% A token is stored transformed, as the HMAC of it under a key of this
%% namespace, so the lookup's timing reveals nothing about the tokens held
%% (§10.3.1 names this way); the `{reset, _}` key keeps the rows apart from
%% the connection ids.
%%
%% Cleanup: a connection that closes removes its own rows on the way out
%% (remove_all/3 and remove_resets/3, one delete per row); one that crashes
%% or is killed cannot, so the listener, which links each connection, calls
%% delete_pid/2 when one ends any other way. Between a connection ending and
%% that cleanup, lookup/2 may briefly return its now-dead pid; routing a
%% datagram there is a harmless no-op (the message is dropped) and is the
%% right outcome anyway (a datagram for a gone connection should be dropped).
%% A registration for an id already held by another pid (a recycled or,
%% astronomically, colliding client DCID) overwrites it; the previous pid's
%% other ids are reaped by its own cleanup, and its removal of the
%% overwritten id leaves the new owner's row alone.
%%
%% The namespace's secret (the listener's `secret` option, or a random one)
%% is never used directly: HKDF (RFC 5869) extracts a key from it, and each
%% purpose expands its own key under a distinct label. The stateless reset
%% key is one of them, so every listener of a pool, and every server given
%% the same secret, derives the same token for an id: a stateless reset
%% token is the HMAC-SHA256 of the connection id under it, truncated to 16
%% bytes (RFC 9000 §10.3.2). It is unpredictable without the key, distinct
%% per id, and needs no per-connection state to recompute, so a restarted
%% server can still reset a connection it has forgotten. The address
%% validation token key (`roadrunner_quic_token`, RFC 9000 §8.1.3) is
%% another, so a token one server issued opens on every server given the
%% secret.
%%
%% The namespace also keeps the tokens already spent (RFC 9000 §8.1.4: a
%% NEW_TOKEN token SHOULD NOT be accepted more than once), in a second
%% table ordered by issue time, so the ones too old to be accepted anyway
%% are dropped from its front as new ones are spent. Past ?SPENT_LIMIT
%% held, a token is refused rather than remembered, which costs a returning
%% client only the address validation a client without one goes through.
%% The set is per namespace: another server, or this one after a restart,
%% may accept a token once more within its lifetime.

-export([new/0, new/1, register_pair/4, add/3, remove/3, remove_all/3, lookup/2, delete_pid/2]).
-export([reset_key/1, reset_token/2]).
-export([add_reset/3, remove_resets/3, lookup_reset/2]).
-export([token_key/1, spend_token/3]).

-export_type([t/0]).

%% RFC 9000 §10.3: a stateless reset token is 16 bytes.
-define(TOKEN_LEN, 16).
%% The HKDF-Extract salt the namespace's keys are extracted with, and the
%% HKDF-Expand label of each purpose (RFC 5869 §3.1, §3.2: distinct labels
%% give independent keys from one secret).
-define(KEY_SALT, ~"roadrunner quic v1").
-define(RESET_LABEL, ~"stateless reset").
-define(TOKEN_LABEL, ~"address token").
%% The most spent tokens a namespace remembers (each about a hundred bytes).
-define(SPENT_LIMIT, 100000).

-record(registry, {
    table :: ets:table(),
    reset_key :: binary(),
    %% The key the client's stateless reset tokens are stored under. Those
    %% rows live only as long as their connections, so it is random per
    %% namespace and never derived from the secret.
    peer_reset_key :: binary(),
    %% The key address validation tokens are sealed under.
    token_key :: <<_:256>>,
    %% The tokens spent, as `{{IssuedAt, Nonce}}` rows of an ordered set.
    spent :: ets:table()
}).

-opaque t() :: #registry{}.

-doc """
Create an empty routing table, owned by the calling process, with keys
derived from a fresh random secret, so its stateless reset tokens last only
as long as the table.
""".
-spec new() -> t().
new() ->
    new(crypto:strong_rand_bytes(32)).

-doc """
Create an empty routing table, owned by the calling process, with keys
derived from `Secret` (at least 32 bytes), so the stateless reset token of
an id stays the same across restarts and on every server given the secret.
""".
-spec new(binary()) -> t().
new(Secret) when byte_size(Secret) >= 32 ->
    Prk = roadrunner_quic_hkdf:extract(sha256, ?KEY_SALT, Secret),
    #registry{
        table = ets:new(?MODULE, [
            set, public, {read_concurrency, true}, {write_concurrency, auto}
        ]),
        reset_key = roadrunner_quic_hkdf:expand(sha256, Prk, ?RESET_LABEL, 32),
        peer_reset_key = crypto:strong_rand_bytes(32),
        token_key = roadrunner_quic_hkdf:expand(sha256, Prk, ?TOKEN_LABEL, 32),
        spent = ets:new(?MODULE, [ordered_set, public, {write_concurrency, auto}])
    }.

-doc """
Route a connection's client DCID and server SCID to its pid (the dual
registration of RFC 9000 §5.1), so a datagram addressed to either id reaches
the connection.
""".
-spec register_pair(t(), binary(), binary(), pid()) -> ok.
register_pair(#registry{table = Table}, DCID, SCID, Pid) ->
    true = ets:insert(Table, [{DCID, Pid}, {SCID, Pid}]),
    ok.

-doc """
Route one more connection id to `Pid`: a spare id the connection issued with
NEW_CONNECTION_ID (RFC 9000 §5.1.1).
""".
-spec add(t(), binary(), pid()) -> ok.
add(#registry{table = Table}, CID, Pid) ->
    true = ets:insert(Table, {CID, Pid}),
    ok.

-doc """
Stop routing a connection id the peer retired (RFC 9000 §19.16). Only the
row routing it to `Pid` is removed, so an id since taken over by another
connection keeps its route.
""".
-spec remove(t(), binary(), pid()) -> ok.
remove(#registry{table = Table}, CID, Pid) ->
    true = ets:delete_object(Table, {CID, Pid}),
    ok.

-doc """
Stop routing every one of a closing connection's ids to `Pid`, one delete
per id, so its normal exit spares the listener the whole-table scan of
delete_pid/2. As with remove/3, an id since taken over by another
connection keeps its route.
""".
-spec remove_all(t(), [binary()], pid()) -> ok.
remove_all(#registry{table = Table}, CIDs, Pid) ->
    lists:foreach(fun(CID) -> true = ets:delete_object(Table, {CID, Pid}) end, CIDs).

-doc "The connection owning a destination connection id, if one is registered.".
-spec lookup(t(), binary()) -> {ok, pid()} | error.
lookup(#registry{table = Table}, CID) ->
    case ets:lookup(Table, CID) of
        [{_CID, Pid}] -> {ok, Pid};
        [] -> error
    end.

-doc """
Drop every connection id routing to `Pid` (its connection has ended without
removing its own): a scan of the whole table.
""".
-spec delete_pid(t(), pid()) -> ok.
delete_pid(#registry{table = Table}, Pid) ->
    true = ets:match_delete(Table, {'_', Pid}),
    ok.

-doc """
Route a stateless reset token the client gave with NEW_CONNECTION_ID (RFC
9000 §10.3.1) to `Pid`, so a reset from a client that has lost its state
reaches the connection, which decides whether it is one.
""".
-spec add_reset(t(), <<_:128>>, pid()) -> ok.
add_reset(#registry{table = Table, peer_reset_key = Key}, Token, Pid) ->
    true = ets:insert(Table, {reset_row(Key, Token), Pid}),
    ok.

-doc """
Stop routing the client's stateless reset tokens to `Pid`: tokens of ids it
retired, or every one of a closing connection. As with remove/3, a row since
taken over by another connection keeps its route.
""".
-spec remove_resets(t(), [<<_:128>>], pid()) -> ok.
remove_resets(#registry{table = Table, peer_reset_key = Key}, Tokens, Pid) ->
    lists:foreach(
        fun(Token) -> true = ets:delete_object(Table, {reset_row(Key, Token), Pid}) end, Tokens
    ).

-doc """
The connection holding the client stateless reset token `Tail` (the last 16
bytes of a datagram that routes by no connection id), if one does.
""".
-spec lookup_reset(t(), <<_:128>>) -> {ok, pid()} | error.
lookup_reset(#registry{table = Table, peer_reset_key = Key}, Tail) ->
    case ets:lookup(Table, reset_row(Key, Tail)) of
        [{_Row, Pid}] -> {ok, Pid};
        [] -> error
    end.

%% A client token's row key: its HMAC under the namespace's key (RFC 9000
%% §10.3.1), never the token itself.
-spec reset_row(binary(), <<_:128>>) -> {reset, binary()}.
reset_row(Key, Token) ->
    {reset, crypto:macN(hmac, sha256, Key, Token, ?TOKEN_LEN)}.

-doc "The key the namespace's address validation tokens are sealed under.".
-spec token_key(t()) -> <<_:256>>.
token_key(#registry{token_key = Key}) ->
    Key.

-doc """
Spend the token `Id` (its issue time and nonce, from
`roadrunner_quic_token:open/4`): `true` the first time, `false` once spent
or when the namespace already holds ?SPENT_LIMIT spent tokens. Spent
tokens issued before `Oldest` (too old to be accepted anyway) are forgotten
first.
""".
-spec spend_token(t(), {non_neg_integer(), binary()}, integer()) -> boolean().
spend_token(#registry{spent = Spent}, Id, Oldest) ->
    ok = forget_spent(Spent, Oldest),
    ets:info(Spent, size) < ?SPENT_LIMIT andalso ets:insert_new(Spent, {Id}).

%% Drop the spent tokens issued before `Oldest`, from the front of the
%% table, so each is dropped once and the work stays proportional to the
%% tokens spent.
-spec forget_spent(ets:table(), integer()) -> ok.
forget_spent(Spent, Oldest) ->
    case ets:first(Spent) of
        {IssuedAt, _Nonce} = Id when IssuedAt < Oldest ->
            true = ets:delete(Spent, Id),
            forget_spent(Spent, Oldest);
        _ ->
            ok
    end.

-doc "The namespace's stateless reset key, which `reset_token/2` derives tokens from.".
-spec reset_key(t()) -> binary().
reset_key(#registry{reset_key = Key}) ->
    Key.

-doc """
The stateless reset token for a connection id (RFC 9000 §10.3.2): the
HMAC-SHA256 of the id under the namespace's reset key, truncated to 16 bytes.
""".
-spec reset_token(binary(), binary()) -> <<_:128>>.
reset_token(Key, CID) ->
    crypto:macN(hmac, sha256, Key, CID, ?TOKEN_LEN).
