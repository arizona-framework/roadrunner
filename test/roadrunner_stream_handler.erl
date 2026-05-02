-module(roadrunner_stream_handler).
-moduledoc """
Test fixture — streams `hello world` in two chunks plus the
size-0 terminator. Used to verify `roadrunner_conn` honors the
`{stream, ...}` return shape.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    Resp =
        {stream, 200, [{~"content-type", ~"text/plain; charset=utf-8"}], fun(Send) ->
            _ = Send(~"hello ", nofin),
            _ = Send(~"world", fin),
            ok
        end},
    {Resp, Req}.
