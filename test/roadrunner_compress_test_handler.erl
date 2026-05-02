-module(roadrunner_compress_test_handler).
-moduledoc """
Test fixture — emits a body of about 1 KB so the compression
threshold doesn't kick in. Used by `roadrunner_compress_tests` for the
end-to-end round-trip.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

handle(Req) ->
    Body = iolist_to_binary(lists:duplicate(80, ~"<h1>arizona</h1>")),
    Resp =
        {200,
            [
                {~"content-type", ~"text/html; charset=utf-8"},
                {~"content-length", integer_to_binary(byte_size(Body))},
                {~"connection", ~"close"}
            ],
            Body},
    {Resp, Req}.
