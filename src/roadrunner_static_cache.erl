-module(roadrunner_static_cache).
-moduledoc false.

%% Owner and API for the node-global static-file metadata cache.
%%
%% `roadrunner_static` caches each served file's `{Size, Mtime, Expiry}`
%% (opt-in via the `cache_ttl_ms` route option) so hot paths skip the
%% per-request `read_link_info` syscall. This module owns the backing
%% store and exposes `lookup/1` / `store/4` / `clear/0`; callers never
%% see the representation.
%%
%% The store is a public named ETS table, so `lookup`/`store`/`clear`
%% run in the CALLER process (no message round-trip): reads and writes
%% stay cheap and concurrent off the request path, which a single owner
%% process serializing every write could not provide. This process
%% exists only to create and own the table; it dies cleanly on
%% shutdown, taking the table with it.

-behaviour(gen_server).

-export([start_link/0, lookup/1, store/7, clear/0]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(TABLE, roadrunner_static_meta).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Read the cached metadata for FilePath if it is still within its TTL.
%% An infinity entry is always a hit; an expired entry is dropped (cheap
%% in ETS) and reported as a miss. The cached value carries the derived
%% ETag + Last-Modified strings and the gzip-sibling result, so a hit
%% skips recomputing them and skips the per-request `<file>.gz` stat.
-spec lookup(file:filename_all()) ->
    {ok, non_neg_integer(), integer(), binary(), binary(), {gz, non_neg_integer()} | nogz} | miss.
lookup(FilePath) ->
    case ets:lookup(?TABLE, FilePath) of
        [] ->
            miss;
        [{_, {Size, Mtime, ETag, LastMod, GzInfo, infinity}}] ->
            {ok, Size, Mtime, ETag, LastMod, GzInfo};
        [{_, {Size, Mtime, ETag, LastMod, GzInfo, ExpiresAt}}] ->
            case erlang:monotonic_time(millisecond) of
                Now when Now =< ExpiresAt ->
                    {ok, Size, Mtime, ETag, LastMod, GzInfo};
                _ ->
                    true = ets:delete(?TABLE, FilePath),
                    miss
            end
    end.

%% Store the size, mtime, derived ETag + Last-Modified strings, and the
%% gzip-sibling result (`{gz, GzSize}` when a `<file>.gz` is on disk,
%% `nogz` otherwise) for FilePath with a TTL of TtlMs ms from now, or
%% forever when TtlMs is infinity. Concurrent stores for the same path
%% are last-writer-wins (each insert is atomic per key).
-spec store(
    file:filename_all(),
    non_neg_integer(),
    integer(),
    binary(),
    binary(),
    {gz, non_neg_integer()} | nogz,
    pos_integer() | infinity
) -> ok.
store(FilePath, Size, Mtime, ETag, LastMod, GzInfo, infinity) ->
    true = ets:insert(?TABLE, {FilePath, {Size, Mtime, ETag, LastMod, GzInfo, infinity}}),
    ok;
store(FilePath, Size, Mtime, ETag, LastMod, GzInfo, TtlMs) when is_integer(TtlMs), TtlMs > 0 ->
    ExpiresAt = erlang:monotonic_time(millisecond) + TtlMs,
    true = ets:insert(?TABLE, {FilePath, {Size, Mtime, ETag, LastMod, GzInfo, ExpiresAt}}),
    ok.

%% Drop every cached entry in one call.
-spec clear() -> ok.
clear() ->
    true = ets:delete_all_objects(?TABLE),
    ok.

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
