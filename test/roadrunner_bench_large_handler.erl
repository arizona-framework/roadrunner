-module(roadrunner_bench_large_handler).
-moduledoc """
Roadrunner handler for `scripts/bench.escript --scenario large_response`.

Returns a 64 KB `application/octet-stream` body for `GET /large`.
The body is computed once via `persistent_term` so the per-request
cost is `persistent_term:get/1` (constant) plus the wire write —
the bench is meant to measure per-request response framing + send
behavior, not body construction.
""".

-behaviour(roadrunner_handler).

-on_load(init_body/0).

-export([handle/1]).

-define(BODY_KEY, {?MODULE, body}).
-define(BODY_SIZE, 65536).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    Body = persistent_term:get(?BODY_KEY),
    Resp =
        {200,
            [
                {~"content-type", ~"application/octet-stream"},
                {~"content-length", integer_to_binary(byte_size(Body))}
            ],
            Body},
    {Resp, Req}.

-spec init_body() -> ok.
init_body() ->
    persistent_term:put(?BODY_KEY, binary:copy(~"x", ?BODY_SIZE)),
    ok.
