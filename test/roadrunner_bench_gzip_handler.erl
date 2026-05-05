-module(roadrunner_bench_gzip_handler).
-moduledoc """
Roadrunner handler for `scripts/bench.escript --scenario gzip_response`.

Returns a 16 KB JSON-shaped body. Above the 860-byte threshold of
`roadrunner_compress`, well-compressible (repeating record shape)
so the bench measures gzip cost on a body shape that real APIs
emit (lists of similar JSON objects).

The compress middleware (configured at the listener level) adds
`Content-Encoding: gzip` when the request's `Accept-Encoding` allows.
""".

-behaviour(roadrunner_handler).

-on_load(init_body/0).

-export([handle/1]).

-define(BODY_KEY, {?MODULE, body}).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    Body = persistent_term:get(?BODY_KEY),
    Resp =
        {200,
            [
                {~"content-type", ~"application/json"},
                {~"content-length", integer_to_binary(byte_size(Body))}
            ],
            Body},
    {Resp, Req}.

-spec init_body() -> ok.
init_body() ->
    %% Build ~16 KB of repeating JSON record shape — gzip should
    %% reduce this by ~95% (one repeating dictionary entry).
    Record = ~"""
    {"id":"01J8X9Z3K7QFRBQ4PCVE5K8RNH","name":"item","status":"active","tags":["a","b","c"]}
    """,
    %% 90 bytes per record, 180 records ≈ 16.2 KB.
    Records = [Record || _ <- lists:seq(1, 180)],
    Body = iolist_to_binary([
        ~"[",
        lists:join(~",", Records),
        ~"]"
    ]),
    persistent_term:put(?BODY_KEY, Body),
    ok.
