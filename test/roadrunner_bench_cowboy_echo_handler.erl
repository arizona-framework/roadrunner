-module(roadrunner_bench_cowboy_echo_handler).
-moduledoc """
Cowboy handler for `scripts/bench.escript --scenarios echo`.

Mirror of `roadrunner_bench_echo_handler` for cowboy: reads the
request body and echoes it back. Body is read via
`cowboy_req:read_body/1` (which returns `{ok, Body, Req}` for
content-length-bounded reads).
""".

-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Resp = cowboy_req:reply(
        200,
        #{~"content-type" => ~"application/octet-stream"},
        Body,
        Req1
    ),
    {ok, Resp, State}.
