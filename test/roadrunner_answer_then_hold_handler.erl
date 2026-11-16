-module(roadrunner_answer_then_hold_handler).
-moduledoc """
Test fixture: answers in full, then announces itself to the registered
`roadrunner_h2_slot_collector` and keeps running until released, as a
handler that does more work after its response would.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    {
        {send, [], fun(R) ->
            ok = roadrunner_send:reply(200, [], ~"ok", R),
            roadrunner_h2_slot_collector ! {handler_started, self()},
            receive
                release -> R
            after 5000 -> R
            end
        end},
        Req
    }.
