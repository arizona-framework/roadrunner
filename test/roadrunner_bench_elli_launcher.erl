-module(roadrunner_bench_elli_launcher).
-moduledoc """
Run inside the elli peer BEAM (called via `peer:call/4`) to start
elli and read back its bound port.

Lives in `test/` (test profile) as a regular module so the peer can
resolve it via the inherited code path. The escript module itself
has an auto-generated name and isn't loadable in the peer.
""".

-export([start/1]).

-spec start(module()) -> {ok, inet:port_number()} | {error, term()}.
start(Callback) ->
    case
        elli:start_link([
            {callback, Callback},
            {port, 0},
            {min_acceptors, 10}
        ])
    of
        {ok, Pid} ->
            %% `peer:call` spawns a transient process to handle the
            %% RPC; that process exits when the call returns. Elli's
            %% only entry point is `start_link/1` which links to the
            %% caller — without unlinking here, elli dies as soon as
            %% the launcher process exits and the bench connects to
            %% a closed port. Unlink to detach the lifetime so the
            %% gen_server outlives this RPC.
            true = unlink(Pid),
            %% Elli doesn't expose `get_port/1`; reach into the
            %% gen_server state. The state record has the listen
            %% socket as its first non-tag field, wrapped as
            %% `{plain, inet:socket()}`. If elli's state shape
            %% changes, this needs updating.
            State = sys:get_state(Pid),
            {plain, ListenSock} = element(2, State),
            {ok, _Port} = inet:port(ListenSock);
        {error, _} = Err ->
            Err
    end.
