-module(roadrunner_bench_cowboy_ws_handler).
-moduledoc """
Cowboy WebSocket echo handler for `scripts/bench.escript --scenarios
websocket_msg_throughput`.

Mirror of `roadrunner_ws_echo_handler`'s behavior: echoes any text
frame back unchanged. Wired in via cowboy_router so the upgrade
happens on `GET /ws`.
""".

-behaviour(cowboy_handler).

-export([init/2, websocket_handle/2, websocket_info/2]).

-spec init(cowboy_req:req(), term()) -> {cowboy_websocket, cowboy_req:req(), term()}.
init(Req, State) ->
    {cowboy_websocket, Req, State}.

-spec websocket_handle(term(), term()) -> {list(), term()}.
websocket_handle({text, Payload}, State) ->
    {[{text, Payload}], State};
websocket_handle(_Frame, State) ->
    {[], State}.

-spec websocket_info(term(), term()) -> {list(), term()}.
websocket_info(_Info, State) ->
    {[], State}.
