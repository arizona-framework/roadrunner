-module(cactus_test_handler).
-moduledoc """
Test fixture — a `cactus_handler` that always returns `201 Created`
with a recognizable body, used to verify that listener → conn dispatch
actually reaches the user-supplied handler module.
""".

-behaviour(cactus_handler).

-export([handle/1]).

-spec handle(cactus_http1:request()) -> cactus_handler:result().
handle(Req) ->
    Body = ~"custom handler response",
    Resp =
        {201,
            [
                {~"content-type", ~"text/plain"},
                {~"content-length", integer_to_binary(byte_size(Body))},
                {~"connection", ~"close"}
            ],
            Body},
    {Resp, Req}.
