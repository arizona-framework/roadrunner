-module(roadrunner_bench_cowboy_etag_handler).
-moduledoc """
Cowboy handler for `scripts/bench.escript --scenarios etag_304`.

Mirror of `roadrunner_bench_etag_handler`: returns 304 when the
request's If-None-Match matches `\"v1\"`, else 200 with body.
""".

-behaviour(cowboy_handler).

-export([init/2]).

-define(ETAG, ~"\"v1\"").
-define(BODY,
    ~"""
    {"status":"ok","data":[1,2,3]}
    """
).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req, State) ->
    case cowboy_req:header(~"if-none-match", Req) of
        ?ETAG ->
            Resp = cowboy_req:reply(
                304,
                #{~"etag" => ?ETAG},
                <<>>,
                Req
            ),
            {ok, Resp, State};
        _ ->
            Resp = cowboy_req:reply(
                200,
                #{
                    ~"content-type" => ~"application/json",
                    ~"etag" => ?ETAG
                },
                ?BODY,
                Req
            ),
            {ok, Resp, State}
    end.
