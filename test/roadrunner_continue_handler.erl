-module(roadrunner_continue_handler).
-moduledoc """
Test fixture for manual body mode and `Expect: 100-continue`: `/reject`
answers 401 without reading the body, `/slow-read` spends 1.1 s (past the
slow-client rate grace) before reading it, `/stream-echo` starts a streamed
answer and then reads the body and streams it back, `/read-then-stream`
reads it and then streams it back, and any other path reads it and answers
with its size.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(#{target := ~"/reject"} = Req) ->
    {roadrunner_resp:text(401, ~"no"), Req};
handle(#{target := ~"/slow-read"} = Req) ->
    receive
    after 1100 -> ok
    end,
    read(Req);
handle(#{target := ~"/stream-echo"} = Req) ->
    Fun = fun(Send) ->
        {ok, Body, _} = roadrunner_req:read_body(Req),
        _ = Send(Body, fin),
        ok
    end,
    {{stream, 200, [{~"content-type", ~"text/plain"}], Fun}, Req};
handle(#{target := ~"/read-then-stream"} = Req) ->
    {ok, Body, _} = roadrunner_req:read_body(Req),
    Fun = fun(Send) ->
        _ = Send(Body, fin),
        ok
    end,
    {{stream, 200, [{~"content-type", ~"text/plain"}], Fun}, Req};
handle(Req) ->
    read(Req).

read(Req) ->
    {ok, Body, Req2} = roadrunner_req:read_body(Req),
    {roadrunner_resp:text(200, integer_to_binary(iolist_size(Body))), Req2}.
