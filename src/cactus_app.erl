%%%-------------------------------------------------------------------
%% @doc cactus public API
%% @end
%%%-------------------------------------------------------------------

-module(cactus_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    cactus_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
