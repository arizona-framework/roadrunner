-module(cactus_hello_handler).
-moduledoc """
Default `cactus_handler` — answers every request with `200 Hello, cactus!`.

Used when no `handler` opt is passed to `cactus:start_listener/2`.
Replaces the hardcoded body cactus_conn carried before slice 3.
""".

-behaviour(cactus_handler).

-export([handle/1]).

-spec handle(cactus_http1:request()) ->
    {200, cactus_http1:headers(), iodata()}.
handle(_Req) ->
    Body = ~"Hello, cactus!\r\n",
    {200,
        [
            {~"content-type", ~"text/plain"},
            {~"content-length", integer_to_binary(byte_size(Body))},
            {~"connection", ~"close"}
        ],
        Body}.
