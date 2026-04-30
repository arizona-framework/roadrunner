-module(cactus_keepalive_handler).
-moduledoc """
Test fixture — minimal 200 response with **no** `Connection: close`
header, so the conn layer's keep-alive logic can engage.
""".

-behaviour(cactus_handler).

-export([handle/1]).

-spec handle(cactus_http1:request()) -> cactus_handler:result().
handle(Req) ->
    Body = ~"alive\r\n",
    Resp =
        {200,
            [
                {~"content-type", ~"text/plain"},
                {~"content-length", integer_to_binary(byte_size(Body))}
            ],
            Body},
    {Resp, Req}.
