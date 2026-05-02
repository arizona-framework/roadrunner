-module(roadrunner_test_handler).
-moduledoc """
Test fixture — a `roadrunner_handler` that always returns `201 Created`
with a recognizable body, used to verify that listener → conn dispatch
actually reaches the user-supplied handler module.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
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
