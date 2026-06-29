-module(roadrunner_acceptor).
-moduledoc false.

%% Acceptor process — spins on `gen_tcp:accept/1` for a listen socket
%% and hands each accepted connection off to a `roadrunner_conn` worker.
%%
%% Spawn-linked to the owning `roadrunner_listener`: a listener stop closes
%% the listen socket, the acceptor's `accept/1` returns `{error, closed}`,
%% and the acceptor exits cleanly. A transient accept error instead
%% (`emfile`/`enfile`/`system_limit` descriptor exhaustion when `max_clients`
%% sits above the OS `ulimit -n`, or a connection aborted before accept
%% completed) is reported via telemetry and retried after a short back-off,
%% so the pool never silently drains. Unrelated acceptor crashes propagate
%% back via the link, taking the listener down for supervisor restart.
%% Connection workers are spawned **without** a link so that a crash
%% in one connection does not bring down the acceptor.

%% Back-off between retries after a transient accept error. Bounds the
%% retry/telemetry rate and gives the box a moment to reclaim descriptors
%% before the next `accept/1`.
-define(ACCEPT_ERROR_BACKOFF_MS, 100).

-export([start_link/3]).

-doc """
Spawn-link an acceptor process bound to `LSocket` with the given
`ProtoOpts` (handler + body limits) and a 1-based pool index. Each
accepted socket is handed to a `roadrunner_conn` worker that consumes
the same opts. The index is used in the `proc_lib` label so
`observer` distinguishes `{roadrunner_acceptor, ListenerName, 1}`,
`{..., 2}`, etc., per listener.
""".
-spec start_link(roadrunner_transport:socket(), roadrunner_conn:proto_opts(), pos_integer()) ->
    {ok, pid()}.
start_link(LSocket, ProtoOpts, Index) ->
    ListenerName = maps:get(listener_name, ProtoOpts, undefined),
    Pid = proc_lib:spawn_link(fun() ->
        proc_lib:set_label({roadrunner_acceptor, ListenerName, Index}),
        loop(LSocket, ProtoOpts)
    end),
    {ok, Pid}.

-spec loop(roadrunner_transport:socket(), roadrunner_conn:proto_opts()) -> ok.
loop(LSocket, ProtoOpts) ->
    case roadrunner_transport:accept(LSocket) of
        {ok, Socket} ->
            handle_accepted(Socket, ProtoOpts),
            loop(LSocket, ProtoOpts);
        {error, closed} ->
            %% Listen socket was closed — the listener is stopping. Exit
            %% cleanly; the linked listener tears the rest of the pool down.
            ok;
        {error, Reason} ->
            %% Any other accept error is transient: descriptor exhaustion
            %% (`emfile`/`enfile`/`system_limit`) when `max_clients` sits
            %% above the OS `ulimit -n`, or a connection aborted before
            %% accept completed. Surface it and back off, then keep
            %% accepting — exiting here would silently drain the pool and
            %% leave the listener permanently deaf with no diagnostic.
            ok = roadrunner_telemetry:listener_accept_error(#{
                listener_name => maps:get(listener_name, ProtoOpts, undefined),
                reason => Reason
            }),
            receive
            after ?ACCEPT_ERROR_BACKOFF_MS -> ok
            end,
            loop(LSocket, ProtoOpts)
    end.

-spec handle_accepted(roadrunner_transport:socket(), roadrunner_conn:proto_opts()) -> ok.
handle_accepted(Socket, ProtoOpts) ->
    case roadrunner_conn:try_acquire_slot(ProtoOpts) of
        true ->
            {ok, ConnPid} = roadrunner_conn:start(Socket, ProtoOpts),
            ok = roadrunner_transport:controlling_process(Socket, ConnPid),
            ConnPid ! shoot,
            ok;
        false ->
            %% Over max_clients — drop the new connection on the floor, but
            %% make the drop observable: bump the cumulative reject counter
            %% (surfaced via `roadrunner_listener:info/1`) and emit
            %% `[roadrunner, listener, conn_rejected]`. No `peername` lookup
            %% here — this is the floodable path, so it stays cheap.
            #{rejected_counter := RejectedCounter} = ProtoOpts,
            ok = atomics:add(RejectedCounter, 1, 1),
            ok = roadrunner_telemetry:listener_conn_rejected(#{
                listener_name => maps:get(listener_name, ProtoOpts, undefined),
                reason => max_clients
            }),
            _ = roadrunner_transport:close(Socket),
            ok
    end.
