-module(cactus_ws_hibernate_handler).
-moduledoc """
Test fixture — `cactus_ws_handler` that returns the 4-tuple opts
variant with `hibernate` so the session hibernates after each
event. Text frames echo back; binary frames return `{ok, _, [hibernate]}`
without a reply; `~"stop"` closes.
""".

-behaviour(cactus_ws_handler).

-export([handle_frame/2]).

-spec handle_frame(cactus_ws:frame(), term()) ->
    {reply, [{cactus_ws:opcode(), iodata()}], term(), [cactus_ws_handler:opt()]}
    | {ok, term(), [cactus_ws_handler:opt()]}
    | {close, term()}.
handle_frame(#{opcode := text, payload := ~"stop"}, State) ->
    {close, State};
handle_frame(#{opcode := text, payload := P}, State) ->
    {reply, [{text, P}], State, [hibernate]};
handle_frame(_Frame, State) ->
    {ok, State, [hibernate]}.
