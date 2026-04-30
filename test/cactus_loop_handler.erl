-module(cactus_loop_handler).
-moduledoc """
Test fixture — handler that returns `{loop, ...}` and pushes one
SSE-style chunk per incoming Erlang message. Registers itself under
`cactus_loop_test_conn` so the test can send messages to the conn.
""".

-behaviour(cactus_handler).

-export([handle/1, handle_info/3]).

handle(_Req) ->
    true = register(cactus_loop_test_conn, self()),
    {loop, 200, [{~"content-type", ~"text/event-stream"}], 0}.

handle_info({push, Data}, Push, N) ->
    _ = Push([~"data: ", Data, ~"\n\n"]),
    {ok, N + 1};
handle_info(stop, Push, N) ->
    _ = Push([~"data: bye(", integer_to_binary(N), ~")\n\n"]),
    {stop, N}.
