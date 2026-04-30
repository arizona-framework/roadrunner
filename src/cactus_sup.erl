%%%-------------------------------------------------------------------
%% @doc cactus top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(cactus_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    %% Listeners are added dynamically via cactus:start_listener/2 — start
    %% with no static children. one_for_one isolates per-listener crashes.
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    {ok, {SupFlags, []}}.

%% internal functions
