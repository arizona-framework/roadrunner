-module(cactus_acceptor).
-moduledoc """
Acceptor process — spins on `gen_tcp:accept/1` for a listen socket
and hands each accepted connection off to a `cactus_conn` worker.

Spawn-linked to the owning `cactus_listener`: a listener stop closes
the listen socket, the acceptor's `accept/1` returns `{error, _}`,
and the acceptor exits cleanly. Unrelated acceptor crashes propagate
back via the link, taking the listener down for supervisor restart.
Connection workers are spawned **without** a link so that a crash
in one connection does not bring down the acceptor.
""".

-export([start_link/3]).

-doc """
Spawn-link an acceptor process bound to `LSocket` with the given
`ProtoOpts` (handler + body limits) and a 1-based pool index. Each
accepted socket is handed to a `cactus_conn` worker that consumes
the same opts. The index is used in the `proc_lib` label so
`observer` distinguishes `{cactus_acceptor, ListenerName, 1}`,
`{..., 2}`, etc., per listener.
""".
-spec start_link(cactus_transport:socket(), cactus_conn:proto_opts(), pos_integer()) ->
    {ok, pid()}.
start_link(LSocket, ProtoOpts, Index) ->
    ListenerName = maps:get(listener_name, ProtoOpts, undefined),
    Pid = proc_lib:spawn_link(fun() ->
        proc_lib:set_label({cactus_acceptor, ListenerName, Index}),
        loop(LSocket, ProtoOpts)
    end),
    {ok, Pid}.

-spec loop(cactus_transport:socket(), cactus_conn:proto_opts()) -> ok.
loop(LSocket, ProtoOpts) ->
    case cactus_transport:accept(LSocket) of
        {ok, Socket} ->
            handle_accepted(Socket, ProtoOpts),
            loop(LSocket, ProtoOpts);
        {error, _} ->
            %% Listen socket was closed (or another transport error) —
            %% terminate cleanly; the linked listener will tear us down.
            ok
    end.

-spec handle_accepted(cactus_transport:socket(), cactus_conn:proto_opts()) -> ok.
handle_accepted(Socket, ProtoOpts) ->
    case cactus_conn:try_acquire_slot(ProtoOpts) of
        true ->
            {ok, ConnPid} = cactus_conn:start(Socket, ProtoOpts),
            ok = cactus_transport:controlling_process(Socket, ConnPid),
            ConnPid ! shoot,
            ok;
        false ->
            %% Over max_clients — drop the new connection on the floor.
            _ = cactus_transport:close(Socket),
            ok
    end.
