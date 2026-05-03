-module(roadrunner_conn_loop_lazy_manual_handler).
-moduledoc """
Test fixture — manual-mode handler that returns 200 immediately
WITHOUT reading the request body. The conn's `finishing_phase`
must then `drain_body/1` the unread bytes from the
`body_state`. When the recv during drain fails (test sink replies
`{error, closed}`), `drain_body` returns `{error, _}` and the
conn must exit cleanly. Covers
`roadrunner_conn_loop:buffered_finish/4`'s drain-failure branch.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    Resp = {200, [{~"content-length", ~"2"}], ~"ok"},
    {Resp, Req}.
