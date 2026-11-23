-module(roadrunner_ws_multi_frame_handler).
-moduledoc """
Test fixture: replies with several frames of the same text, from
`handle_frame/2` (`two`, `three`), from `handle_info/2` (`push`) and in the
frames of a close (`close`), for the permessage-deflate order checks.
""".

-behaviour(roadrunner_ws_handler).

-export([handle_frame/2, handle_info/2]).

-define(TEXT, ~"hello world").

handle_frame(#{payload := ~"two"}, State) ->
    {reply, [{text, ?TEXT}, {text, ?TEXT}], State};
handle_frame(#{payload := ~"three"}, State) ->
    {reply, [{text, ?TEXT}, {text, ?TEXT}, {text, ?TEXT}], State};
handle_frame(#{payload := ~"close"}, State) ->
    {close, 1000, ~"", [{text, ?TEXT}, {text, ?TEXT}], State};
handle_frame(_Frame, State) ->
    {ok, State}.

handle_info(push, State) ->
    {reply, [{text, ?TEXT}, {text, ?TEXT}, {text, ?TEXT}], State}.
