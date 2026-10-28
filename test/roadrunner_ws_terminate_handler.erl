-module(roadrunner_ws_terminate_handler).
-moduledoc """
Test fixture: a WebSocket handler with `terminate/2`, which sends its
reason and last state to the state's `report` pid as
`{terminated, Reason, State}`. A frame closes the session when the state
has `close_on_frame => true`; a drain always closes it. With
`crash_in_terminate => true`, `terminate/2` raises after reporting.
""".

-behaviour(roadrunner_ws_handler).

-export([handle_frame/2, handle_drain/2, terminate/2]).

handle_frame(_Frame, #{close_on_frame := true} = State) ->
    {close, State#{closed_by => frame}};
handle_frame(_Frame, State) ->
    {ok, State}.

handle_drain(_Deadline, State) ->
    {close, 1001, ~"", State#{closed_by => drain}}.

terminate(Reason, #{report := Pid} = State) ->
    Pid ! {terminated, Reason, State},
    case State of
        #{crash_in_terminate := true} -> error(terminate_crash);
        #{} -> ok
    end.
