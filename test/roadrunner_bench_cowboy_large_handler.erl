-module(roadrunner_bench_cowboy_large_handler).
-moduledoc """
Cowboy handler for `scripts/bench.escript --scenarios large_response`.

Mirror of `roadrunner_bench_large_handler` for cowboy: returns a
64 KB `application/octet-stream` body. Body is cached in
`persistent_term` so the bench measures wire framing + send,
not body construction.
""".

-behaviour(cowboy_handler).

-on_load(init_body/0).

-export([init/2]).

-define(BODY_KEY, {?MODULE, body}).
-define(BODY_SIZE, 65536).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Body = persistent_term:get(?BODY_KEY),
    Resp = cowboy_req:reply(
        200,
        #{~"content-type" => ~"application/octet-stream"},
        Body,
        Req0
    ),
    {ok, Resp, State}.

-spec init_body() -> ok.
init_body() ->
    persistent_term:put(?BODY_KEY, binary:copy(~"x", ?BODY_SIZE)),
    ok.
