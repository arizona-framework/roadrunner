-module(roadrunner_drain_ignore_handler).
-moduledoc """
Test fixture — `{loop, ...}` handler that pushes a "started" chunk
and then ignores **everything**, including `{roadrunner_drain, _}`. Used
to verify `roadrunner_listener:drain/2` falls back to `exit(Pid, shutdown)`
once the timeout elapses.
""".

-behaviour(roadrunner_handler).

-export([handle/1, handle_info/3]).

handle(Req) ->
    self() ! started,
    {{loop, 200, [{~"content-type", ~"text/plain"}], 0}, Req}.

handle_info(started, Push, State) ->
    _ = Push(~"started"),
    {ok, State};
handle_info(_Other, _Push, State) ->
    {ok, State}.
