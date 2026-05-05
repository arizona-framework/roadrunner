-module(roadrunner_bench_elli_handler).
-moduledoc """
Elli callback module for `scripts/bench.escript`.

Three routes — same shape as the cowboy / roadrunner fixtures so the
three servers respond identically on the wire:

- `GET /`       → `200 / text/plain / "alive\\r\\n"` (hello scenario)
- `POST /echo`  → `200 / application/octet-stream / <body>` (echo)
- `GET /large`  → `200 / application/octet-stream / 64 KB` (large_response)

The 64 KB body is cached in `persistent_term` so the bench measures
wire framing + send, not body construction.

`handle_event/3` is part of the elli_handler behaviour and required
even when we don't subscribe to any events.
""".

-behaviour(elli_handler).

-on_load(init_body/0).

-export([handle/2, handle_event/3]).

-define(LARGE_BODY_KEY, {?MODULE, large_body}).
-define(LARGE_BODY_SIZE, 65536).
-define(JSON_BODY_KEY, {?MODULE, json_body}).

-define(JSON_BODY,
    ~"""
    {"id":"01J8X9Z3K7QFRBQ4PCVE5K8RNH","status":"ok","data":{"name":"roadrunner","version":2,"flags":["alpha","beta"]}}
    """
).

-spec handle(elli:req(), elli_handler:callback_args()) -> elli_handler:result().
handle(Req, _Args) ->
    handle(elli_request:method(Req), elli_request:path(Req), Req).

handle('GET', [], _Req) ->
    {ok, [{~"content-type", ~"text/plain"}], ~"alive\r\n"};
handle('POST', [<<"echo">>], Req) ->
    Body = elli_request:body(Req),
    {ok, [{~"content-type", ~"application/octet-stream"}], Body};
handle('GET', [<<"large">>], _Req) ->
    Body = persistent_term:get(?LARGE_BODY_KEY),
    {ok, [{~"content-type", ~"application/octet-stream"}], Body};
handle('GET', [<<"json">>], _Req) ->
    Body = persistent_term:get(?JSON_BODY_KEY),
    {ok, [{~"content-type", ~"application/json"}], Body};
handle(_Method, _Path, _Req) ->
    {404, [], ~""}.

-spec handle_event(elli_handler:event(), list(), elli_handler:callback_args()) -> ok.
handle_event(_Event, _Data, _Args) ->
    ok.

-spec init_body() -> ok.
init_body() ->
    persistent_term:put(?LARGE_BODY_KEY, binary:copy(~"x", ?LARGE_BODY_SIZE)),
    persistent_term:put(?JSON_BODY_KEY, ?JSON_BODY),
    ok.
