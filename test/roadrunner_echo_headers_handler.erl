-module(roadrunner_echo_headers_handler).
-moduledoc """
Test fixture — emits two request header values (`x-mw-fun` and
`x-mw-mod`) in the response body so middleware request-side mutation
is observable end-to-end.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

handle(Req) ->
    Fun = value(roadrunner_req:header(~"x-mw-fun", Req)),
    Mod = value(roadrunner_req:header(~"x-mw-mod", Req)),
    Body = iolist_to_binary([~"fun=", Fun, ~" mod=", Mod]),
    Resp =
        {200,
            [
                {~"content-type", ~"text/plain"},
                {~"content-length", integer_to_binary(byte_size(Body))},
                {~"connection", ~"close"}
            ],
            Body},
    {Resp, Req}.

value(undefined) -> ~"none";
value(V) -> V.
