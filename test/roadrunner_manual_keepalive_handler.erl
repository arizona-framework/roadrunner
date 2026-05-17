-module(roadrunner_manual_keepalive_handler).
-moduledoc """
Test fixture for the manual-mode keep-alive finishing path:
explicitly reads the body via `roadrunner_req:read_body/1` so the
`body_reader` is fully drained, and emits a keep-alive-friendly
response (no `Connection: close`).
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    {ok, _Body, Req2} = roadrunner_req:read_body(Req),
    Resp = {200, [{~"content-length", ~"2"}], ~"ok"},
    {Resp, Req2}.
