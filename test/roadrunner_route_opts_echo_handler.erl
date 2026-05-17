-module(roadrunner_route_opts_echo_handler).
-moduledoc """
Test fixture — replies with `term_to_binary(roadrunner_req:route_opts(Req))`
so tests can assert the per-handler opts attached via the
`routes => {Module, Opts}` listener shape reach the handler unchanged.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

handle(Req) ->
    Body = term_to_binary(roadrunner_req:route_opts(Req)),
    Headers = [
        {~"content-type", ~"application/octet-stream"},
        {~"content-length", integer_to_binary(byte_size(Body))},
        {~"connection", ~"close"}
    ],
    {{200, Headers, Body}, Req}.
