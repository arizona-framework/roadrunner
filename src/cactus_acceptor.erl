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

-export([start_link/2]).

-doc """
Spawn-link an acceptor process bound to `LSocket` with the given
`Handler` module. Each accepted socket is handed to a `cactus_conn`
worker that dispatches to `Handler:handle/1`.
""".
-spec start_link(gen_tcp:socket(), module()) -> {ok, pid()}.
start_link(LSocket, Handler) ->
    Pid = proc_lib:spawn_link(fun() ->
        proc_lib:set_label(cactus_acceptor),
        loop(LSocket, Handler)
    end),
    {ok, Pid}.

-spec loop(gen_tcp:socket(), module()) -> ok.
loop(LSocket, Handler) ->
    case gen_tcp:accept(LSocket) of
        {ok, Socket} ->
            {ok, ConnPid} = cactus_conn:start(Socket, Handler),
            ok = gen_tcp:controlling_process(Socket, ConnPid),
            ConnPid ! shoot,
            loop(LSocket, Handler);
        {error, _} ->
            %% Listen socket was closed (or another transport error) —
            %% terminate cleanly; the linked listener will tear us down.
            ok
    end.
