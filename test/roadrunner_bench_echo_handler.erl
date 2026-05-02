-module(roadrunner_bench_echo_handler).
-moduledoc """
Roadrunner handler for `scripts/bench_vs_cowboy.escript --scenario realistic`.

Reads the request body (delivered via auto buffering) and echoes it
back in the response with `Content-Type: application/octet-stream`.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(#{body := Body} = Req) ->
    Resp =
        {200,
            [
                {~"content-type", ~"application/octet-stream"},
                {~"content-length", integer_to_binary(byte_size(Body))}
            ],
            Body},
    {Resp, Req};
handle(Req) ->
    %% No body (e.g., GET) — return empty 200.
    Resp =
        {200,
            [
                {~"content-type", ~"application/octet-stream"},
                {~"content-length", ~"0"}
            ],
            ~""},
    {Resp, Req}.
