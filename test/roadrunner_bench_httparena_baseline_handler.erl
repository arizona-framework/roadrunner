-module(roadrunner_bench_httparena_baseline_handler).
-moduledoc """
Roadrunner handler for `scripts/bench.escript --scenario httparena_baseline`.

Mirrors HttpArena's `baseline` profile: `GET /baseline11?a=I&b=I`
returns plaintext `integer_to_binary(A + B)`. Exercises query-string
parsing, integer parsing, and small plaintext response framing.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    A = qs_int(~"a", Req, 0),
    B = qs_int(~"b", Req, 0),
    Body = integer_to_binary(A + B),
    Resp =
        {200,
            [
                {~"content-type", ~"text/plain"},
                {~"content-length", integer_to_binary(byte_size(Body))}
            ],
            Body},
    {Resp, Req}.

qs_int(Key, Req, Default) ->
    case lists:keyfind(Key, 1, roadrunner_req:parse_qs(Req)) of
        {Key, V} when is_binary(V) ->
            case string:to_integer(V) of
                {N, _} when is_integer(N) -> N;
                _ -> Default
            end;
        _ ->
            Default
    end.
