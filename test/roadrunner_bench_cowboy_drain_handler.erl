-module(roadrunner_bench_cowboy_drain_handler).
-moduledoc """
Cowboy handler for `scripts/bench.escript --scenario large_post_streaming`.

Mirror of `roadrunner_bench_drain_handler`: loops
`cowboy_req:read_body/1` until the body is fully drained, then
returns a 2-byte ack.
""".

-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Req1 = drain(Req0),
    Resp = cowboy_req:reply(
        200,
        #{~"content-type" => ~"text/plain"},
        ~"ok",
        Req1
    ),
    {ok, Resp, State}.

drain(Req) ->
    case cowboy_req:read_body(Req) of
        {ok, _Body, Req2} -> Req2;
        {more, _Body, Req2} -> drain(Req2)
    end.
