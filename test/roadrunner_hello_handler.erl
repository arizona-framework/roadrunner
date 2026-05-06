-module(roadrunner_hello_handler).
-moduledoc """
Test-fixture `roadrunner_handler` — answers every request with
`200 Hello, roadrunner!`. Used by the test suite, the diagnostic
scripts (`scripts/h2spec.sh`, `scripts/diag/h2_probe.escript`), and
the bench client tests as a minimal default-shape handler. Lives
in `test/` because no production listener should ship with this
as a default.
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
