-module(roadrunner_bench_elli_handler).
-moduledoc """
Elli callback module for `scripts/bench_vs_cowboy.escript`.

Two routes — same shape as the cowboy / roadrunner fixtures so the
three servers respond identically on the wire:

- `GET /`      → `200 / text/plain / "alive\\r\\n"` (hello scenario)
- `POST /echo` → `200 / application/octet-stream / <body>` (echo scenario)

`handle_event/3` is part of the elli_handler behaviour and required
even when we don't subscribe to any events.
""".

-behaviour(elli_handler).

-export([handle/2, handle_event/3]).

-spec handle(elli:req(), elli_handler:callback_args()) -> elli_handler:result().
handle(Req, _Args) ->
    handle(elli_request:method(Req), elli_request:path(Req), Req).

handle('GET', [], _Req) ->
    {ok, [{~"content-type", ~"text/plain"}], ~"alive\r\n"};
handle('POST', [<<"echo">>], Req) ->
    Body = elli_request:body(Req),
    {ok, [{~"content-type", ~"application/octet-stream"}], Body};
handle(_Method, _Path, _Req) ->
    {404, [], ~""}.

-spec handle_event(elli_handler:event(), list(), elli_handler:callback_args()) -> ok.
handle_event(_Event, _Data, _Args) ->
    ok.
