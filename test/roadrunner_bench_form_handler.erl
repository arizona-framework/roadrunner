-module(roadrunner_bench_form_handler).
-moduledoc """
Roadrunner handler for `scripts/bench.escript --scenario post_4kb_form`.

Reads a `application/x-www-form-urlencoded` body, parses it via
`roadrunner_qs:parse/1`, and returns a small `200 ok` ack with the
pair count. Exercises the form-decode path that has unit-test
coverage but no bench coverage.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(#{body := Body} = Req) ->
    Pairs = roadrunner_qs:parse(Body),
    AckBody = integer_to_binary(length(Pairs)),
    Resp =
        {200,
            [
                {~"content-type", ~"text/plain"},
                {~"content-length", integer_to_binary(byte_size(AckBody))}
            ],
            AckBody},
    {Resp, Req}.
