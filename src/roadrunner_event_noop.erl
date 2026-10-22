-module(roadrunner_event_noop).
-moduledoc """
The default `roadrunner_event_handler`: drops every event.

An event costs one `persistent_term` read and one call to this
module; no measurement or metadata is built.
""".

-behaviour(roadrunner_event_handler).

-export([handle_event/2]).

-doc "Drop the event.".
-spec handle_event(roadrunner_event_handler:event(), term()) -> ok.
handle_event(_Event, _Args) ->
    ok.
