-module(roadrunner_bench_cowboy_json_handler).
-moduledoc """
Cowboy JSON handler for `scripts/bench.escript --scenarios json`.

Mirrors `roadrunner_bench_json_handler` so cowboy and roadrunner
return the same wire bytes for the `json` scenario.
""".

-behaviour(cowboy_handler).

-on_load(init_body/0).

-export([init/2]).

-define(BODY_KEY, {?MODULE, body}).

-define(JSON_BODY,
    ~"""
    {"id":"01J8X9Z3K7QFRBQ4PCVE5K8RNH","status":"ok","data":{"name":"roadrunner","version":2,"flags":["alpha","beta"]}}
    """
).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req, State) ->
    Resp = cowboy_req:reply(
        200,
        #{~"content-type" => ~"application/json"},
        persistent_term:get(?BODY_KEY),
        Req
    ),
    {ok, Resp, State}.

-spec init_body() -> ok.
init_body() ->
    persistent_term:put(?BODY_KEY, ?JSON_BODY),
    ok.
