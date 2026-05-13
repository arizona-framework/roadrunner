-module(roadrunner_bench_small_chunks_handler).
-moduledoc """
Roadrunner handler for `scripts/bench.escript --scenarios small_chunked_response`.

Streams 100 × 64-byte chunks via `{stream, _, _, Fun}` — distinct
from `streaming_response`'s 4 × 4 KB. Tests fragmentation overhead
(per-chunk DATA-frame headers on h2, per-chunk size lines on h1
chunked encoding) where the per-chunk overhead matters more than
the payload size.
""".

-behaviour(roadrunner_handler).

-on_load(init_chunk/0).

-export([handle/1]).

-define(CHUNK_KEY, {?MODULE, chunk}).
-define(CHUNK_SIZE, 64).
-define(NUM_CHUNKS, 100).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    Chunk = persistent_term:get(?CHUNK_KEY),
    Fun = fun(Send) ->
        emit_chunks(Send, Chunk, ?NUM_CHUNKS - 1)
    end,
    Resp = {stream, 200, [{~"content-type", ~"application/octet-stream"}], Fun},
    {Resp, Req}.

emit_chunks(Send, Chunk, 0) ->
    Send(Chunk, fin);
emit_chunks(Send, Chunk, N) ->
    Send(Chunk, nofin),
    emit_chunks(Send, Chunk, N - 1).

-spec init_chunk() -> ok.
init_chunk() ->
    persistent_term:put(?CHUNK_KEY, binary:copy(~"x", ?CHUNK_SIZE)),
    ok.
