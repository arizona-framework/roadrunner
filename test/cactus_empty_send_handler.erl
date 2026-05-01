-module(cactus_empty_send_handler).
-moduledoc """
Test fixture — calls the stream `Send` callback with empty data
followed by a real chunk. Documents the empty-chunk special case
in `stream_frame/2`.
""".

-behaviour(cactus_handler).

-export([handle/1]).

handle(#{target := ~"/fin-empty"} = Req) ->
    %% Send a real chunk via nofin, then close with empty fin — the
    %% terminator should still be emitted (just without a leading chunk).
    Resp =
        {stream, 200, [{~"content-type", ~"text/plain"}], fun(Send) ->
            _ = Send(~"hi", nofin),
            _ = Send(~"", fin),
            ok
        end},
    {Resp, Req};
handle(Req) ->
    Resp =
        {stream, 200, [{~"content-type", ~"text/plain"}], fun(Send) ->
            _ = Send(~"", nofin),
            _ = Send(~"hi", fin),
            ok
        end},
    {Resp, Req}.
