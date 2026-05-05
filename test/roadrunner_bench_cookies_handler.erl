-module(roadrunner_bench_cookies_handler).
-moduledoc """
Roadrunner handler for `scripts/bench.escript --scenario cookies_heavy`.

Calls `roadrunner_req:parse_cookies/1` and returns the cookie
count. Tests the cookie-header parser hot path (single `Cookie:`
header with N pairs separated by `; `).
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    Cookies = roadrunner_req:parse_cookies(Req),
    AckBody = integer_to_binary(length(Cookies)),
    Resp =
        {200,
            [
                {~"content-type", ~"text/plain"},
                {~"content-length", integer_to_binary(byte_size(AckBody))}
            ],
            AckBody},
    {Resp, Req}.
