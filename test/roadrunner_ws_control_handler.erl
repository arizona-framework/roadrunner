-module(roadrunner_ws_control_handler).
-moduledoc """
Test fixture: `handle_control/2` reports each ping and pong to the state's
pid and replies `seen`, except a ping carrying `crash`, which raises; a
`stop` text frame closes with a last frame first, a `restart` one closes
with 1012.
""".

-behaviour(roadrunner_ws_handler).

-export([handle_frame/2, handle_control/2]).

handle_frame(#{payload := ~"stop"}, Pid) ->
    {close, 1000, ~"bye", [{text, ~"last"}], Pid};
handle_frame(#{payload := ~"restart"}, Pid) ->
    {close, 1012, ~"", Pid};
handle_frame(_Frame, Pid) ->
    {ok, Pid}.

handle_control(#{payload := ~"crash"}, _Pid) ->
    error(control_crash);
handle_control(#{opcode := Opcode, payload := Payload}, Pid) ->
    Pid ! {control, Opcode, Payload},
    {reply, [{text, ~"seen"}], Pid}.
