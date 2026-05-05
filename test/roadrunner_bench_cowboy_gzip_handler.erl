-module(roadrunner_bench_cowboy_gzip_handler).
-moduledoc """
Cowboy handler for `scripts/bench.escript --scenario gzip_response`.

Mirror of `roadrunner_bench_gzip_handler` for cowboy. Compression
is applied by `cowboy_compress_h` configured in the listener's
`stream_handlers` opt — the handler itself is unaware.
""".

-behaviour(cowboy_handler).

-on_load(init_body/0).

-export([init/2]).

-define(BODY_KEY, {?MODULE, body}).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Body = persistent_term:get(?BODY_KEY),
    Resp = cowboy_req:reply(
        200,
        #{~"content-type" => ~"application/json"},
        Body,
        Req0
    ),
    {ok, Resp, State}.

-spec init_body() -> ok.
init_body() ->
    Record = ~"""
    {"id":"01J8X9Z3K7QFRBQ4PCVE5K8RNH","name":"item","status":"active","tags":["a","b","c"]}
    """,
    Records = [Record || _ <- lists:seq(1, 180)],
    Body = iolist_to_binary([
        ~"[",
        lists:join(~",", Records),
        ~"]"
    ]),
    persistent_term:put(?BODY_KEY, Body),
    ok.
