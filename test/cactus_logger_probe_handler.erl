-module(cactus_logger_probe_handler).
-moduledoc """
Test fixture — returns the conn process's `logger:get_process_metadata/0`
contents and the request's `cactus_req:request_id/1` so tests can verify
per-request correlation is established before the handler runs.

The body is `term_to_binary(#{logger_metadata => Md, request_id => Id})`.
""".

-behaviour(cactus_handler).

-export([handle/1]).

handle(Req) ->
    Md = logger:get_process_metadata(),
    Id = cactus_req:request_id(Req),
    Body = term_to_binary(#{logger_metadata => Md, request_id => Id}),
    Headers = [
        {~"content-type", ~"application/octet-stream"},
        {~"content-length", integer_to_binary(byte_size(Body))}
    ],
    {{200, Headers, Body}, Req}.
