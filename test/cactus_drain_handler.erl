-module(cactus_drain_handler).
-moduledoc """
Test fixture — `{loop, ...}` handler that signals "started" by
pushing a chunk, then waits for `{cactus_drain, _}` and stops
cleanly. Used to verify `cactus_listener:drain/2` reaches in-flight
loops via the per-listener `pg` group.
""".

-behaviour(cactus_handler).

-export([handle/1, handle_info/3]).

handle(Req) ->
    %% Self-poke so handle_info/3 fires once and pushes the "started"
    %% chunk; the test waits for it before invoking drain/2.
    self() ! started,
    {{loop, 200, [{~"content-type", ~"text/plain"}], 0}, Req}.

handle_info({cactus_drain, _Deadline}, _Push, State) ->
    {stop, State};
handle_info(started, Push, State) ->
    _ = Push(~"started"),
    {ok, State}.
