-module(roadrunner_bench_httparena_baseline_handler).
-moduledoc """
Roadrunner handler for `scripts/bench.escript --scenarios httparena_baseline`.

Mirrors HttpArena's `baseline` profile: `GET /baseline11?a=I&b=I`
returns plaintext `integer_to_binary(A + B)`. Exercises query-string
parsing, integer parsing, and small plaintext response framing.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
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
        {Key, V} when is_binary(V) -> bin_int(V, Default);
        _ -> Default
    end.

%% Parse the leading (optionally signed) digits — the shape
%% `string:to_integer/1` accepted — without the unicode list
%% round-trip the string module pays per call. Mirrors the HttpArena
%% adapter's parser so bench profiles reflect what the adapter runs.
bin_int(<<$-, Rest/binary>>, Default) ->
    case leading_digits(Rest, 0, false) of
        {ok, N} -> -N;
        error -> Default
    end;
bin_int(Bin, Default) ->
    case leading_digits(Bin, 0, false) of
        {ok, N} -> N;
        error -> Default
    end.

leading_digits(<<D, Rest/binary>>, Acc, _Any) when D >= $0, D =< $9 ->
    leading_digits(Rest, Acc * 10 + (D - $0), true);
leading_digits(_Rest, _Acc, false) ->
    error;
leading_digits(_Rest, Acc, true) ->
    {ok, Acc}.
