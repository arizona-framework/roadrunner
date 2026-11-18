-module(roadrunner_h2_slot_handler).
-moduledoc """
Test fixture — announces itself and then holds its in-flight slot until
released, so a second stream has to park behind
`max_concurrent_requests`. Announcing to a registered collector rather
than registering itself lets several run at once. It waits for `release`
with no timeout, so a test decides when each one ends; `stop_all/0`
ends any a failed test left behind.
""".

-behaviour(roadrunner_handler).

-export([handle/1, stop_all/0]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    _ =
        case whereis(roadrunner_h2_slot_collector) of
            undefined -> ok;
            Pid -> Pid ! {handler_started, self()}
        end,
    receive
        release -> ok
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

%% Kill every handler still waiting for its `release`.
-spec stop_all() -> ok.
stop_all() ->
    lists:foreach(
        fun(Pid) ->
            case erlang:process_info(Pid, current_function) of
                {current_function, {?MODULE, handle, 1}} -> exit(Pid, kill);
                _ -> ok
            end
        end,
        erlang:processes()
    ).
