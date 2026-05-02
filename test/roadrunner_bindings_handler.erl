-module(roadrunner_bindings_handler).
-moduledoc """
Test fixture — echoes the `id` binding back as the response body.
Used to verify router bindings reach the handler via
`roadrunner_req:bindings/1`.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    Bindings = roadrunner_req:bindings(Req),
    Id = maps:get(~"id", Bindings, ~"<unbound>"),
    Body = <<"id=", Id/binary>>,
    Resp =
        {200,
            [
                {~"content-type", ~"text/plain"},
                {~"content-length", integer_to_binary(byte_size(Body))},
                {~"connection", ~"close"}
            ],
            Body},
    {Resp, Req}.
