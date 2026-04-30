%%%-------------------------------------------------------------------
%% @doc cactus public API
%% @end
%%%-------------------------------------------------------------------

-module(cactus_app).

-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> supervisor:startlink_ret().
start(_StartType, _StartArgs) ->
    cactus_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    ok.

%% internal functions
