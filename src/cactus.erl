-module(cactus).
-moduledoc """
Public API for the cactus HTTP server.

Listeners are supervised by `cactus_sup`: starting a listener adds a
`cactus_listener` child, stopping one terminates and forgets it. The
cactus application must be running (typically via
`application:ensure_all_started(cactus)`).
""".

-export([start_listener/2, stop_listener/1, listeners/0]).
-export([acknowledge_drain/1]).

-doc """
Start a listener as a supervised child of the cactus application.

`Name` becomes the listener's registered atom; pass the same name to
`stop_listener/1` later. Returns `{ok, Pid}` on success or `{error, _}`
if a child with the same name already exists or the listen socket
cannot be opened.
""".
-spec start_listener(Name :: atom(), cactus_listener:opts()) ->
    {ok, pid()} | {error, term()}.
start_listener(Name, Opts) when is_atom(Name), is_map(Opts) ->
    ChildSpec = #{
        id => Name,
        start => {cactus_listener, start_link, [Name, Opts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [cactus_listener]
    },
    case supervisor:start_child(cactus_sup, ChildSpec) of
        {ok, _Pid} = Ok -> Ok;
        {error, _} = Err -> Err
    end.

-doc """
Stop a previously started listener and remove it from the supervision tree.

Returns `ok` on success or `{error, not_found}` if no listener is
registered under `Name`.
""".
-spec stop_listener(Name :: atom()) -> ok | {error, not_found}.
stop_listener(Name) when is_atom(Name) ->
    case supervisor:terminate_child(cactus_sup, Name) of
        ok ->
            ok = supervisor:delete_child(cactus_sup, Name);
        {error, not_found} ->
            {error, not_found}
    end.

-doc """
Return the list of currently registered listener names.

Order matches `supervisor:which_children/1` — typically reverse
start-order. The cactus application must be running.
""".
-spec listeners() -> [atom()].
listeners() ->
    [
        Name
     || {Name, _Pid, _Type, Mods} <- supervisor:which_children(cactus_sup),
        Mods =:= [cactus_listener]
    ].

-doc """
Emit `[cactus, drain, acknowledged]` for the current request, signalling
to subscribers that a long-running handler (`{loop, ...}` or WebSocket)
has observed and is honoring an in-flight `cactus_listener:drain/2`
broadcast. Handlers should call this from their `handle_info/3` (loop)
or `handle_frame/2` (websocket) when they pattern-match on
`{cactus_drain, _}` and decide to wind down.

`Req` is the request map the handler received. Returns `ok`. Calling
this when no drain is in flight is harmless — subscribers see a stray
event and ignore it — but the documented usage is post-drain-receipt.
""".
-spec acknowledge_drain(cactus_http1:request()) -> ok.
acknowledge_drain(Req) when is_map(Req) ->
    cactus_telemetry:drain_acknowledged(#{
        listener_name => maps:get(listener_name, Req, undefined),
        peer => maps:get(peer, Req, undefined),
        request_id => maps:get(request_id, Req, undefined)
    }).
