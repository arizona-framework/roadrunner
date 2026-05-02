-module(roadrunner_drain_pause_handler).
-moduledoc """
Test fixture — buffered handler that briefly sleeps before
responding so a `drain/2` call running concurrently can plant a
`{roadrunner_drain, _}` message in the conn's mailbox before
`serve_loop/5` checks it.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

handle(Req) ->
    timer:sleep(150),
    Body = ~"hi",
    Headers = [
        {~"content-type", ~"text/plain"},
        {~"content-length", integer_to_binary(byte_size(Body))}
    ],
    {{200, Headers, Body}, Req}.
