-module(roadrunner_explicit_date_handler).
-moduledoc """
Test fixture — a handler that emits its OWN `Date` header. Used by
`roadrunner_conn_tests:conn_handler_emitted_date_is_preserved_test_/0`
to confirm `roadrunner_conn_loop`'s auto-Date injection defers to
handler-supplied values.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    Headers = [
        {~"content-type", ~"text/plain; charset=utf-8"},
        {~"date", ~"Sun, 06 Nov 1994 08:49:37 GMT"}
    ],
    {{200, Headers, ~"fixture\n"}, Req}.
