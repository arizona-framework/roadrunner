-module(cactus_trailers_handler).
-moduledoc """
Test fixture — streams a body and ends with `Send(_, {fin, Trailers})`
to emit trailer headers after the size-0 terminator.
""".

-behaviour(cactus_handler).

-export([handle/1]).

handle(Req) ->
    Resp =
        {stream, 200, [{~"trailer", ~"x-trailer-one, x-trailer-two"}], fun(Send) ->
            _ = Send(~"hello", nofin),
            _ = Send(
                ~" world",
                {fin, [
                    {~"x-trailer-one", ~"alpha"},
                    {~"x-trailer-two", ~"beta"}
                ]}
            ),
            ok
        end},
    {Resp, Req}.
