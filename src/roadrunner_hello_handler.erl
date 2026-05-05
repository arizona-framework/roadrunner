-module(roadrunner_hello_handler).
-moduledoc """
Default `roadrunner_handler` — answers every request with `200 Hello, roadrunner!`.

Used when no `handler` opt is passed to `roadrunner:start_listener/2`.
Replaces the hardcoded body roadrunner_conn carried before slice 3.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    Body = ~"Hello, roadrunner!\r\n",
    Resp =
        {200,
            [
                {~"content-type", ~"text/plain"},
                {~"content-length", integer_to_binary(byte_size(Body))},
                {~"connection", ~"close"}
            ],
            Body},
    {Resp, Req}.
