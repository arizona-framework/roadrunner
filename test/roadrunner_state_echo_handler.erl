-module(roadrunner_state_echo_handler).
-moduledoc """
Test fixture — replies with `term_to_binary(roadrunner_req:state(Req))`
so tests can assert the per-handler state attached via the
`routes => {Module, State}` listener shape reaches the handler unchanged.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

handle(Req) ->
    Body = term_to_binary(roadrunner_req:state(Req)),
    Headers = [
        {~"content-type", ~"application/octet-stream"},
        {~"content-length", integer_to_binary(byte_size(Body))},
        {~"connection", ~"close"}
    ],
    {{200, Headers, Body}, Req}.
