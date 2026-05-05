-module(roadrunner_bench_cowboy_cookies_handler).
-moduledoc """
Cowboy handler for `scripts/bench.escript --scenario cookies_heavy`.

Mirror of `roadrunner_bench_cookies_handler` — parses the request's
cookies via `cowboy_req:parse_cookies/1` and returns the cookie
count.
""".

-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Cookies = cowboy_req:parse_cookies(Req0),
    AckBody = integer_to_binary(length(Cookies)),
    Resp = cowboy_req:reply(
        200,
        #{~"content-type" => ~"text/plain"},
        AckBody,
        Req0
    ),
    {ok, Resp, State}.
