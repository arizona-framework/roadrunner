-module(cactus_listener).
-moduledoc """
Listener gen_server — owns the listening socket and the acceptor pool
for one named cactus instance.

Plain TCP is backed by `gen_tcp` with `{inet_backend, socket}` so we
land on the NIF-based async I/O path that's been the production-ready
default since OTP 27. TLS is backed by `ssl`, gated by the `tls` opt.
Both paths share the same `cactus_transport` tagged-socket abstraction.

On `init/1` the listener opens the listen socket, builds the shared
`cactus_conn:proto_opts()` (dispatch + body limits + timeouts +
`max_clients` counter), and spawn-links `num_acceptors` (default 10)
`cactus_acceptor` processes that pull from the same listen socket.
Connection workers are unlinked from the acceptor so a single
connection crash doesn't take the pool down.
""".

-behaviour(gen_server).

-export([start_link/2, stop/1, port/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

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
    routes => cactus_router:routes(),
    max_content_length => non_neg_integer(),
    request_timeout => non_neg_integer(),
    keep_alive_timeout => non_neg_integer(),
    num_acceptors => pos_integer(),
    max_keep_alive_request => pos_integer(),
    max_clients => pos_integer(),
    minimum_bytes_per_second => non_neg_integer(),
    tls => [ssl:tls_server_option()]
}.

-record(state, {
    listen_socket :: cactus_transport:socket(),
    port :: inet:port_number(),
    proto_opts :: cactus_conn:proto_opts()
}).

-doc """
Start a named listener that binds the given TCP port.

`port => 0` lets the kernel choose an ephemeral port — query it back
with `port/1`.
""".
-spec start_link(Name :: atom(), opts()) -> {ok, pid()} | {error, term()}.
start_link(Name, Opts) when is_atom(Name), is_map(Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, Opts, []).

-doc "Stop a listener and release its port.".
-spec stop(Name :: atom()) -> ok.
stop(Name) ->
    gen_server:stop(Name).

-doc "Return the actual TCP port the listener is bound to.".
-spec port(Name :: atom()) -> inet:port_number().
port(Name) ->
    gen_server:call(Name, port).

%% --- gen_server callbacks ---

-spec init(opts()) -> {ok, #state{}} | {stop, term()}.
init(#{port := Port} = Opts) ->
    ProtoOpts = build_proto_opts(Opts),
    proc_lib:set_label({cactus_listener, Port}),
    case open_listen_socket(Port, Opts) of
        {ok, LSocket} ->
            {ok, BoundPort} = cactus_transport:port(LSocket),
            NumAcceptors = maps:get(num_acceptors, Opts, ?DEFAULT_NUM_ACCEPTORS),
            ok = spawn_acceptors(LSocket, ProtoOpts, NumAcceptors),
            {ok, #state{listen_socket = LSocket, port = BoundPort, proto_opts = ProtoOpts}};
        {error, Reason} ->
            {stop, {listen_failed, Reason}}
    end.

-spec open_listen_socket(inet:port_number(), opts()) ->
    {ok, cactus_transport:socket()} | {error, term()}.
open_listen_socket(Port, #{tls := TlsOpts}) ->
    %% TLS path — caller is responsible for the cert/key options. We layer
    %% the standard transport options on top so accepted sockets behave
    %% like the plain-TCP variant.
    cactus_transport:listen_tls(Port, TlsOpts ++ base_listen_opts());
open_listen_socket(Port, _Opts) ->
    %% Plain TCP. `inet_backend` must be the first option per gen_tcp docs.
    cactus_transport:listen(Port, [{inet_backend, socket} | base_listen_opts()]).

-spec base_listen_opts() -> [gen_tcp:listen_option()].
base_listen_opts() ->
    [binary, {active, false}, {reuseaddr, true}, {packet, raw}].

%% Multiple acceptor processes all calling gen_tcp:accept on the same listen
%% socket — Linux/BSD accept is thread-safe and avoids thundering-herd via
%% kernel-side queueing.
-spec spawn_acceptors(cactus_transport:socket(), cactus_conn:proto_opts(), pos_integer()) ->
    ok.
spawn_acceptors(LSocket, ProtoOpts, N) ->
    lists:foreach(
        fun(_) ->
            {ok, _Pid} = cactus_acceptor:start_link(LSocket, ProtoOpts)
        end,
        lists:seq(1, N)
    ).

-spec build_proto_opts(opts()) -> cactus_conn:proto_opts().
build_proto_opts(Opts) ->
    %% A single shared atomics counter tracks live connections per listener.
    %% Acceptors bump it before spawning a conn; conns decrement on exit.
    %% Lock-free, ~1ns per op — cheap enough on the accept hot path.
    Counter = atomics:new(1, [{signed, false}]),
    #{
        dispatch => build_dispatch(Opts),
        max_content_length => maps:get(max_content_length, Opts, ?DEFAULT_MAX_CONTENT_LENGTH),
        request_timeout => maps:get(request_timeout, Opts, ?DEFAULT_REQUEST_TIMEOUT),
        keep_alive_timeout => maps:get(keep_alive_timeout, Opts, ?DEFAULT_KEEP_ALIVE_TIMEOUT),
        max_keep_alive_request =>
            maps:get(max_keep_alive_request, Opts, ?DEFAULT_MAX_KEEP_ALIVE),
        max_clients => maps:get(max_clients, Opts, ?DEFAULT_MAX_CLIENTS),
        client_counter => Counter,
        minimum_bytes_per_second =>
            maps:get(minimum_bytes_per_second, Opts, ?DEFAULT_MIN_BYTES_PER_SECOND)
    }.

%% `routes` (router-based dispatch) takes precedence over `handler`. With
%% neither, fall back to the default hello-world handler.
-spec build_dispatch(opts()) -> cactus_conn:dispatch().
build_dispatch(#{routes := Routes}) ->
    {router, cactus_router:compile(Routes)};
build_dispatch(Opts) ->
    {handler, maps:get(handler, Opts, cactus_hello_handler)}.

-spec handle_call(port, gen_server:from(), #state{}) ->
    {reply, inet:port_number(), #state{}}.
handle_call(port, _From, #state{port = Port} = State) ->
    {reply, Port, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{listen_socket = LSocket}) ->
    cactus_transport:close(LSocket).
