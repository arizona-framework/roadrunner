-module(roadrunner_h2_slot_handler).
-moduledoc """
Test fixture — announces itself and then holds its in-flight slot until
released, so a second stream has to park behind
`max_concurrent_requests`. Announcing to a registered collector rather
than registering itself lets several run at once.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    _ =
        case whereis(roadrunner_h2_slot_collector) of
            undefined -> ok;
            Pid -> Pid ! {handler_started, self()}
        end,
    receive
        release -> ok
    after 5000 -> ok
    end,
    Body = ~"ok",
    Resp =
        {200,
            [
                {~"content-type", ~"text/plain"},
                {~"content-length", integer_to_binary(byte_size(Body))}
            ],
            Body},
    {Resp, Req}.
