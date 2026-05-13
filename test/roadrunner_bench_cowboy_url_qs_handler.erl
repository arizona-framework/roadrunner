-module(roadrunner_bench_cowboy_url_qs_handler).
-moduledoc """
Cowboy handler for `scripts/bench.escript --scenarios url_with_qs`.

Mirror of `roadrunner_bench_url_qs_handler`: parses the URL's
query string via `cowboy_req:parse_qs/1` and returns the pair
count.
""".

-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Pairs = cowboy_req:parse_qs(Req0),
    AckBody = integer_to_binary(length(Pairs)),
    Resp = cowboy_req:reply(
        200,
        #{~"content-type" => ~"text/plain"},
        AckBody,
        Req0
    ),
    {ok, Resp, State}.
