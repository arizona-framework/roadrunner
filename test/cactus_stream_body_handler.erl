-module(cactus_stream_body_handler).
-moduledoc """
Test fixture — handler that reads the request body via
`cactus_req:read_body/1,2`. Two paths:

- `GET-style` paths (no body): just returns 200 with `no body`.
- `POST /full`: reads the entire body via `read_body/1` and echoes it.
- `POST /chunks`: streams the body via `read_body/2` with a small
  `length` and concatenates the chunks, prefixed with the count.
""".

-behaviour(cactus_handler).

-export([handle/1]).

handle(#{method := ~"POST", target := ~"/full"} = Req) ->
    {ok, Body, _Req2} = cactus_req:read_body(Req),
    reply(200, Body);
handle(#{method := ~"POST", target := ~"/chunks"} = Req) ->
    {Count, Body} = read_in_chunks(Req, 0, []),
    Out = iolist_to_binary([
        ~"chunks=", integer_to_binary(Count), ~" body=", Body
    ]),
    reply(200, Out);
handle(_Req) ->
    reply(200, ~"no body").

read_in_chunks(Req, Count, Acc) ->
    case cactus_req:read_body(Req, #{length => 4}) of
        {ok, Bytes, _Req2} -> {Count + 1, iolist_to_binary(lists:reverse([Bytes | Acc]))};
        {more, Bytes, Req2} -> read_in_chunks(Req2, Count + 1, [Bytes | Acc])
    end.

reply(Status, Body) ->
    {Status,
        [
            {~"content-type", ~"text/plain"},
            {~"content-length", integer_to_binary(byte_size(Body))},
            {~"connection", ~"close"}
        ],
        Body}.
