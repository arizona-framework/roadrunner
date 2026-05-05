-module(roadrunner_bench_url_qs_handler).
-moduledoc """
Roadrunner handler for `scripts/bench.escript --scenario url_with_qs`.

Calls `roadrunner_req:parse_qs/1` on the URL's query string,
returns the pair count. Mirrors `roadrunner_bench_form_handler`'s
shape but exercises the URL-side qs:parse path (vs the body-side
form-decode path the form handler measures).
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    Pairs = roadrunner_req:parse_qs(Req),
    AckBody = integer_to_binary(length(Pairs)),
    Resp =
        {200,
            [
                {~"content-type", ~"text/plain"},
                {~"content-length", integer_to_binary(byte_size(AckBody))}
            ],
            AckBody},
    {Resp, Req}.
