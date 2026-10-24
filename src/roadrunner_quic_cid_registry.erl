-module(roadrunner_quic_cid_registry).
-moduledoc false.

%% The connection-id namespace of a native QUIC listener (or a SO_REUSEPORT
%% pool of them): the connection-id -> connection-pid routing table (an ETS
%% set) and the stateless reset key the connection ids' reset tokens derive
%% from.
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
%% Cleanup is the owner's contract: the listener monitors each connection and
%% calls delete_pid/2 when it ends. Between a connection ending and that
%% cleanup, lookup/2 may briefly return its now-dead pid; routing a datagram
%% there is a harmless no-op (the message is dropped) and is the right outcome
%% anyway (a datagram for a gone connection should be dropped). A registration
%% for an id already held by another pid (a recycled or, astronomically,
%% colliding client DCID) overwrites it; the previous pid's other ids are
%% reaped by its own delete_pid/2, and its remove/3 of the overwritten id
%% leaves the new owner's row alone.
%%
%% The reset key is one random secret per namespace, so every listener of a
%% pool derives the same token for an id: a stateless reset token is the
%% HMAC-SHA256 of the connection id under it, truncated to 16 bytes (RFC 9000
%% §10.3.2). It is unpredictable without the key, distinct per id, and needs
%% no per-connection state to recompute.

-export([new/0, register_pair/4, add/3, remove/3, lookup/2, delete_pid/2]).
-export([reset_key/1, reset_token/2]).

-export_type([t/0]).

%% RFC 9000 §10.3: a stateless reset token is 16 bytes.
-define(TOKEN_LEN, 16).

-record(registry, {
    table :: ets:table(),
    reset_key :: binary()
}).

-opaque t() :: #registry{}.

-doc """
Create an empty routing table, owned by the calling process, and a fresh
stateless reset key.
""".
-spec new() -> t().
new() ->
    #registry{
        table = ets:new(?MODULE, [
            set, public, {read_concurrency, true}, {write_concurrency, auto}
        ]),
        reset_key = crypto:strong_rand_bytes(32)
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

-doc "The connection owning a destination connection id, if one is registered.".
-spec lookup(t(), binary()) -> {ok, pid()} | error.
lookup(#registry{table = Table}, CID) ->
    case ets:lookup(Table, CID) of
        [{_CID, Pid}] -> {ok, Pid};
        [] -> error
    end.

-doc "Drop every connection id routing to `Pid` (its connection has ended).".
-spec delete_pid(t(), pid()) -> ok.
delete_pid(#registry{table = Table}, Pid) ->
    true = ets:match_delete(Table, {'_', Pid}),
    ok.

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
