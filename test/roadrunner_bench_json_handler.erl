-module(roadrunner_bench_json_handler).
-moduledoc """
Roadrunner handler for `scripts/bench.escript --scenarios json`.

Returns a fixed JSON body (~120 bytes) with `Content-Type:
application/json`. The body and `Content-Length` are precomputed at
module load and stashed in `persistent_term` so the bench measures
wire framing + dispatch, not body construction.
""".

-behaviour(roadrunner_handler).

-on_load(init_body/0).

-export([handle/1]).

-define(BODY_KEY, {?MODULE, body}).
-define(LEN_KEY, {?MODULE, len}).

%% Realistic-ish API response shape: a small object with nested
%% data + a few primitives. ~120 bytes — typical of a single-item
%% REST GET response, big enough to differ from `hello`'s 7-byte
%% body but small enough to stay below the HEADERS+DATA atomic
%% threshold.
-define(JSON_BODY,
    ~"""
    {"id":"01J8X9Z3K7QFRBQ4PCVE5K8RNH","status":"ok","data":{"name":"roadrunner","version":2,"flags":["alpha","beta"]}}
    """
).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    Resp =
        {200,
            [
                {~"content-type", ~"application/json"},
                {~"content-length", persistent_term:get(?LEN_KEY)}
            ],
            persistent_term:get(?BODY_KEY)},
    {Resp, Req}.

-spec init_body() -> ok.
init_body() ->
    persistent_term:put(?BODY_KEY, ?JSON_BODY),
    persistent_term:put(?LEN_KEY, integer_to_binary(byte_size(?JSON_BODY))),
    ok.
