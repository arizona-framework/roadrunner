-module(roadrunner_route_old_heap_handler).
-moduledoc """
Test fixture: a handler that decodes 10,000 small fields a little at a
time, so under the emulator's generational policy its minor collections
move them to the old heap while the young heap keeps its size, and
answers with the pid it ran in (`pid_to_list/1`). The fields are garbage
once the handler returns.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    Decoded = decode(10000, []),
    Body = list_to_binary(pid_to_list(self())),
    10000 = length(Decoded),
    {{200, [], Body}, Req}.

decode(0, Fields) ->
    Fields;
decode(N, Fields) ->
    decode(N - 1, [{N, integer_to_binary(N)} | Fields]).
