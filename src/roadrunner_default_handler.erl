-module(roadrunner_default_handler).
-moduledoc """
Default `roadrunner_handler` — used when a listener starts with
neither `routes` nor `handler` configured. Returns 404 with a body
pointing the operator at the quickstart, so a smoke `curl` against
an otherwise-blank listener tells you what to do next instead of
silently 200-ing.

Operators wire their own handler via the listener's `handler` opt
(single-handler shape) or `routes` opt (routed shape) — see
`t:roadrunner_listener:opts/0` and the project README.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-define(BODY, ~"""
roadrunner: no handler or routes configured for this listener.

Quickstart:
  roadrunner:start_listener(my_listener, #{
      port => 8080,
      handler => my_handler
  }).

  roadrunner:start_listener(my_listener, #{
      port => 8080,
      routes => [{~"/", my_handler, #{}}]
  }).

Docs: https://github.com/arizona-framework/roadrunner
""").

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    Resp =
        {404,
            [
                {~"content-type", ~"text/plain; charset=utf-8"},
                {~"content-length", integer_to_binary(byte_size(?BODY))}
            ],
            ?BODY},
    {Resp, Req}.
