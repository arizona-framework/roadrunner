-module(cactus_echo_body_handler).
-moduledoc """
Test fixture — handler that echoes the request body back as the
response body. Used to verify that `cactus_conn` plumbs the buffered
body into the handler's request map.
""".

-behaviour(cactus_handler).

-export([handle/1]).

-spec handle(cactus_http1:request()) -> cactus_handler:result().
handle(Req) ->
    Body = cactus_req:body(Req),
    Resp =
        {200,
            [
                {~"content-type", ~"text/plain"},
                {~"content-length", integer_to_binary(byte_size(Body))},
                {~"connection", ~"close"}
            ],
            Body},
    {Resp, Req}.
