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

## Phases shipped so far

- **Phase 1** — `awaiting_shoot` + clean exit funnel (`exit_clean/6`).
- **Phase 2** — `read_request_phase` with active-mode header read,
  parse via `roadrunner_http1:parse_request/1`, 400 / 408 error
  responses, drain handling, `request_timeout` via the receive's
  `after` clause (no `start_timer` arms), stray-msg tolerance.
  Successful parse currently exits cleanly (placeholder for body
  + dispatch in Phase 3).

Pending phases: Phase 3 (body read + dispatch + finishing),
Phase 4 (hibernation), Phase 5 (top-level try/catch around
`exit_clean`), Phase 6 (test parametrization), Phase 7 (A/B vs
gen_statem), Phase 8 (cutover or park).
""".

-export([start/2]).

%% Internal entry — invoked by `proc_lib:start/3` from `start/2`.
-export([init_loop/3]).

%% Loop-state record carried through every phase. Allocated once on
%% the transition out of `awaiting_shoot` and pattern-matched (not
%% reconstructed) thereafter, so the per-request hot path stays
%% allocation-light.
-record(loop_state, {
    socket :: roadrunner_transport:socket(),
    proto_opts :: roadrunner_conn:proto_opts(),
    listener_name :: atom(),
    %% Captured at `shoot` from `roadrunner_telemetry:listener_accept/1`.
    %% Paired with `listener_conn_close` in `exit_clean/2`.
    start_mono :: integer(),
    peer :: {inet:ip_address(), inet:port_number()} | undefined,
    %% Bytes received but not yet parsed. Empty on first iteration;
    %% populated mid-recv when `parse_request/1` returns `{more, _}`.
    %% Phase 3 will also use this for pipelined leftovers.
    buffered = <<>> :: binary()
}).

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
            S = #loop_state{
                socket = Socket,
                proto_opts = ProtoOpts,
                listener_name = ListenerName,
                start_mono = StartMono,
                peer = Peer
            },
            read_request_phase(S);
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

%% --- read_request phase ---
%%
%% Active-mode header read. Each iteration:
%%
%%   1. `setopts({active, once})` so the next inbound packet arrives
%%      as a `{TcpTag, Sock, Bytes}` info event.
%%   2. `receive` matches the data tag (accumulate + parse), the
%%      closed/error tags (clean exit), `{roadrunner_drain, _}`
%%      (clean exit), or stray messages (drop and re-loop).
%%   3. The receive's `after RequestTimeout` clause handles
%%      slowloris — no `start_timer` / `cancel_timer` per iteration,
%%      unlike the gen_statem variant.
%%
%% Phase 2 only handles the "first request on a fresh conn" case;
%% Phase 3 will add keep-alive loop-back and pipelined leftover.
-spec read_request_phase(#loop_state{}) -> no_return().
read_request_phase(#loop_state{listener_name = ListenerName} = S) ->
    proc_lib:set_label({roadrunner_conn, reading_request, ListenerName}),
    Timeout = maps:get(request_timeout, S#loop_state.proto_opts),
    %% Compute an *absolute* deadline once. Each iteration's `after`
    %% clause decays it — `recv_request_bytes/2` recomputes
    %% `Deadline - now` so a slow client that drips bytes can NOT keep
    %% extending the receive's timeout. Mirrors gen_statem's one-shot
    %% `state_timeout` semantics in a hand-rolled receive.
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    arm_active_once(S),
    recv_request_bytes(S, Deadline).

-spec recv_request_bytes(#loop_state{}, integer()) -> no_return().
recv_request_bytes(
    #loop_state{
        socket = Socket,
        buffered = Buf
    } = S,
    Deadline
) ->
    {DataTag, ClosedTag, ErrorTag} = roadrunner_transport:messages(Socket),
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {DataTag, _Sock, Bytes} ->
            handle_request_bytes(S#loop_state{buffered = <<Buf/binary, Bytes/binary>>}, Deadline);
        {ClosedTag, _Sock} ->
            %% Peer closed mid-headers — silent exit, no 4xx (peer's
            %% gone, no point writing).
            exit_normal(S);
        {ErrorTag, _Sock, _Reason} ->
            exit_normal(S);
        {roadrunner_drain, _Deadline} ->
            exit_normal(S);
        _Stray ->
            %% Drop unmatched messages (gen_statem does the same via
            %% the wildcard `info` clause) and re-arm.
            arm_active_once(S),
            recv_request_bytes(S, Deadline)
    after Remaining ->
        %% Slowloris / first-request silence. Phase 2 only sees `first`
        %% requests (no keep-alive yet) so we always send a 408.
        _ = roadrunner_conn:send_request_timeout(Socket),
        exit_normal(S)
    end.

%% Try parsing the accumulated buffer. On `{more, _}` we re-arm and
%% wait for more bytes; on `{ok, Req, Rest}` we've parsed a full
%% request (Phase 2 placeholder: exit clean — Phase 3 will dispatch
%% body + handler); on `{error, _}` we send 400 and exit.
-spec handle_request_bytes(#loop_state{}, integer()) -> no_return().
handle_request_bytes(
    #loop_state{
        socket = Socket,
        listener_name = ListenerName,
        peer = Peer,
        buffered = Buf
    } = S,
    Deadline
) ->
    case roadrunner_http1:parse_request(Buf) of
        {ok, _Req, _Rest} ->
            %% Phase 2 placeholder — Phase 3 dispatches body + handler.
            exit_normal(S);
        {more, _} ->
            arm_active_once(S),
            recv_request_bytes(S, Deadline);
        {error, Reason} ->
            logger:debug(#{
                msg => "roadrunner rejecting malformed request",
                peer => Peer,
                listener_name => ListenerName,
                reason => Reason
            }),
            ok = roadrunner_telemetry:request_rejected(#{
                listener_name => ListenerName,
                peer => Peer,
                reason => Reason
            }),
            _ = roadrunner_conn:send_bad_request(Socket),
            exit_normal(S)
    end.

-spec arm_active_once(#loop_state{}) -> ok.
arm_active_once(#loop_state{socket = Socket} = S) ->
    %% On socket failure (peer RST during the gap, kernel-side close)
    %% we can't `setopts` — exit cleanly instead of crashing.
    case roadrunner_transport:setopts(Socket, [{active, once}]) of
        ok -> ok;
        {error, _} -> exit_normal(S)
    end.

%% Convenience wrapper around `exit_clean/6` that pulls fields off
%% the loop state. Most exit paths in the read phases fire
%% `listener_conn_close` (accept already fired during `shoot`).
-spec exit_normal(#loop_state{}) -> no_return().
exit_normal(#loop_state{
    socket = Socket,
    proto_opts = ProtoOpts,
    listener_name = ListenerName,
    start_mono = StartMono,
    peer = Peer
}) ->
    exit_clean(Socket, ProtoOpts, StartMono, Peer, ListenerName, normal).

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
