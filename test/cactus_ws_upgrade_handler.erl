-module(cactus_ws_upgrade_handler).
-moduledoc """
Test fixture — a `cactus_handler` that always upgrades the request
to a WebSocket session driven by `cactus_ws_echo_handler`.
""".

-behaviour(cactus_handler).

-export([handle/1]).

-spec handle(cactus_http1:request()) -> cactus_handler:result().
handle(Req) ->
    {{websocket, cactus_ws_echo_handler, no_state}, Req}.
