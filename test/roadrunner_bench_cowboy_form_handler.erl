-module(roadrunner_bench_cowboy_form_handler).
-moduledoc """
Cowboy handler for `scripts/bench.escript --scenario post_4kb_form`.

Mirror of `roadrunner_bench_form_handler` for cowboy: reads the
form body via `cowboy_req:read_urlencoded_body/1` (which both reads
and parses) and returns the pair count.
""".

-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    {ok, Pairs, Req1} = cowboy_req:read_urlencoded_body(Req0),
    AckBody = integer_to_binary(length(Pairs)),
    Resp = cowboy_req:reply(
        200,
        #{~"content-type" => ~"text/plain"},
        AckBody,
        Req1
    ),
    {ok, Resp, State}.
