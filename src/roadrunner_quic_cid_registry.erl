-module(roadrunner_quic_cid_registry).
-moduledoc false.

%% The connection-id -> connection-pid routing table for the native QUIC
%% listener (an ETS set).
%%
%% A received datagram is routed to its owning connection by the Destination
%% Connection ID in its header. A connection is registered under BOTH the
%% client's original DCID (which the peer uses on its early Initials) and the
%% server's issued SCID (which the peer echoes once it learns it, and which
%% every fixed-length short-header 1-RTT packet carries), so either addressing
%% finds the connection (RFC 9000 §5.1). The table is `public` so a
%% SO_REUSEPORT pool can share one manager-held table across its listeners.
%%
%% Cleanup is the owner's contract: the listener monitors each connection and
%% calls delete_pid/2 when it ends. Between a connection ending and that
%% cleanup, lookup/2 may briefly return its now-dead pid; routing a datagram
%% there is a harmless no-op (the message is dropped) and is the right outcome
%% anyway (a datagram for a gone connection should be dropped). A registration
%% for an id already held by another pid (a recycled or, astronomically,
%% colliding client DCID) overwrites it; the previous pid's other ids are
%% reaped by its own delete_pid/2.

-export([new/0, register_pair/4, lookup/2, delete_pid/2]).

-export_type([t/0]).

-opaque t() :: ets:table().

-doc "Create an empty routing table, owned by the calling process.".
-spec new() -> t().
new() ->
    ets:new(?MODULE, [set, public, {read_concurrency, true}, {write_concurrency, auto}]).

-doc """
Route a connection's client DCID and server SCID to its pid (the dual
registration of RFC 9000 §5.1), so a datagram addressed to either id reaches
the connection.
""".
-spec register_pair(t(), binary(), binary(), pid()) -> ok.
register_pair(Table, DCID, SCID, Pid) ->
    true = ets:insert(Table, [{DCID, Pid}, {SCID, Pid}]),
    ok.

-doc "The connection owning a destination connection id, if one is registered.".
-spec lookup(t(), binary()) -> {ok, pid()} | error.
lookup(Table, CID) ->
    case ets:lookup(Table, CID) of
        [{_CID, Pid}] -> {ok, Pid};
        [] -> error
    end.

-doc "Drop every connection id routing to `Pid` (its connection has ended).".
-spec delete_pid(t(), pid()) -> ok.
delete_pid(Table, Pid) ->
    true = ets:match_delete(Table, {'_', Pid}),
    ok.
