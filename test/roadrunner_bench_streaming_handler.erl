-module(roadrunner_bench_streaming_handler).
-moduledoc """
Roadrunner handler for `scripts/bench.escript --scenarios streaming_response`.

Returns a `{stream, _, _, Fun}` shape that emits the response body
in 4 × 4 KB chunks via the `Send/2` callback. Exercises the
`roadrunner_http2_stream_response` (h2) and `roadrunner_stream_response`
(h1) worker paths — code that has unit-test coverage but no bench
coverage.

The chunks are precomputed at module load and stashed in
`persistent_term` so the bench measures stream emission +
fragmentation cost, not body construction.
""".

-behaviour(roadrunner_handler).

-on_load(init_chunks/0).

-export([handle/1]).

-define(CHUNK_KEY, {?MODULE, chunk}).
-define(CHUNK_SIZE, 4096).
-define(NUM_CHUNKS, 4).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    Chunk = persistent_term:get(?CHUNK_KEY),
    Fun = fun(Send) ->
        emit_chunks(Send, Chunk, ?NUM_CHUNKS - 1)
    end,
    Resp = {stream, 200, [{~"content-type", ~"application/octet-stream"}], Fun},
    {Resp, Req}.

%% Body recursion: send N nofin chunks, then one fin chunk.
emit_chunks(Send, Chunk, 0) ->
    Send(Chunk, fin);
emit_chunks(Send, Chunk, N) ->
    Send(Chunk, nofin),
    emit_chunks(Send, Chunk, N - 1).

-spec init_chunks() -> ok.
init_chunks() ->
    persistent_term:put(?CHUNK_KEY, binary:copy(~"x", ?CHUNK_SIZE)),
    ok.
