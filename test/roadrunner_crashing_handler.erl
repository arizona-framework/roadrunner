-module(roadrunner_crashing_handler).
-moduledoc """
Test fixture — `handle/1` always raises. Used to verify that
`roadrunner_conn:handle_and_send/3` catches handler crashes and replies
with 500 instead of leaving the client hanging.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> no_return().
handle(_Req) ->
    error(boom).
