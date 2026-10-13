-module(roadrunner_client_ip_handler).
-moduledoc """
Test fixture: answers with `roadrunner_req:client_ip/1` as text, so a test can
see which address the listener resolved for the request.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    Body =
        case roadrunner_req:client_ip(Req) of
            undefined -> ~"undefined";
            IP -> list_to_binary(inet:ntoa(IP))
        end,
    {roadrunner_resp:text(200, Body), Req}.
