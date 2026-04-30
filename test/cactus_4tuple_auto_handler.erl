-module(cactus_4tuple_auto_handler).
-moduledoc """
Test fixture — handler running in `auto` body-buffering mode that
returns the 4-tuple shape `{Status, Headers, Body, Req2}`. Exercises
`cactus_conn:drain_body/1`'s no-body_state path (auto-mode `Req2`
has no body_state to drain).
""".

-behaviour(cactus_handler).

-export([handle/1]).

handle(Req) ->
    Body = ~"alive",
    {200,
        [
            {~"content-type", ~"text/plain"},
            {~"content-length", integer_to_binary(byte_size(Body))}
        ],
        Body, Req}.
