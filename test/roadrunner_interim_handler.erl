-module(roadrunner_interim_handler).
-moduledoc """
Test-fixture `roadrunner_handler` — returns a `103` (interim) status as
its final response, buffered or (by target) as a stream, loop or
sendfile response. A 1xx cannot be a final response (RFC 9110
§15.2), so the conn loop / stream worker rejects it with `500`. Used to
cover that rejection on the h1 dispatch path.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(#{target := ~"/stream"} = Req) ->
    {{stream, 103, [], fun(Send) -> Send(~"never sent", fin) end}, Req};
handle(#{target := ~"/loop"} = Req) ->
    {{loop, 103, [], state}, Req};
handle(#{target := ~"/sendfile"} = Req) ->
    {{sendfile, 103, [], {"/nonexistent", 0, 1}}, Req};
handle(Req) ->
    {{103, [], ~""}, Req}.
