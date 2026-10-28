-module(roadrunner_ws_crash_upgrade_handler).
-moduledoc """
Test fixture — a `roadrunner_handler` that upgrades the request to a
WebSocket session whose handler (`roadrunner_ws_lifecycle_handler`)
raises on the first frame.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    {{websocket, roadrunner_ws_lifecycle_handler, #{on_frame => crash}}, Req}.
