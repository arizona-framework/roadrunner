-module(roadrunner_bench_cowboy_small_chunks_handler).
-moduledoc """
Cowboy streaming handler for `scripts/bench.escript --scenarios small_chunked_response`.

Mirrors `roadrunner_bench_small_chunks_handler`: streams 100 × 64-byte
chunks via `cowboy_req:stream_body/3`.
""".

-behaviour(cowboy_handler).

-on_load(init_chunk/0).

-export([init/2]).

-define(CHUNK_KEY, {?MODULE, chunk}).
-define(CHUNK_SIZE, 64).
-define(NUM_CHUNKS, 100).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Chunk = persistent_term:get(?CHUNK_KEY),
    Req = cowboy_req:stream_reply(
        200,
        #{~"content-type" => ~"application/octet-stream"},
        Req0
    ),
    emit_chunks(Req, Chunk, ?NUM_CHUNKS - 1),
    {ok, Req, State}.

emit_chunks(Req, Chunk, 0) ->
    cowboy_req:stream_body(Chunk, fin, Req);
emit_chunks(Req, Chunk, N) ->
    cowboy_req:stream_body(Chunk, nofin, Req),
    emit_chunks(Req, Chunk, N - 1).

-spec init_chunk() -> ok.
init_chunk() ->
    persistent_term:put(?CHUNK_KEY, binary:copy(~"x", ?CHUNK_SIZE)),
    ok.
