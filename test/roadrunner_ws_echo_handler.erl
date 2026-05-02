-module(roadrunner_ws_echo_handler).
-moduledoc """
Test fixture — `roadrunner_ws_handler` that echoes text frames back to the
client and ignores everything else (state passes through unchanged).
""".

-behaviour(roadrunner_ws_handler).

-export([handle_frame/2]).

-spec handle_frame(roadrunner_ws:frame(), term()) ->
    {reply, [{roadrunner_ws:opcode(), iodata()}], term()}
    | {ok, term()}
    | {close, term()}.
handle_frame(#{opcode := text, payload := ~"stop"}, State) ->
    {close, State};
handle_frame(#{opcode := text, payload := P}, State) ->
    {reply, [{text, P}], State};
handle_frame(_Frame, State) ->
    {ok, State}.
