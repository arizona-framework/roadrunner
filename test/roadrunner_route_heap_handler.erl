-module(roadrunner_route_heap_handler).
-moduledoc """
Test fixture: a handler that builds a large term on its process heap, as
one decoding a big request body does, and answers with the pid it ran in
(`pid_to_list/1`), so a test can look at that process's heap once the
response is out. The term is garbage once the handler returns.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    Decoded = lists:seq(1, 400000),
    Body = list_to_binary(pid_to_list(self())),
    400000 = length(Decoded),
    {{200, [], Body}, Req}.
