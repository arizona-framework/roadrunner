-module(roadrunner_bench_cowboy_cors_handler).
-moduledoc """
Cowboy CORS preflight handler for `scripts/bench.escript --scenarios cors_preflight`.

Mirror of `roadrunner_bench_cors_handler`: returns 204 + CORS
allow-headers.
""".

-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Resp = cowboy_req:reply(
        204,
        #{
            ~"access-control-allow-origin" => ~"*",
            ~"access-control-allow-methods" => ~"GET, POST, PUT, DELETE, OPTIONS",
            ~"access-control-allow-headers" => ~"Content-Type, Authorization",
            ~"access-control-max-age" => ~"86400"
        },
        <<>>,
        Req0
    ),
    {ok, Resp, State}.
