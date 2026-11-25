-module(roadrunner_route_binary_handler).
-moduledoc """
Test fixture: a handler that builds a 512 KB binary, as one reading a big
file does, and answers with the pid it ran in (`pid_to_list/1`), so a
test can look at the binaries that process holds once the response is
out. The binary is garbage once the handler returns.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    Read = binary:copy(~"x", 524288),
    Body = list_to_binary(pid_to_list(self())),
    524288 = byte_size(Read),
    {{200, [], Body}, Req}.
