-module(roadrunner_bench_drain_handler).
-moduledoc """
Roadrunner handler for `scripts/bench.escript --scenario large_post_streaming`.

Manual-mode body read: loops `roadrunner_req:read_body/2` with
`length => 64 KB` until the body is fully drained, then returns a
2-byte ack. Exercises the manual body_state machine + `recv_phase_bytes`
rate-limit interaction — paths with unit coverage but no bench coverage.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-define(CHUNK_LIMIT, 65536).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    Final = drain(Req),
    Resp =
        {200,
            [
                {~"content-type", ~"text/plain"},
                {~"content-length", ~"2"}
            ],
            ~"ok"},
    {Resp, Final}.

drain(Req) ->
    case roadrunner_req:read_body(Req, #{length => ?CHUNK_LIMIT}) of
        {ok, _Bytes, Req2} -> Req2;
        {more, _Bytes, Req2} -> drain(Req2)
    end.
