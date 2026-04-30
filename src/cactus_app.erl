%%%-------------------------------------------------------------------
%% @doc cactus public API
%% @end
%%%-------------------------------------------------------------------

-module(cactus_app).

-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    case cactus_sup:start_link() of
        {ok, _} = Ok -> Ok;
        {error, _} = Err -> Err
    end.

-spec stop(term()) -> ok.
stop(_State) ->
    ok.

%% internal functions
