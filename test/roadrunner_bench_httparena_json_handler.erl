-module(roadrunner_bench_httparena_json_handler).
-moduledoc """
Roadrunner handler for `scripts/bench.escript --scenarios httparena_json`.

Mirrors HttpArena's `json` profile: `GET /httparena_json/:count?m=M`
returns a JSON list of `count` items, each projected with
`total = price * quantity * M`. The 50-item dataset is precomputed
at module load and stashed in `persistent_term` so the bench
measures dispatch + projection + JSON encode, not dataset
construction.

Dataset shape (id, name, category, price, quantity, active, tags,
rating) mirrors HttpArena's `data/dataset.json`. The canonical
bench-fixture response (count=50, m=1) is also precomputed and
exposed via `bench_body/0` so the loadgen knows the exact response
size to expect.
""".

-behaviour(roadrunner_handler).

-on_load(init_dataset/0).

-export([handle/1]).
-export([bench_body/0]).

-define(DATASET_KEY, {?MODULE, dataset}).
-define(BENCH_BODY_KEY, {?MODULE, bench_body}).
-define(DATASET_SIZE, 50).
-define(BENCH_COUNT, 50).
-define(BENCH_MULTIPLIER, 1).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    Count = binding_int(~"count", Req, 0),
    M = qs_int(~"m", Req, 1),
    Body = encode(Count, M),
    Resp =
        {200,
            [
                {~"content-type", ~"application/json"},
                {~"content-length", integer_to_binary(byte_size(Body))}
            ],
            Body},
    {Resp, Req}.

-spec bench_body() -> binary().
bench_body() ->
    persistent_term:get(?BENCH_BODY_KEY).

encode(Count, M) ->
    Items = lists:sublist(persistent_term:get(?DATASET_KEY), max(0, Count)),
    Projected = [project(I, M) || I <- Items],
    iolist_to_binary(
        json:encode(#{
            ~"count" => length(Projected),
            ~"items" => Projected
        })
    ).

project(#{~"price" := P, ~"quantity" := Q} = Item, M) ->
    Item#{~"total" => P * Q * M}.

binding_int(Key, Req, Default) ->
    case roadrunner_req:bindings(Req) of
        #{Key := V} when is_binary(V) -> bin_int(V, Default);
        _ -> Default
    end.

qs_int(Key, Req, Default) ->
    case lists:keyfind(Key, 1, roadrunner_req:parse_qs(Req)) of
        {Key, V} when is_binary(V) -> bin_int(V, Default);
        _ -> Default
    end.

bin_int(<<>>, Default) ->
    Default;
bin_int(Bin, Default) ->
    case string:to_integer(Bin) of
        {N, _} when is_integer(N) -> N;
        _ -> Default
    end.

-spec init_dataset() -> ok.
init_dataset() ->
    persistent_term:put(?DATASET_KEY, build_dataset(?DATASET_SIZE)),
    persistent_term:put(?BENCH_BODY_KEY, encode(?BENCH_COUNT, ?BENCH_MULTIPLIER)),
    ok.

build_dataset(Size) ->
    Categories = [~"electronics", ~"tools", ~"home", ~"outdoor", ~"office"],
    TagPool = [~"sale", ~"new", ~"popular", ~"fast", ~"heavy-duty", ~"wireless"],
    [build_item(N, Categories, TagPool) || N <- lists:seq(1, Size)].

build_item(N, Categories, TagPool) ->
    #{
        ~"id" => N,
        ~"name" => <<"Item-", (integer_to_binary(N))/binary>>,
        ~"category" => lists:nth(((N - 1) rem length(Categories)) + 1, Categories),
        ~"price" => 100 + (N * 7) rem 900,
        ~"quantity" => 1 + (N * 3) rem 100,
        ~"active" => (N rem 2) =:= 0,
        ~"tags" => pick_tags(N, TagPool),
        ~"rating" => #{
            ~"score" => 30 + (N rem 70),
            ~"count" => 1 + (N * 5) rem 200
        }
    }.

pick_tags(N, TagPool) ->
    Count = 2 + (N rem 3),
    [lists:nth(((N + I - 1) rem length(TagPool)) + 1, TagPool) || I <- lists:seq(1, Count)].
