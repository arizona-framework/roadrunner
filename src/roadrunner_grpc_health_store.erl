-module(roadrunner_grpc_health_store).
-moduledoc false.

%% The gRPC health statuses (`roadrunner_grpc_health`): an ETS table any
%% process reads, written through this server so a change and the word to
%% its watchers go together. A watcher (a `Watch` call) is monitored and
%% forgotten when it ends. The server's own status, the empty name, starts
%% `serving`, as gRPC servers do once the health service is up. A restart of
%% this server starts over that way too: the table goes with it.

-behaviour(gen_server).

-export([start_link/0, status/1, statuses/0, set/2, watch/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, roadrunner_grpc_health).

-type status() :: serving | not_serving.

%% The watchers by the service they watch, and back from their monitor.
-record(store, {
    watchers = #{} :: #{binary() => #{reference() => pid()}},
    services = #{} :: #{reference() => binary()}
}).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% A service's status, `unknown` when it has none.
-spec status(binary()) -> status() | unknown.
status(Service) ->
    case ets:lookup(?TABLE, Service) of
        [{_, Status}] -> Status;
        [] -> unknown
    end.

-spec statuses() -> [{binary(), status()}].
statuses() ->
    ets:tab2list(?TABLE).

%% Set a service's status, `unknown` forgetting it, and tell its watchers.
-spec set(binary(), status() | unknown) -> ok.
set(Service, Status) ->
    gen_server:call(?MODULE, {set, Service, Status}).

%% Have the calling process told of each change to the service's status,
%% as `{roadrunner_grpc_health, Service, Status | unknown}`, until it ends;
%% the status now comes back, read with the watch taken, so each change
%% told after is newer.
-spec watch(binary()) -> status() | unknown.
watch(Service) ->
    gen_server:call(?MODULE, {watch, Service, self()}).

-spec init([]) -> {ok, #store{}}.
init([]) ->
    ?TABLE = ets:new(?TABLE, [named_table, protected, set, {read_concurrency, true}]),
    true = ets:insert(?TABLE, {<<>>, serving}),
    {ok, #store{}}.

-spec handle_call(term(), gen_server:from(), #store{}) ->
    {reply, ok | status() | unknown, #store{}}.
handle_call({set, Service, Status}, _From, Store) ->
    true =
        case Status of
            unknown -> ets:delete(?TABLE, Service);
            _ -> ets:insert(?TABLE, {Service, Status})
        end,
    ok = notify(Service, Status, Store),
    {reply, ok, Store};
handle_call({watch, Service, Pid}, _From, #store{watchers = Watchers, services = Services} = Store) ->
    Ref = monitor(process, Pid),
    Of = maps:get(Service, Watchers, #{}),
    {reply, status(Service), Store#store{
        watchers = Watchers#{Service => Of#{Ref => Pid}},
        services = Services#{Ref => Service}
    }}.

-spec handle_cast(term(), State) -> {noreply, State}.
handle_cast(_Msg, State) ->
    {noreply, State}.

%% A watcher's end; anything else sent to the registered name is dropped,
%% not let to crash the statuses away.
-spec handle_info(term(), #store{}) -> {noreply, #store{}}.
handle_info({'DOWN', Ref, process, _Pid, _Reason}, #store{services = Services} = Store) ->
    case Services of
        #{Ref := Service} -> {noreply, forget(Ref, Service, Store)};
        #{} -> {noreply, Store}
    end;
handle_info(_Other, Store) ->
    {noreply, Store}.

-spec forget(reference(), binary(), #store{}) -> #store{}.
forget(Ref, Service, #store{watchers = Watchers, services = Services} = Store) ->
    #{Service := Of} = Watchers,
    Remaining = maps:remove(Ref, Of),
    Watchers1 =
        case map_size(Remaining) of
            0 -> maps:remove(Service, Watchers);
            _ -> Watchers#{Service := Remaining}
        end,
    Store#store{watchers = Watchers1, services = maps:remove(Ref, Services)}.

-spec notify(binary(), status() | unknown, #store{}) -> ok.
notify(Service, Status, #store{watchers = Watchers}) ->
    case Watchers of
        #{Service := Of} ->
            maps:foreach(fun(_Ref, Pid) -> Pid ! {roadrunner_grpc_health, Service, Status} end, Of);
        #{} ->
            ok
    end.
