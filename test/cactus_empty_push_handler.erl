-module(cactus_empty_push_handler).
-moduledoc """
Test fixture — `{loop, ...}` handler that registers itself, then
relays Erlang messages: `empty_push` calls Push with empty data,
`{push, X}` pushes a payload, `stop` finishes.
""".

-behaviour(cactus_handler).

-export([handle/1, handle_info/3]).

handle(Req) ->
    true = register(cactus_empty_push_test_conn, self()),
    {{loop, 200, [{~"content-type", ~"text/plain"}], 0}, Req}.

handle_info(empty_push, Push, State) ->
    _ = Push(~""),
    {ok, State};
handle_info({push, Data}, Push, State) ->
    _ = Push(Data),
    {ok, State};
handle_info(stop, _Push, State) ->
    {stop, State}.
