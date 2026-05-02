-module(roadrunner_bench_cowboy_handler).
-moduledoc """
Cowboy hello handler used by `scripts/bench.escript`.

Mirrors the response shape of `roadrunner_keepalive_handler` so the
two servers are comparable on the wire: 200 OK, `text/plain`, body
`alive\\r\\n`, no `Connection: close` so keep-alive engages.
""".

-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req, State) ->
    Resp = cowboy_req:reply(
        200,
        #{~"content-type" => ~"text/plain"},
        ~"alive\r\n",
        Req
    ),
    {ok, Resp, State}.
