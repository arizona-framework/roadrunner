-module(cactus_stream_handler).
-moduledoc """
Test fixture — streams `hello world` in two chunks plus the
size-0 terminator. Used to verify `cactus_conn` honors the
`{stream, ...}` return shape.
""".

-behaviour(cactus_handler).

-export([handle/1]).

-spec handle(cactus_http1:request()) -> cactus_handler:response().
handle(_Req) ->
    {stream, 200, [{~"content-type", ~"text/plain; charset=utf-8"}], fun(Send) ->
        _ = Send(~"hello ", nofin),
        _ = Send(~"world", fin),
        ok
    end}.
