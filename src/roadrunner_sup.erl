-module(roadrunner_sup).
-moduledoc false.

%% roadrunner top level supervisor.

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    %% Listeners are added dynamically via roadrunner:start_listener/2. The
    %% one static child is the static-file metadata cache table owner.
    %% one_for_one isolates per-listener crashes; the static child only
    %% restarts on its own crash.
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    StaticCache = #{
        id => roadrunner_static_cache,
        start => {roadrunner_static_cache, start_link, []},
        type => worker,
        restart => permanent,
        shutdown => 5000,
        modules => [roadrunner_static_cache]
    },
    {ok, {SupFlags, [StaticCache]}}.

%% internal functions
