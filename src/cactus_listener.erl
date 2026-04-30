-module(cactus_listener).
-moduledoc """
TCP listener — owns the listening socket for a named cactus instance.

Backed by `gen_tcp` with `{inet_backend, socket}` so we land on the
NIF-based async I/O path that's been the production-ready default
since OTP 27.

This first slice opens and closes the listen socket. Acceptors and
connection workers will hang off it in subsequent features.
""".

-behaviour(gen_server).

-export([start_link/2, stop/1, port/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-export_type([opts/0]).

-define(DEFAULT_MAX_CONTENT_LENGTH, 10485760).
-define(DEFAULT_REQUEST_TIMEOUT, 30000).

-type opts() :: #{
    port := inet:port_number(),
    handler => module(),
    routes => cactus_router:routes(),
    max_content_length => non_neg_integer(),
    request_timeout => non_neg_integer()
}.

-record(state, {
    listen_socket :: gen_tcp:socket(),
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
    %% `inet_backend` must be the first option per gen_tcp docs.
    case
        gen_tcp:listen(Port, [
            {inet_backend, socket},
            binary,
            {active, false},
            {reuseaddr, true},
            {packet, raw}
        ])
    of
        {ok, LSocket} ->
            {ok, BoundPort} = inet:port(LSocket),
            {ok, _AcceptorPid} = cactus_acceptor:start_link(LSocket, ProtoOpts),
            {ok, #state{listen_socket = LSocket, port = BoundPort, proto_opts = ProtoOpts}};
        {error, Reason} ->
            {stop, {listen_failed, Reason}}
    end.

-spec build_proto_opts(opts()) -> cactus_conn:proto_opts().
build_proto_opts(Opts) ->
    #{
        dispatch => build_dispatch(Opts),
        max_content_length => maps:get(max_content_length, Opts, ?DEFAULT_MAX_CONTENT_LENGTH),
        request_timeout => maps:get(request_timeout, Opts, ?DEFAULT_REQUEST_TIMEOUT)
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
    _ = gen_tcp:close(LSocket),
    ok.
