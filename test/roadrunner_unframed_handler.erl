-module(roadrunner_unframed_handler).
-moduledoc """
Test fixture: buffered responses built as plain tuples, most without a
`content-length`, keyed by path, for the HTTP/1.1 framing checks.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    {response(roadrunner_req:path(Req)), Req}.

response(~"/binary") ->
    {200, [{~"content-type", ~"text/plain"}], ~"hello"};
response(~"/iolist") ->
    {200, [{~"content-type", ~"text/plain"}], [~"ab", [~"cd", $e]]};
response(~"/own-length") ->
    {200, [{~"content-length", ~"5"}], ~"hello"};
response(~"/chunked") ->
    {200, [{~"transfer-encoding", ~"chunked"}], ~"5\r\nhello\r\n0\r\n\r\n"};
response(~"/no-content") ->
    {204, [], ~""}.
