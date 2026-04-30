-module(cactus_keepalive_handler).
-moduledoc """
Test fixture — minimal 200 response with **no** `Connection: close`
header, so the conn layer's keep-alive logic can engage.
""".

-behaviour(cactus_handler).

-export([handle/1]).

-spec handle(cactus_http1:request()) ->
    {200, cactus_http1:headers(), iodata()}.
handle(_Req) ->
    Body = ~"alive\r\n",
    {200,
        [
            {~"content-type", ~"text/plain"},
            {~"content-length", integer_to_binary(byte_size(Body))}
        ],
        Body}.
