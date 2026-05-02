-module(roadrunner_keepalive_handler).
-moduledoc """
Test fixture — minimal 200 response with **no** `Connection: close`
header, so the conn layer's keep-alive logic can engage.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
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
