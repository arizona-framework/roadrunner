-module(roadrunner_evil_trailers_handler).
-moduledoc """
Test fixture — streams a body and then sends a trailer with a CRLF
in the value. The conn must reject this via the header-safety check
in `encode_trailers`; the wire output must not contain the
attacker-injected line.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

handle(Req) ->
    Resp =
        {stream, 200, [{~"trailer", ~"x-bad"}], fun(Send) ->
            _ = Send(~"hello", {fin, [{~"x-bad", ~"value\r\nInjected: yes"}]}),
            ok
        end},
    {Resp, Req}.
