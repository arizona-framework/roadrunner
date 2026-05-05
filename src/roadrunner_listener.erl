-module(roadrunner_listener).
-moduledoc """
Listener gen_server — owns the listening socket and the acceptor pool
for one named roadrunner instance.

Plain TCP is backed by `gen_tcp` with the legacy `inet_drv` backend.
The OTP-27 `{inet_backend, socket}` NIF path was tried but adds ~46%
own-time overhead on short-lived connections via per-socket-option
lookups (see `docs/conn_lifecycle_investigation.md`). TLS is backed
by `ssl`, gated by the `tls` opt.
Both paths share the same `roadrunner_transport` tagged-socket abstraction.

On `init/1` the listener opens the listen socket, builds the shared
`roadrunner_conn:proto_opts()` (dispatch + body limits + timeouts +
`max_clients` counter), and spawn-links `num_acceptors` (default 10)
`roadrunner_acceptor` processes that pull from the same listen socket.
Connection workers are unlinked from the acceptor so a single
connection crash doesn't take the pool down.
""".

-behaviour(gen_server).

-export([start_link/2, stop/1, drain/2, port/1, info/1, status/1, reload_routes/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([opts/0]).

-define(DEFAULT_MAX_CONTENT_LENGTH, 10485760).
-define(DEFAULT_REQUEST_TIMEOUT, 30000).
-define(DEFAULT_KEEP_ALIVE_TIMEOUT, 60000).
-define(DEFAULT_NUM_ACCEPTORS, 10).
-define(DEFAULT_MAX_KEEP_ALIVE, 1000).
-define(DEFAULT_MAX_CLIENTS, 150).
-define(DEFAULT_MIN_BYTES_PER_SECOND, 100).

-type opts() :: #{
    port := inet:port_number(),
    handler => module(),
    routes => roadrunner_router:routes(),
    middlewares => roadrunner_middleware:middleware_list(),
    max_content_length => non_neg_integer(),
    request_timeout => non_neg_integer(),
    keep_alive_timeout => non_neg_integer(),
    num_acceptors => pos_integer(),
    max_keep_alive_request => pos_integer(),
    max_clients => pos_integer(),
    minimum_bytes_per_second => non_neg_integer(),
    %% How often (ms) `reading_request` re-checks the running
    %% bytes-per-second average against `minimum_bytes_per_second`.
    %% Default 1000ms — matches the 1-second grace period of the
    %% rate check itself. Tests use shorter intervals (20–30ms) to
    %% exercise rate-check fires deterministically without
    %% second-scale waits; ops can tune for chattier observability.
    rate_check_interval_ms => pos_integer(),
    body_buffering => auto | manual,
    slot_reconciliation => disabled | #{interval_ms := pos_integer()},
    %% Opt out of the per-conn `pg` drain group. Default `enabled`
    %% (current behavior). Set to `disabled` for short-lived
    %% h1-only workloads (REST APIs, health-check probes, CLI
    %% clients) where conns finish on their own faster than any
    %% drain notification could fire. Trades graceful drain
    %% notification for ~10% lower per-conn overhead. Long-lived
    %% conns (loop handlers, SSE, WebSocket) still rely on this
    %% — keep `enabled` if your handlers have those.
    drain_group => enabled | disabled,
    %% When set, the per-connection process auto-hibernates after
    %% `Ms` milliseconds of idle main-loop time. Most useful for
    %% long-lived keep-alive HTTP/1.1 connections that mostly sit
    %% idle between requests — drops process heap to ~1KB during
    %% the wait. Setting this routes `roadrunner_conn_loop`'s recv
    %% through the active-mode `recv_with_hibernate/3` path so the
    %% receive's `after` clause has a window to call
    %% `erlang:hibernate/3`.
    hibernate_after => pos_integer(),
    tls => [ssl:tls_server_option()],
    %% When `true` AND `tls` is set, the listener advertises `h2` ahead
    %% of `http/1.1` in `alpn_preferred_protocols`; clients that
    %% negotiate `h2` are dispatched to `roadrunner_conn_loop_http2`
    %% instead of the HTTP/1.1 path. Default `false`. User-supplied
    %% `alpn_preferred_protocols` in `tls` opts win — set this opt only
    %% if you want roadrunner to manage the ALPN list automatically.
    http2_enabled => boolean()
}.

-record(state, {
    listen_socket :: roadrunner_transport:socket() | closed,
    port :: inet:port_number(),
    proto_opts :: roadrunner_conn:proto_opts(),
    phase = accepting :: accepting | draining | stopped,
    %% Slot reconciliation (off by default). When enabled, a periodic
    %% timer compares `client_counter` against pg group membership and
    %% releases slots that have been orphaned by `kill`-style exits
    %% (which bypass `terminate/3`). `prev_diff` tracks the previous
    %% tick's diff to filter out spawn-time races (a freshly-started
    %% conn has bumped the counter but not yet pg:join'd) — only
    %% sustained diffs are reaped.
    reconciliation = disabled ::
        disabled
        | #{
            interval_ms := pos_integer(),
            prev_diff := non_neg_integer()
        }
}).

-doc """
Start a named listener that binds the given TCP port.

`port => 0` lets the kernel choose an ephemeral port — query it back
with `port/1`.
""".
-spec start_link(Name :: atom(), opts()) -> {ok, pid()} | {error, term()}.
start_link(Name, Opts) when is_atom(Name), is_map(Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, Opts, []).

-doc "Stop a listener and release its port. In-flight conns are not waited on.".
-spec stop(Name :: atom()) -> ok.
stop(Name) ->
    gen_server:stop(Name).

-doc """
Graceful shutdown. Closes the listen socket immediately so no new
connections are accepted, broadcasts `{roadrunner_drain, Deadline}` to
every active conn (so `{loop, ...}` handlers can opt to honor it),
and then polls the live-connection counter until it hits zero or
`Timeout` milliseconds elapse. Conns still alive at the deadline are
hard-killed via `exit(Pid, shutdown)`.

Returns `{ok, drained}` when the counter reached zero before the
deadline, or `{timeout, Remaining}` with the count that was still
alive when the timeout fired (those processes are torn down before
returning).

After `drain/2` returns the listener exits — call `start_link/2`
again to bring it back up.
""".
-spec drain(Name :: atom(), Timeout :: non_neg_integer()) ->
    {ok, drained} | {timeout, non_neg_integer()}.
drain(Name, Timeout) ->
    gen_server:call(Name, {drain, Timeout}, Timeout + 5000).

-doc "Return the actual TCP port the listener is bound to.".
-spec port(Name :: atom()) -> inet:port_number().
port(Name) ->
    gen_server:call(Name, port).

-doc """
Return runtime introspection for a listener:

- `active_clients` — current number of connections held open.
- `max_clients` — the configured cap.
- `requests_served` — cumulative count of requests whose headers
  parsed successfully since the listener started. Includes 4xx
  responses from the router (404) and the body-size pre-check (413);
  excludes wire-level parse failures, idle keep-alive timeouts, and
  silent slow-client closes.

Useful for ops dashboards / health endpoints.
""".
-spec info(Name :: atom()) ->
    #{
        active_clients := non_neg_integer(),
        max_clients := pos_integer(),
        requests_served := non_neg_integer()
    }.
info(Name) ->
    gen_server:call(Name, info).

-doc """
Return the listener's lifecycle phase:

- `accepting` — normal serving; new connections are being accepted.
- `draining` — `drain/2` is in progress; the listen socket is
  closed and active conns are finishing.

After `drain/2` (or `stop/1`) returns the listener has exited and
this call would fail with a `noproc`.
""".
-spec status(Name :: atom()) -> accepting | draining.
status(Name) ->
    gen_server:call(Name, status).

-doc """
Atomically swap the listener's compiled route table without
restarting it. The new `Routes` are compiled via
`roadrunner_router:compile/1` and published to `persistent_term`;
in-flight conns keep using whatever they read at request-resolve
time, but every subsequent dispatch sees the new table.

Returns `ok` on success or `{error, no_routes}` if the listener was
started without a `routes` opt (single-handler dispatch — there's
nothing to reload).
""".
-spec reload_routes(Name :: atom(), roadrunner_router:routes()) ->
    ok | {error, no_routes}.
reload_routes(Name, Routes) ->
    gen_server:call(Name, {reload_routes, Routes}).

%% --- gen_server callbacks ---

-spec init(opts()) -> {ok, #state{}} | {stop, term()}.
init(#{port := Port} = Opts) ->
    ListenerName = listener_name(),
    publish_routes(ListenerName, Opts),
    ProtoOpts = build_proto_opts(Opts, ListenerName),
    proc_lib:set_label({roadrunner_listener, ListenerName, Port}),
    case open_listen_socket(Port, Opts) of
        {ok, LSocket} ->
            {ok, BoundPort} = roadrunner_transport:port(LSocket),
            NumAcceptors = maps:get(num_acceptors, Opts, ?DEFAULT_NUM_ACCEPTORS),
            ok = spawn_acceptors(LSocket, ProtoOpts, NumAcceptors),
            Reconciliation = setup_reconciliation(Opts),
            {ok, #state{
                listen_socket = LSocket,
                port = BoundPort,
                proto_opts = ProtoOpts,
                reconciliation = Reconciliation
            }};
        {error, Reason} ->
            {stop, {listen_failed, Reason}}
    end.

-spec setup_reconciliation(opts()) ->
    disabled | #{interval_ms := pos_integer(), prev_diff := non_neg_integer()}.
setup_reconciliation(#{slot_reconciliation := #{interval_ms := IntervalMs}}) when
    is_integer(IntervalMs), IntervalMs > 0
->
    erlang:send_after(IntervalMs, self(), reconcile_slots),
    #{interval_ms => IntervalMs, prev_diff => 0};
setup_reconciliation(_Opts) ->
    disabled.

%% Compile + publish to `persistent_term` once, at listener start. The
%% conn reads via `persistent_term:get/1` on every request, so the
%% lookup is O(1) and the table is shared across all conns of this
%% listener without copying.
-spec publish_routes(atom(), opts()) -> ok.
publish_routes(ListenerName, #{routes := Routes}) ->
    persistent_term:put({roadrunner_routes, ListenerName}, roadrunner_router:compile(Routes));
publish_routes(_ListenerName, _Opts) ->
    ok.

%% Recover the registered name we were started with. `start_link/2` always
%% calls `gen_server:start_link({local, Name}, ...)` so the name is set
%% before `init/1` runs.
-spec listener_name() -> atom().
listener_name() ->
    {registered_name, Name} = process_info(self(), registered_name),
    Name.

-spec open_listen_socket(inet:port_number(), opts()) ->
    {ok, roadrunner_transport:socket()} | {error, term()}.
open_listen_socket(Port, #{tls := UserTlsOpts0} = Opts) ->
    %% TLS path — caller supplies cert/key; we merge `roadrunner_transport`'s
    %% hardened defaults underneath (user values win) and layer the
    %% standard transport options on top so accepted sockets behave like
    %% the plain-TCP variant.
    UserTlsOpts = inject_http2_alpn(UserTlsOpts0, Opts),
    TlsOpts = roadrunner_transport:apply_tls_defaults(UserTlsOpts),
    roadrunner_transport:listen_tls(Port, TlsOpts ++ base_listen_opts());
open_listen_socket(Port, _Opts) ->
    %% Plain TCP. The legacy `inet_drv` backend (gen_tcp default) has
    %% lower per-call overhead than the OTP-27 `socket` backend on
    %% short-lived connections. fprof on `connection_storm` shows the
    %% `socket` backend's `prim_socket:is_supported_option` + the
    %% `maps:fold_1` walking it costs ~46% of per-conn own time
    %% (~106 lookups per connection). See
    %% `docs/conn_lifecycle_investigation.md`. The new backend's
    %% async I/O wins are real for long-lived connections; revisit
    %% if/when the workload mix shifts there.
    roadrunner_transport:listen(Port, base_listen_opts()).

-spec base_listen_opts() -> [gen_tcp:listen_option()].
base_listen_opts() ->
    %% `nodelay` disables Nagle's algorithm on accepted sockets.
    %% RFC 9113 §5.2 doesn't mandate it, but every production h2
    %% server (nginx, h2o, cowboy, …) sets it because h2 responses
    %% emit multiple small frames per request (HEADERS + DATA),
    %% and Nagle holds the second write until the client ACKs the
    %% first — hitting Linux's 40 ms delayed-ACK timer and
    %% capping per-request latency at ~50 ms. h1 isn't affected
    %% (one `ssl:send/2` per response) but `nodelay` is the right
    %% default for any HTTP server. See
    %% `docs/h2_loadgen_artifact.md` for the original investigation.
    %%
    %% `backlog` overrides OTP's default of 5. With 5, a burst of
    %% concurrent connects (real apps, load tests, health-check
    %% storms) overflows the kernel listen queue and the new SYNs
    %% get dropped — `gen_tcp:connect` succeeds (kernel SYN-cookie
    %% path), then the first `send` returns `{error, closed}`
    %% because the conn was never queued for `accept`. Cowboy
    %% defaults to 1024; matching that. Linux clamps at
    %% `net.core.somaxconn` (typically 4096), so this is safely
    %% non-truncated everywhere.
    [
        binary,
        {active, false},
        {reuseaddr, true},
        {packet, raw},
        {nodelay, true},
        {backlog, 1024}
    ].

%% When `http2_enabled => true` and the user didn't supply their own
%% `alpn_preferred_protocols`, advertise `h2` ahead of `http/1.1`.
%% User-supplied ALPN list always wins.
-spec inject_http2_alpn([ssl:tls_server_option()], opts()) -> [ssl:tls_server_option()].
inject_http2_alpn(UserTlsOpts, #{http2_enabled := true}) ->
    case lists:keymember(alpn_preferred_protocols, 1, UserTlsOpts) of
        true -> UserTlsOpts;
        false -> [{alpn_preferred_protocols, [~"h2", ~"http/1.1"]} | UserTlsOpts]
    end;
inject_http2_alpn(UserTlsOpts, _Opts) ->
    UserTlsOpts.

%% Multiple acceptor processes all calling gen_tcp:accept on the same listen
%% socket — Linux/BSD accept is thread-safe and avoids thundering-herd via
%% kernel-side queueing.
-spec spawn_acceptors(roadrunner_transport:socket(), roadrunner_conn:proto_opts(), pos_integer()) ->
    ok.
spawn_acceptors(LSocket, ProtoOpts, N) ->
    lists:foreach(
        fun(I) ->
            {ok, _Pid} = roadrunner_acceptor:start_link(LSocket, ProtoOpts, I)
        end,
        lists:seq(1, N)
    ).

-spec build_proto_opts(opts(), atom()) -> roadrunner_conn:proto_opts().
build_proto_opts(Opts, ListenerName) ->
    %% Per-listener atomics: live-connection counter (acceptors bump on
    %% accept; conns decrement on exit) and a cumulative requests-served
    %% counter (conn bumps on each handler dispatch). Lock-free, ~1ns
    %% per op — cheap enough on the hot path.
    ClientCounter = atomics:new(1, [{signed, false}]),
    RequestsCounter = atomics:new(1, [{signed, false}]),
    Base = #{
        dispatch => build_dispatch(Opts, ListenerName),
        middlewares => maps:get(middlewares, Opts, []),
        max_content_length => maps:get(max_content_length, Opts, ?DEFAULT_MAX_CONTENT_LENGTH),
        request_timeout => maps:get(request_timeout, Opts, ?DEFAULT_REQUEST_TIMEOUT),
        keep_alive_timeout => maps:get(keep_alive_timeout, Opts, ?DEFAULT_KEEP_ALIVE_TIMEOUT),
        max_keep_alive_request =>
            maps:get(max_keep_alive_request, Opts, ?DEFAULT_MAX_KEEP_ALIVE),
        max_clients => maps:get(max_clients, Opts, ?DEFAULT_MAX_CLIENTS),
        client_counter => ClientCounter,
        requests_counter => RequestsCounter,
        minimum_bytes_per_second =>
            maps:get(minimum_bytes_per_second, Opts, ?DEFAULT_MIN_BYTES_PER_SECOND),
        body_buffering => maps:get(body_buffering, Opts, auto),
        listener_name => ListenerName,
        drain_group => maps:get(drain_group, Opts, enabled),
        http2_enabled => maps:get(http2_enabled, Opts, false)
    },
    WithHibernate =
        %% Optional `hibernate_after` — `roadrunner_conn_loop` reads it
        %% from proto_opts and routes the recv path through
        %% `recv_with_hibernate/3` so the conn auto-hibernates after
        %% Ms of idle time. Omitted by default because hibernation has
        %% a per-wake CPU cost (~tens of microseconds for the GC); only
        %% worth enabling for workloads with mostly-idle keep-alive
        %% conns where the heap-shrink win dominates.
        case Opts of
            #{hibernate_after := Ms} when is_integer(Ms), Ms > 0 ->
                Base#{hibernate_after => Ms};
            #{} ->
                Base
        end,
    %% Optional `rate_check_interval_ms` — the rate-check timer
    %% interval inside `reading_request`. Default 1000ms; ops can
    %% override.
    case Opts of
        #{rate_check_interval_ms := IntervalMs} when is_integer(IntervalMs), IntervalMs > 0 ->
            WithHibernate#{rate_check_interval_ms => IntervalMs};
        #{} ->
            WithHibernate
    end.

%% `routes` (router-based dispatch) takes precedence over `handler`. With
%% neither, fall back to the default hello-world handler. Routes are
%% published to `persistent_term` by `publish_routes/2` — the dispatch
%% tag carries the listener name so the conn can look the table up.
-spec build_dispatch(opts(), atom()) -> roadrunner_conn:dispatch().
build_dispatch(#{routes := _}, ListenerName) ->
    {router, ListenerName};
build_dispatch(Opts, _ListenerName) ->
    {handler, maps:get(handler, Opts, roadrunner_hello_handler)}.

-spec handle_call(
    port
    | info
    | status
    | {drain, non_neg_integer()}
    | {reload_routes, roadrunner_router:routes()},
    gen_server:from(),
    #state{}
) -> {reply, term(), #state{}} | {stop, normal, term(), #state{}}.
handle_call(port, _From, #state{port = Port} = State) ->
    {reply, Port, State};
handle_call(status, _From, #state{phase = Phase} = State) ->
    {reply, Phase, State};
handle_call({drain, Timeout}, _From, State) ->
    {Reply, NewState} = do_drain(State, Timeout),
    {stop, normal, Reply, NewState};
handle_call({reload_routes, Routes}, _From, State) ->
    Reply = do_reload_routes(State, Routes),
    {reply, Reply, State};
handle_call(info, _From, #state{proto_opts = ProtoOpts} = State) ->
    #{
        client_counter := ClientCounter,
        requests_counter := RequestsCounter,
        max_clients := MaxClients
    } = ProtoOpts,
    Reply = #{
        active_clients => atomics:get(ClientCounter, 1),
        max_clients => MaxClients,
        requests_served => atomics:get(RequestsCounter, 1)
    },
    {reply, Reply, State}.

-spec do_reload_routes(#state{}, roadrunner_router:routes()) ->
    ok | {error, no_routes}.
do_reload_routes(#state{proto_opts = #{dispatch := {router, Name}}}, Routes) ->
    persistent_term:put({roadrunner_routes, Name}, roadrunner_router:compile(Routes)),
    ok;
do_reload_routes(#state{proto_opts = #{dispatch := {handler, _}}}, _Routes) ->
    {error, no_routes}.

-spec do_drain(#state{}, non_neg_integer()) ->
    {{ok, drained} | {timeout, non_neg_integer()}, #state{}}.
do_drain(#state{listen_socket = LSocket, proto_opts = ProtoOpts} = State, Timeout) ->
    %% Close listen socket — accept fails, acceptors exit cleanly.
    ok = roadrunner_transport:close(LSocket),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    Group = drain_group(ProtoOpts),
    notify_conns(Group, Deadline),
    DrainingState = State#state{listen_socket = closed, phase = draining},
    Counter = maps:get(client_counter, ProtoOpts),
    Reply = wait_for_drain(Counter, Deadline, Group),
    {Reply, DrainingState#state{phase = stopped}}.

%% Best-effort broadcast to in-flight conns. Loop / SSE / WebSocket
%% handlers can pattern-match on `{roadrunner_drain, Deadline}` in
%% `handle_info/3`; non-loop conns ignore the message and fall through
%% to the mailbox check at the next keep-alive boundary.
-spec notify_conns(term(), integer()) -> ok.
notify_conns(Group, Deadline) ->
    lists:foreach(
        fun(Pid) -> Pid ! {roadrunner_drain, Deadline} end,
        pg:get_members(Group)
    ).

%% Poll the active-clients atomics counter every 50ms (or whatever
%% remains, if smaller) until it hits zero or the deadline expires.
-spec wait_for_drain(atomics:atomics_ref(), integer(), term()) ->
    {ok, drained} | {timeout, non_neg_integer()}.
wait_for_drain(Counter, Deadline, Group) ->
    case atomics:get(Counter, 1) of
        0 ->
            {ok, drained};
        N ->
            Remaining = Deadline - erlang:monotonic_time(millisecond),
            case Remaining =< 0 of
                true ->
                    lists:foreach(
                        fun(Pid) -> exit(Pid, shutdown) end,
                        pg:get_members(Group)
                    ),
                    {timeout, N};
                false ->
                    timer:sleep(min(50, Remaining)),
                    wait_for_drain(Counter, Deadline, Group)
            end
    end.

-spec drain_group(roadrunner_conn:proto_opts()) -> {roadrunner_drain, atom()}.
drain_group(#{listener_name := Name}) ->
    {roadrunner_drain, Name}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(reconcile_slots, #state{reconciliation = disabled} = State) ->
    %% Race: a `slot_reconciliation` opt change between scheduling and
    %% receipt would surface as the timer firing in disabled state.
    %% Just drop it; the new config is the source of truth.
    {noreply, State};
handle_info(
    reconcile_slots,
    #state{
        proto_opts = #{client_counter := Counter, listener_name := Name},
        reconciliation = #{interval_ms := Interval, prev_diff := PrevDiff}
    } = State
) ->
    %% pg is supervised by roadrunner_sup so it's always up when the
    %% reconciler runs (which only fires when explicitly opted into).
    %%
    %% We avoid `length/1` on the member list because `max_clients`
    %% can be configured into the tens of thousands and a full O(N)
    %% length walk would dominate the tick. We only need to know
    %% whether `length(members) >= counter` (no orphans) or
    %% `length(members) < counter` (orphans = counter - length); a
    %% bounded count short-circuits at the counter so the worst case
    %% is `min(length(members), counter)` element visits.
    Counter0 = atomics:get(Counter, 1),
    PgCountBounded = count_up_to(pg:get_members({roadrunner_drain, Name}), Counter0),
    NewDiff = Counter0 - PgCountBounded,
    %% Only release slots that have been orphaned for two consecutive
    %% ticks — filters out the spawn-time race where a fresh conn has
    %% incremented the counter but hasn't yet pg:join'd.
    Release = min(PrevDiff, NewDiff),
    case Release of
        0 ->
            ok;
        N when N > 0 ->
            _ = atomics:sub(Counter, 1, N),
            logger:notice(#{
                msg => "roadrunner_listener reconciled orphan slots",
                listener_name => Name,
                released => N,
                counter_was => Counter0,
                pg_count_bounded => PgCountBounded
            }),
            ok = roadrunner_telemetry:slots_reconciled(#{
                listener_name => Name,
                released => N,
                counter_was => Counter0
            })
    end,
    erlang:send_after(Interval, self(), reconcile_slots),
    {noreply, State#state{
        reconciliation = #{interval_ms => Interval, prev_diff => NewDiff - Release}
    }};
handle_info(_Msg, State) ->
    {noreply, State}.

%% Count list elements, short-circuiting at `Cap`. Used by the slot
%% reconciler so the worst-case walk per tick is bounded by the
%% `client_counter` (i.e. `max_clients`) rather than the absolute
%% size of the pg member list.
-spec count_up_to([term()], non_neg_integer()) -> non_neg_integer().
count_up_to(List, Cap) ->
    count_up_to(List, Cap, 0).

-spec count_up_to([term()], non_neg_integer(), non_neg_integer()) -> non_neg_integer().
count_up_to(_, Cap, N) when N >= Cap -> Cap;
count_up_to([], _Cap, N) -> N;
count_up_to([_ | T], Cap, N) -> count_up_to(T, Cap, N + 1).

-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{listen_socket = LSocket, proto_opts = ProtoOpts}) ->
    erase_routes(ProtoOpts),
    case LSocket of
        %% `drain/2` already closed the listen socket on its way out.
        closed -> ok;
        _ -> roadrunner_transport:close(LSocket)
    end.

-spec erase_routes(roadrunner_conn:proto_opts()) -> ok.
erase_routes(#{dispatch := {router, Name}}) ->
    _ = persistent_term:erase({roadrunner_routes, Name}),
    ok;
erase_routes(_) ->
    ok.
