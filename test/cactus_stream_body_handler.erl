-module(cactus_stream_body_handler).
-moduledoc """
Test fixture — handler that reads the request body via
`cactus_req:read_body/1,2`. Routes:

- `POST /full`: reads the entire body via `read_body/1` and echoes it.
  Sets `Connection: close` (no keep-alive).
- `POST /chunks`: streams the body via `read_body/2` with a small
  `length` and concatenates the chunks, prefixed with the count.
- `POST /echo-keepalive`: reads body fully and threads `Req2` back
  so the conn drains and keep-alive engages.
- `POST /skip-keepalive`: does NOT read body; threads original `Req`
  back so the conn drains on its behalf.
- anything else: returns `200 no body`.
""".

-behaviour(cactus_handler).

-export([handle/1]).

handle(#{method := ~"POST", target := ~"/full"} = Req) ->
    {ok, Body, Req2} = cactus_req:read_body(Req),
    {reply(200, Body), Req2};
handle(#{method := ~"POST", target := ~"/chunks"} = Req) ->
    {Count, Body, Req2} = read_in_chunks(Req, 0, []),
    Out = iolist_to_binary([
        ~"chunks=", integer_to_binary(Count), ~" body=", Body
    ]),
    {reply(200, Out), Req2};
handle(#{method := ~"POST", target := ~"/echo-keepalive"} = Req) ->
    {ok, Body, Req2} = cactus_req:read_body(Req),
    {reply_keepalive(200, Body), Req2};
handle(#{method := ~"POST", target := ~"/skip-keepalive"} = Req) ->
    {reply_keepalive(200, ~"skipped"), Req};
handle(Req) ->
    {reply(200, ~"no body"), Req}.

read_in_chunks(Req, Count, Acc) ->
    case cactus_req:read_body(Req, #{length => 4}) of
        {ok, Bytes, Req2} ->
            {Count + 1, iolist_to_binary(lists:reverse([Bytes | Acc])), Req2};
        {more, Bytes, Req2} ->
            read_in_chunks(Req2, Count + 1, [Bytes | Acc])
    end.

reply(Status, Body) ->
    {Status,
        [
            {~"content-type", ~"text/plain"},
            {~"content-length", integer_to_binary(byte_size(Body))},
            {~"connection", ~"close"}
        ],
        Body}.

reply_keepalive(Status, Body) ->
    {Status,
        [
            {~"content-type", ~"text/plain"},
            {~"content-length", integer_to_binary(byte_size(Body))}
        ],
        Body}.
