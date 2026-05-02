-module(roadrunner_ws_upgrade_handler).
-moduledoc """
Test fixture — a `roadrunner_handler` that always upgrades the request
to a WebSocket session driven by `roadrunner_ws_echo_handler`.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    {{websocket, roadrunner_ws_echo_handler, no_state}, Req}.
