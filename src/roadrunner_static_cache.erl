-module(roadrunner_static_cache).
-moduledoc false.

%% Owner process for the node-global static-file metadata cache table.
%%
%% `roadrunner_static` caches each served file's `{Size, Mtime, Expiry}`
%% (opt-in via the `cache_ttl_ms` route option). The table is a public
%% named ETS table so any connection/worker process can read and write
%% it directly off the request path: reads copy a tiny 3-tuple, writes
%% are process-local and cheap, and expiry can delete the row. This
%% process exists only to create and own the table; it dies cleanly on
%% shutdown, taking the table with it.

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(TABLE, roadrunner_static_meta).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec init([]) -> {ok, undefined}.
init([]) ->
    _ = ets:new(?TABLE, [
        named_table, public, set, {read_concurrency, true}, {write_concurrency, true}
    ]),
    {ok, undefined}.

-spec handle_call(term(), gen_server:from(), State) -> {reply, ok, State}.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(term(), State) -> {noreply, State}.
handle_cast(_Msg, State) ->
    {noreply, State}.
