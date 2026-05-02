-module(roadrunner_loop_handler).
-moduledoc """
Test fixture — handler that returns `{loop, ...}` and pushes one
SSE-style chunk per incoming Erlang message. Registers itself under
`roadrunner_loop_test_conn` so the test can send messages to the conn.
""".

-behaviour(roadrunner_handler).

-export([handle/1, handle_info/3]).

handle(Req) ->
    true = register(roadrunner_loop_test_conn, self()),
    {{loop, 200, [{~"content-type", ~"text/event-stream"}], 0}, Req}.

handle_info({push, Data}, Push, N) ->
    _ = Push([~"data: ", Data, ~"\n\n"]),
    {ok, N + 1};
handle_info(stop, Push, N) ->
    _ = Push([~"data: bye(", integer_to_binary(N), ~")\n\n"]),
    {stop, N}.
