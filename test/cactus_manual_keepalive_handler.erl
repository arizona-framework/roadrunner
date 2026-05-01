-module(cactus_manual_keepalive_handler).
-moduledoc """
Test fixture for `cactus_conn_statem`'s manual-mode keep-alive
finishing path: explicitly reads the body via `cactus_req:read_body/1`
so the `body_state` is fully drained, and emits a keep-alive-friendly
response (no `Connection: close`).
""".

-behaviour(cactus_handler).

-export([handle/1]).

-spec handle(cactus_http1:request()) -> cactus_handler:result().
handle(Req) ->
    {ok, _Body, Req2} = cactus_req:read_body(Req),
    Resp = {200, [{~"content-length", ~"2"}], ~"ok"},
    {Resp, Req2}.
