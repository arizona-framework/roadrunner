-module(roadrunner_quic_listener_sup).
-moduledoc false.

%% A SO_REUSEPORT pool of `roadrunner_quic_listener`s sharing one connection-id
%% registry. This is the drop-in for the dep's `quic_listener_sup`: the seam in
%% `roadrunner_listener` starts it with `start_link/2`, reads a listener back
%% with `get_listeners/1`, and tears it down with `stop/1`.
%%
%% `pool_size + 1` listeners (the `+1` is the primary, matching the dep) all
%% bind the SAME concrete port with `SO_REUSEPORT`, so the kernel fans inbound
%% datagrams across them and demux parallelizes across cores. The caller hands
%% in a concrete port (`roadrunner_listener` pins a free one with a reuseport
%% probe before calling, because binding port 0 on each listener would hand out
%% a different ephemeral port); reuseport is enabled only when there is more
%% than one listener.
%%
%% The shared registry is created here, so it is owned by this supervisor
%% process and OUTLIVES any single listener: a crashed listener is restarted
%% (one_for_one) with the same child spec, i.e. the same table, and a datagram
%% that fans out to a different listener still routes to the owning connection.
%% Each listener registers + monitors only the connections it spawns, so the
%% per-listener cleanup stays correct over the shared table.
%%
%% Connections are owned (and linked) by the `roadrunner_conn_loop_http3` owner
%% the `connection_handler` returns, not by the listeners, so `stop/1` brings
%% the pool (and its sockets/port) down without abruptly killing in-flight
%% connections; those drain through the owner protocol or idle out. The Version
%% Negotiation trigger, anti-amplification, and the handshake all live in the
%% listener and connection; this module is only the pool wiring.

-behaviour(supervisor).

-export([start_link/2, get_listeners/1, stop/1]).
-export([init/1]).
%% Exported for eunit coverage of the pure pool-options translation.
-export([listener_opts/4]).

-export_type([pool_opts/0]).

%% Default transport parameters advertised to clients. Only initial_max_streams_
%% bidi is carried in pool_opts today (from the listener's http3 opts); the rest
%% are fixed defaults pending the flow-control opt wiring. They mirror the conn
%% layer's own limits (the 30s idle matches the connection idle timeout).
-define(DEFAULT_INITIAL_MAX_DATA, 1048576).
-define(DEFAULT_INITIAL_MAX_STREAM_DATA, 262144).
-define(DEFAULT_INITIAL_MAX_STREAMS_UNI, 100).
-define(DEFAULT_MAX_IDLE_TIMEOUT, 30000).

-type pool_opts() :: #{
    cert := binary(),
    key := public_key:private_key(),
    cert_chain := [binary()],
    alpn := [binary(), ...],
    max_streams_bidi := non_neg_integer(),
    connection_handler := fun((pid()) -> {ok, pid()} | {error, term()}),
    pool_size := non_neg_integer()
}.

%% =============================================================================
%% API
%% =============================================================================

-doc """
Start a pool of reuseport listeners on `Port` (a concrete port; the caller
resolves an ephemeral one first). Returns once every listener has bound, so a
bind failure surfaces synchronously as `{error, _}`.
""".
-spec start_link(inet:port_number(), pool_opts()) -> {ok, pid()} | {error, term()}.
start_link(Port, PoolOpts) ->
    supervisor:start_link(?MODULE, {Port, PoolOpts}).

-doc "The pool's listener pids (non-empty for a running pool, any answers get_port/1).".
-spec get_listeners(pid()) -> [pid()].
get_listeners(Sup) ->
    [
        Pid
     || {{listener, _N}, Pid, _Type, _Modules} <- supervisor:which_children(Sup), is_pid(Pid)
    ].

-doc """
Stop the pool, bringing the supervisor down (which terminates every listener,
freeing the shared port). Called by the pool's owner, the process that
`start_link`ed it: this unlinks first so the supervisor's shutdown exit does
not fell the owner, and returns once the supervisor is gone.
""".
-spec stop(pid()) -> ok.
stop(Sup) ->
    Mon = monitor(process, Sup),
    true = unlink(Sup),
    _ = exit(Sup, shutdown),
    receive
        {'DOWN', Mon, process, Sup, _Reason} -> ok
    end.

%% =============================================================================
%% Supervisor
%% =============================================================================

-doc false.
-spec init({inet:port_number(), pool_opts()}) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init({Port, #{pool_size := PoolSize} = PoolOpts}) ->
    %% The shared registry is created (and owned) here so it survives a listener
    %% crash. A restarted listener gets the same child spec, hence the same
    %% table.
    Registry = roadrunner_quic_cid_registry:new(),
    Count = PoolSize + 1,
    ReusePort = Count > 1,
    Specs = [listener_spec(N, Port, PoolOpts, Registry, ReusePort) || N <- lists:seq(1, Count)],
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 5},
    {ok, {SupFlags, Specs}}.

%% =============================================================================
%% Internal
%% =============================================================================

-spec listener_spec(
    pos_integer(),
    inet:port_number(),
    pool_opts(),
    roadrunner_quic_cid_registry:t(),
    boolean()
) -> supervisor:child_spec().
listener_spec(N, Port, PoolOpts, Registry, ReusePort) ->
    #{
        id => {listener, N},
        start =>
            {roadrunner_quic_listener, start_link, [
                listener_opts(Port, PoolOpts, Registry, ReusePort)
            ]},
        type => worker,
        restart => permanent,
        shutdown => 5000,
        modules => [roadrunner_quic_listener]
    }.

-doc false.
-spec listener_opts(
    inet:port_number(), pool_opts(), roadrunner_quic_cid_registry:t(), boolean()
) -> roadrunner_quic_listener:opts().
listener_opts(Port, PoolOpts, Registry, ReusePort) ->
    #{
        cert := Cert,
        key := Key,
        cert_chain := CertChain,
        alpn := [Alpn | _],
        max_streams_bidi := MaxStreamsBidi,
        connection_handler := Handler
    } = PoolOpts,
    #{
        port => Port,
        %% The native listener takes the full chain leaf-first; pool_opts keeps
        %% the leaf and intermediates separate (the dep's split).
        cert_chain => [Cert | CertChain],
        priv_key => Key,
        %% QUIC v1 negotiates a single ALPN; the listener carries the chosen one.
        alpn => Alpn,
        transport_params => transport_params(MaxStreamsBidi),
        connection_handler => Handler,
        reuseport => ReusePort,
        registry => Registry
    }.

-spec transport_params(non_neg_integer()) -> roadrunner_quic_transport_params:params().
transport_params(MaxStreamsBidi) ->
    #{
        initial_max_data => ?DEFAULT_INITIAL_MAX_DATA,
        initial_max_stream_data_bidi_local => ?DEFAULT_INITIAL_MAX_STREAM_DATA,
        initial_max_stream_data_bidi_remote => ?DEFAULT_INITIAL_MAX_STREAM_DATA,
        initial_max_stream_data_uni => ?DEFAULT_INITIAL_MAX_STREAM_DATA,
        initial_max_streams_bidi => MaxStreamsBidi,
        initial_max_streams_uni => ?DEFAULT_INITIAL_MAX_STREAMS_UNI,
        max_idle_timeout => ?DEFAULT_MAX_IDLE_TIMEOUT
    }.
