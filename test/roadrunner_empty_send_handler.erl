-module(roadrunner_empty_send_handler).
-moduledoc """
Test fixture — calls the stream `Send` callback with empty data
followed by a real chunk. Documents the empty-chunk special case
in `stream_frame/2`, and the terminator the framework writes for a
stream fun that returns without a `fin`.
""".

-behaviour(roadrunner_handler).

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
handle(#{target := ~"/unfinished"} = Req) ->
    %% Return without a fin: the framework ends the chunked body.
    Resp =
        {stream, 200, [{~"content-type", ~"text/plain"}], fun(Send) ->
            _ = Send(~"hi", nofin),
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
