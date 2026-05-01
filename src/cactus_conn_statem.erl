-module(cactus_conn_statem).
-moduledoc """
HTTP/1.1 connection state machine — work-in-progress replacement
for the hand-rolled `cactus_conn` recursion.

This module is **not yet wired in**. `cactus_conn:start/2` continues
to spawn the legacy `proc_lib`-based loop. Phase 4 of the migration
plan stops here; later phases (5–7) extend the state callbacks and
finally swap `start/2` to spawn this gen_statem instead.

The plan keeps `cactus_conn`'s public pure-function surface intact —
`parse_loop/2`, `read_body/4`, `peer/1`, `try_acquire_slot/1`,
`release_slot/1`, `consume_body_state/2` — so the 44 closure-driven
unit tests keep passing through the migration. The state machine
just calls those from inside its state callbacks once the later
phases land.

States (only `awaiting_shoot` is implemented in Phase 4):
- `awaiting_shoot` — gates the lifecycle until the acceptor's
  `shoot` info message arrives. `cactus_acceptor:handle_accepted/2`
  spawns this gen_statem, transfers controlling-process, then sends
  `ConnPid ! shoot` (raw bang, not a gen_statem call) — we receive
  it as an info event.
- `reading_request | reading_body | dispatching | finishing |
  draining` — placeholders, implemented in later phases.

Telemetry: `[cactus, listener, accept]` fires at `init/1` (so the
event captures the wall-clock start of the conn's life); the
matching `[cactus, listener, conn_close]` fires from `terminate/3`
with the connection's duration and the keep-alive request count.
""".

-behaviour(gen_statem).

-export([start/2]).
-export([init/1, callback_mode/0, terminate/3]).
-export([awaiting_shoot/3]).

-record(data, {
    socket :: cactus_transport:socket(),
    proto_opts :: cactus_conn:proto_opts(),
    listener_name :: atom(),
    %% Captured at init/1 for the conn_close telemetry's `duration`.
    start_mono :: integer(),
    %% Peer is unknown until after the socket transfer; populated on
    %% entry to `reading_request` (Phase 5).
    peer :: {inet:ip_address(), inet:port_number()} | undefined,
    %% Cumulative successfully-served requests on this conn —
    %% incremented as `dispatching` lands a response.
    requests_served = 0 :: non_neg_integer()
}).

-doc """
Spawn an unlinked gen_statem for the accepted `Socket` and the
shared `ProtoOpts`. Mirrors `cactus_conn:start/2` exactly so the
acceptor's existing handoff dance (`controlling_process` then
`! shoot`) works without modification.

`gen_statem:start/3` (not `start_link/3`) — the conn is
intentionally unlinked from the acceptor so a single-conn crash
never propagates to the acceptor pool.
""".
-spec start(cactus_transport:socket(), cactus_conn:proto_opts()) ->
    {ok, pid()} | {error, term()}.
start(Socket, ProtoOpts) ->
    gen_statem:start(?MODULE, {Socket, ProtoOpts}, []).

-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() -> [state_functions, state_enter].

-spec init({cactus_transport:socket(), cactus_conn:proto_opts()}) ->
    {ok, awaiting_shoot, #data{}}.
init({Socket, ProtoOpts}) ->
    ListenerName = maps:get(listener_name, ProtoOpts, undefined),
    proc_lib:set_label({cactus_conn, ListenerName}),
    ok = cactus_conn:join_drain_group(ListenerName),
    %% Peer isn't known yet — `init/1` runs before the socket transfer.
    %% Listener-accept telemetry fires here so subscribers can correlate
    %% by listener regardless of when the peer becomes available.
    StartMono = cactus_telemetry:listener_accept(#{
        listener_name => ListenerName, peer => undefined
    }),
    {ok, awaiting_shoot, #data{
        socket = Socket,
        proto_opts = ProtoOpts,
        listener_name = ListenerName,
        start_mono = StartMono
    }}.

%% --- States ---

-spec awaiting_shoot(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:event_handler_result(atom()).
awaiting_shoot(enter, _Old, _Data) ->
    keep_state_and_data;
awaiting_shoot(info, shoot, #data{} = Data) ->
    %% Phase 4 stops here — later phases pick up `reading_request` and
    %% drive the request lifecycle. For now exit cleanly so the
    %% skeleton's smoke test can drive `init -> shoot -> exit` end-to-end.
    {stop, normal, Data}.

%% --- Termination ---

-spec terminate(term(), atom(), #data{}) -> ok.
terminate(_Reason, _State, #data{
    socket = Socket,
    proto_opts = ProtoOpts,
    listener_name = ListenerName,
    start_mono = StartMono,
    peer = Peer,
    requests_served = Count
}) ->
    %% Mirror the legacy spine's `serve_lifecycle/3` telemetry exactly.
    cactus_telemetry:listener_conn_close(StartMono, #{
        listener_name => ListenerName, peer => Peer, requests_served => Count
    }),
    _ = cactus_transport:close(Socket),
    cactus_conn:release_slot(ProtoOpts),
    ok.
