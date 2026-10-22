-module(roadrunner_crashing_event_handler).
-moduledoc false.

%% Test-only `roadrunner_event_handler` that tells the calling process
%% it was called, then raises: proves a broken handler is contained.
%% On `request_stop` it first swaps in the no-op handler itself, the way
%% a concurrent crash in another process would have.

-behaviour(roadrunner_event_handler).

-export([handle_event/2]).

-spec handle_event(roadrunner_event_handler:event(), term()) -> no_return().
handle_event(request_stop = Event, _Args) ->
    self() ! {crashing_handler_called, Event},
    ok = roadrunner_event:put_handler(roadrunner_event_noop),
    error(boom);
handle_event(Event, _Args) ->
    self() ! {crashing_handler_called, Event},
    error(boom).
