-module(roadrunner_bench_sse_handler).
-moduledoc """
Roadrunner SSE handler for `scripts/bench.escript --scenario server_sent_events`.

Emits 100 small `tick` events as fast as possible, then a comment
and closes the stream. One bench iteration = one SSE session of
100 events.

Uses the `{loop, _, _, _}` response shape — the `handle_info/3`
callback drives event emission via the `Push` fun.
""".

-behaviour(roadrunner_handler).

-export([handle/1, handle_info/3]).

-define(NUM_EVENTS, 100).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    self() ! {emit, ?NUM_EVENTS},
    Resp =
        {loop, 200,
            [
                {~"content-type", ~"text/event-stream"},
                {~"cache-control", ~"no-cache"}
            ],
            undefined},
    {Resp, Req}.

-spec handle_info(term(), fun(), term()) ->
    {ok, term()} | {stop, term()}.
handle_info({emit, 0}, Push, State) ->
    _ = Push(roadrunner_sse:comment(~"end")),
    {stop, State};
handle_info({emit, N}, Push, State) ->
    _ = Push(roadrunner_sse:event(~"tick", integer_to_binary(N))),
    self() ! {emit, N - 1},
    {ok, State}.
