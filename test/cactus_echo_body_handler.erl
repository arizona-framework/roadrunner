-module(cactus_echo_body_handler).
-moduledoc """
Test fixture — handler that echoes the request body back as the
response body. Used to verify that `cactus_conn` plumbs the buffered
body into the handler's request map.
""".

-behaviour(cactus_handler).

-export([handle/1]).

-spec handle(cactus_http1:request()) ->
    {200, cactus_http1:headers(), iodata()}.
handle(Req) ->
    Body = cactus_req:body(Req),
    {200,
        [
            {~"content-type", ~"text/plain"},
            {~"content-length", integer_to_binary(byte_size(Body))},
            {~"connection", ~"close"}
        ],
        Body}.
