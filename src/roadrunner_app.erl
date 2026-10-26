-module(roadrunner_app).
-moduledoc false.

-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> supervisor:startlink_ret().
start(_StartType, _StartArgs) ->
    {ok, Handler} = application:get_env(roadrunner, event_handler),
    ok = roadrunner_event:put_handler(Handler),
    roadrunner_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    %% The clock clears its stamp when it terminates; this covers a
    %% supervisor that gave up after the clock was killed, where no
    %% terminate ran.
    roadrunner_clock:clear_stamp().
