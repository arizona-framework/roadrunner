-module(roadrunner_bench_etag_handler).
-moduledoc """
Roadrunner handler for `scripts/bench.escript --scenario etag_304`.

Conditional GET: when `If-None-Match: "v1"` matches the server's
fixed ETag, returns `304 Not Modified` with no body. Otherwise
returns `200 OK` with a small JSON body. Tests the conditional
short-circuit response path that real caching layers (CDNs,
browsers, varnish) hit constantly.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-define(ETAG, ~"\"v1\"").
-define(BODY,
    ~"""
    {"status":"ok","data":[1,2,3]}
    """
).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    case roadrunner_req:header(~"if-none-match", Req) of
        ?ETAG ->
            Resp =
                {304,
                    [
                        {~"etag", ?ETAG},
                        {~"content-length", ~"0"}
                    ],
                    ~""},
            {Resp, Req};
        _ ->
            Resp =
                {200,
                    [
                        {~"content-type", ~"application/json"},
                        {~"etag", ?ETAG},
                        {~"content-length", integer_to_binary(byte_size(?BODY))}
                    ],
                    ?BODY},
            {Resp, Req}
    end.
