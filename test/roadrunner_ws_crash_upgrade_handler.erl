-module(roadrunner_ws_crash_upgrade_handler).
-moduledoc """
Test fixture — `roadrunner_handler` functions that upgrade the request to
a WebSocket session (`roadrunner_ws_lifecycle_handler`) that goes wrong
on its first frame: `handle/1` raises, `bad_return/1` returns a shape
that is not a handler result, `bad_close/1` closes with an invalid code.
""".

-behaviour(roadrunner_handler).

-export([handle/1, bad_return/1, bad_close/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    {{websocket, roadrunner_ws_lifecycle_handler, #{on_frame => crash}}, Req}.

-spec bad_return(roadrunner_req:request()) -> roadrunner_handler:result().
bad_return(Req) ->
    {{websocket, roadrunner_ws_lifecycle_handler, #{on_frame => bad_return}}, Req}.

-spec bad_close(roadrunner_req:request()) -> roadrunner_handler:result().
bad_close(Req) ->
    {{websocket, roadrunner_ws_lifecycle_handler, #{on_frame => {close, 5000, ~"x"}}}, Req}.
