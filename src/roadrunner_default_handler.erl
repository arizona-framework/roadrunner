-module(roadrunner_default_handler).
-moduledoc """
Default `roadrunner_handler` — used when a listener starts with no
`routes` opt configured. Returns 404 with a body pointing the
operator at the quickstart, so a smoke `curl` against an otherwise-
blank listener tells you what to do next instead of silently 200-ing.

Operators wire their own handler via the listener's `routes` opt:
either a bare module atom (every request goes to that handler) or
a list of `{Path, Module, Opts}` tuples (routed dispatch). See
`t:roadrunner_listener:opts/0` and the project README.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-define(BODY, ~"""
roadrunner: no routes configured for this listener.

Quickstart:
  roadrunner:start_listener(my_listener, #{
      port => 8080,
      routes => my_handler
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
