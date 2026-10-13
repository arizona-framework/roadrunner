-module(roadrunner_body_size_handler).
-moduledoc """
Test fixture: reads the request body (buffered or through the manual reader)
and answers with its size as text, or with `413` and the read error when the
reader refuses it, so a test can see which body cap the request got.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    case roadrunner_req:read_body(Req) of
        {ok, Body, Req2} ->
            {{200, [{~"content-type", ~"text/plain"}], integer_to_binary(iolist_size(Body))}, Req2};
        {error, Reason} ->
            {{413, [{~"content-type", ~"text/plain"}], atom_to_binary(Reason)}, Req}
    end.
