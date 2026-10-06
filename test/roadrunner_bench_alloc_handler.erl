-module(roadrunner_bench_alloc_handler).
-moduledoc """
Roadrunner handler for `scripts/idle_pool.escript`.

Builds a large transient iolist per request and answers with a
115-byte slice of it. The garbage is the point: the connection
process has to grow a real heap per request, which is what makes a
GC policy measurable, while the wire cost stays small enough that
the response itself is not what is being timed.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

%% ~27 KB of transient iolist per request.
-define(ITEMS, 400).
-define(BODY_LEN, 115).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    Body = binary:part(iolist_to_binary(build(?ITEMS)), 0, ?BODY_LEN),
    Resp =
        {200,
            [
                {~"content-type", ~"application/json"},
                {~"content-length", integer_to_binary(?BODY_LEN)}
            ],
            Body},
    {Resp, Req}.

%% Repeating JSON record shape, built on the way out so the whole
%% list is live at once before it is flattened.
build(0) ->
    [~"{\"id\":0}]"];
build(N) ->
    [
        ~"{\"id\":",
        integer_to_binary(N),
        ~",\"name\":\"item-",
        integer_to_binary(N),
        ~"\",\"status\":\"active\",\"tags\":[\"a\",\"b\",\"c\"]},"
        | build(N - 1)
    ].
