-module(roadrunner_bench_httparena_upload_handler).
-moduledoc """
Roadrunner handler for `scripts/bench.escript --scenarios
httparena_upload_20mb_auto` and `--scenarios
httparena_upload_20mb_manual`.

Mirrors HttpArena's `upload` profile: `POST /upload` returns the
plaintext byte count of the request body. Two pattern-match
clauses cover both buffering modes:

- `body_buffering => auto` (default): the conn pre-buffers the body
  into `#{body := Body}` as `iodata()`; handler reads the field and
  uses `iolist_size/1` to count bytes without flattening.
- `body_buffering => manual`: handler drains the body in 64 KB
  chunks via `roadrunner_req:read_body/2`, counting bytes per
  chunk without retaining them. Peak memory stays bounded even on
  20 MB bodies.

Same workload shape, two server-side paths. The pair is the
empirical reproduction of HttpArena's auto-mode 4.1 GiB memory
peak on the 20 MB upload validator.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-define(CHUNK_LIMIT, 65536).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(#{body := Body} = Req) ->
    ack(iolist_size(Body), Req);
handle(Req) ->
    {Count, Req2} = drain(Req, 0),
    ack(Count, Req2).

drain(Req, Acc) ->
    case roadrunner_req:read_body(Req, #{length => ?CHUNK_LIMIT}) of
        {ok, Bytes, Req2} -> {Acc + iolist_size(Bytes), Req2};
        {more, Bytes, Req2} -> drain(Req2, Acc + iolist_size(Bytes))
    end.

ack(Count, Req) ->
    Body = integer_to_binary(Count),
    Resp =
        {200,
            [
                {~"content-type", ~"text/plain"},
                {~"content-length", integer_to_binary(byte_size(Body))}
            ],
            Body},
    {Resp, Req}.
