-module(roadrunner_echo_body_handler).
-moduledoc """
Test fixture — handler that echoes the request body back as the
response body. Used to verify that `roadrunner_conn` plumbs the buffered
body into the handler's request map.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    Body = roadrunner_req:body(Req),
    Resp =
        {200,
            [
                {~"content-type", ~"text/plain"},
                {~"content-length", integer_to_binary(iolist_size(Body))},
                {~"connection", ~"close"}
            ],
            Body},
    {Resp, Req}.
