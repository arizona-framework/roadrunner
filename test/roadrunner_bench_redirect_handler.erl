-module(roadrunner_bench_redirect_handler).
-moduledoc """
Roadrunner redirect handler for `scripts/bench.escript --scenarios redirect_response`.

Returns 302 with `Location: /target`. Common pattern for login
flows, deprecated-URL forwarding, etc.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    Resp =
        {302,
            [
                {~"location", ~"/target"},
                {~"content-length", ~"0"}
            ],
            ~""},
    {Resp, Req}.
