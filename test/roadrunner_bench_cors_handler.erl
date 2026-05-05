-module(roadrunner_bench_cors_handler).
-moduledoc """
Roadrunner CORS preflight handler for `scripts/bench.escript --scenario cors_preflight`.

Responds to OPTIONS /api with `204 No Content` + CORS allow-headers.
The browser sends this preflight before any actual cross-origin
request, so it's a real hot path for SPAs.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    Resp =
        {204,
            [
                {~"access-control-allow-origin", ~"*"},
                {~"access-control-allow-methods", ~"GET, POST, PUT, DELETE, OPTIONS"},
                {~"access-control-allow-headers", ~"Content-Type, Authorization"},
                {~"access-control-max-age", ~"86400"},
                {~"content-length", ~"0"}
            ],
            ~""},
    {Resp, Req}.
