-module(roadrunner_interim_handler).
-moduledoc """
Test-fixture `roadrunner_handler` — returns a buffered `103` (interim)
status as its final response. A 1xx cannot be a final response (RFC 9110
§15.2), so the conn loop / stream worker rejects it with `500`. Used to
cover that rejection on the h1 dispatch path.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    {{103, [], ~""}, Req}.
