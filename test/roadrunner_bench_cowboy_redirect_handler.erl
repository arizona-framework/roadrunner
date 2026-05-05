-module(roadrunner_bench_cowboy_redirect_handler).
-moduledoc """
Cowboy redirect handler for `scripts/bench.escript --scenario redirect_response`.

Mirror of `roadrunner_bench_redirect_handler`: 302 + Location.
""".

-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Resp = cowboy_req:reply(
        302,
        #{~"location" => ~"/target"},
        <<>>,
        Req0
    ),
    {ok, Resp, State}.
