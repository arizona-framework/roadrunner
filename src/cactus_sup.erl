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
    %% Listeners are added dynamically via cactus:start_listener/2 — the
    %% only static child is `pg`'s default scope, which `cactus_conn`
    %% joins so `cactus_listener:drain/2` can find conns to notify.
    %% one_for_one isolates per-listener crashes; pg only restarts on
    %% its own crash, which is a true protocol break.
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    PgScope = #{
        id => pg,
        start => {pg, start_link, []},
        type => worker,
        restart => permanent,
        shutdown => 5000,
        modules => [pg]
    },
    {ok, {SupFlags, [PgScope]}}.

%% internal functions
