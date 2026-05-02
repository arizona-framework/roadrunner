-module(roadrunner_conn_loop).
-moduledoc """
Tail-recursive synchronous connection loop — alternative to
`roadrunner_conn_statem`'s `gen_statem` implementation.

Same per-connection lifecycle the gen_statem encodes
(`awaiting_shoot → reading_request → reading_body → dispatching →
finishing → loop or close`) but expressed as direct function calls
between phase functions instead of gen_statem dispatch + state-enter
trampolines. The five phase names stay visible to operators via
`proc_lib:set_label/1` updates at every boundary, so `observer`,
`recon:proc_count/2`, and crash reports still show what the
connection was doing.

Selected per-listener via `proto_opts.conn_impl => loop`. Default is
`statem`, which dispatches to `roadrunner_conn_statem`. The two
implementations are wire-equivalent — same accept/drain/telemetry
contract, same body-framing decisions, same keep-alive rules. The
loop variant exists to recover the throughput + variance gap with
elli without giving up roadrunner's stability features (drain,
slot tracking, telemetry pairing, hibernation, lifecycle
introspection). See `.claude/plans/sorted-discovering-thimble.md`
for the phased rollout.

## Phase 1 — scaffolding only

This commit implements `awaiting_shoot` and a clean exit path. It
does not yet handle requests; receiving `shoot` fires the
listener_accept telemetry, then the conn exits cleanly (paired
with listener_conn_close so telemetry stays balanced). Subsequent
phases of the plan add reading_request → reading_body →
dispatching → finishing.
""".

-export([start/2]).

%% Internal entry — invoked by `proc_lib:start/3` from `start/2`.
-export([init_loop/3]).

-spec start(roadrunner_transport:socket(), roadrunner_conn:proto_opts()) ->
    {ok, pid()}.
start(Socket, ProtoOpts) when is_map(ProtoOpts) ->
    %% Unlinked from the acceptor — a single-conn crash never propagates
    %% to the acceptor pool. Mirrors `gen_statem:start/3` (NOT start_link)
    %% so existing acceptor handoff (`controlling_process` then `! shoot`)
    %% works without modification.
    Parent = self(),
    proc_lib:start(?MODULE, init_loop, [Parent, Socket, ProtoOpts]).

-doc false.
-spec init_loop(pid(), roadrunner_transport:socket(), roadrunner_conn:proto_opts()) ->
    no_return().
init_loop(Parent, Socket, ProtoOpts) ->
    ListenerName = maps:get(listener_name, ProtoOpts, undefined),
    proc_lib:set_label({roadrunner_conn, awaiting_shoot, ListenerName}),
    ok = roadrunner_conn:join_drain_group(ListenerName),
    proc_lib:init_ack(Parent, {ok, self()}),
    awaiting_shoot(Socket, ProtoOpts, ListenerName).

-spec awaiting_shoot(roadrunner_transport:socket(), roadrunner_conn:proto_opts(), atom()) ->
    no_return().
awaiting_shoot(Socket, ProtoOpts, ListenerName) ->
    receive
        shoot ->
            %% Socket ownership has just transferred from the acceptor —
            %% refine the proc_lib label with the peer (which we couldn't
            %% know on init/1 because the OS-level socket wasn't ours yet).
            Peer = roadrunner_conn:peer(Socket),
            ok = roadrunner_conn:refine_conn_label(ProtoOpts, Peer),
            StartMono = roadrunner_telemetry:listener_accept(#{
                listener_name => ListenerName, peer => Peer
            }),
            %% Phase 1 placeholder — request handling lands in Phase 2.
            %% Exit cleanly so telemetry stays paired and the slot is
            %% released even on this stripped-down lifecycle.
            exit_clean(Socket, ProtoOpts, StartMono, Peer, ListenerName, normal);
        {roadrunner_drain, _Deadline} ->
            %% Drain before `shoot` — no telemetry was fired yet (accept
            %% pairs with `shoot`), so no listener_conn_close either. Just
            %% release the slot and close the socket.
            exit_clean(Socket, ProtoOpts, undefined, undefined, ListenerName, normal);
        _Stray ->
            %% Stray-msg tolerance — gen_statem drops unmatched info events
            %% silently; we do the same so a buggy library can't crash the
            %% conn with a typo'd message.
            awaiting_shoot(Socket, ProtoOpts, ListenerName)
    end.

%% Funnel for every clean exit path. Mirrors `roadrunner_conn_statem:terminate/3`
%% — fires the paired listener_conn_close telemetry (only if accept already
%% fired), releases the listener slot, closes the socket, and exits with the
%% supplied Reason.
%%
%% **Limitation**: under `exit(Pid, kill)` this funnel is skipped (same
%% gen_statem limitation today). Bounded by `max_clients` and reset on
%% listener restart.
-spec exit_clean(
    roadrunner_transport:socket(),
    roadrunner_conn:proto_opts(),
    integer() | undefined,
    {inet:ip_address(), inet:port_number()} | undefined,
    atom(),
    term()
) -> no_return().
exit_clean(Socket, ProtoOpts, StartMono, Peer, ListenerName, Reason) ->
    case StartMono of
        undefined ->
            ok;
        _ ->
            roadrunner_telemetry:listener_conn_close(StartMono, #{
                listener_name => ListenerName, peer => Peer
            })
    end,
    ok = roadrunner_conn:release_slot(ProtoOpts),
    ok = roadrunner_transport:close(Socket),
    exit(Reason).
