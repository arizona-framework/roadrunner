-module(roadrunner).
-moduledoc """
Public API for the roadrunner HTTP server.

Listeners are supervised by `roadrunner_sup`: starting a listener adds a
`roadrunner_listener` child, stopping one terminates and forgets it. The
roadrunner application must be running (typically via
`application:ensure_all_started(roadrunner)`).
""".

-export([start_listener/2, stop_listener/1, listeners/0]).
-export([acknowledge_drain/1, acknowledge_drain/2]).

-doc """
Start a listener as a supervised child of the roadrunner application.

`Name` becomes the listener's registered atom; pass the same name to
`stop_listener/1` later. Returns `{ok, Pid}` on success or `{error, _}`
if a child with the same name already exists or the listen socket
cannot be opened.
""".
-spec start_listener(Name :: atom(), roadrunner_listener:opts()) ->
    {ok, pid()} | {error, term()}.
start_listener(Name, Opts) when is_atom(Name), is_map(Opts) ->
    ChildSpec = #{
        id => Name,
        start => {roadrunner_listener, start_link, [Name, Opts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [roadrunner_listener]
    },
    case supervisor:start_child(roadrunner_sup, ChildSpec) of
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
    case supervisor:terminate_child(roadrunner_sup, Name) of
        ok ->
            ok = supervisor:delete_child(roadrunner_sup, Name);
        {error, not_found} ->
            {error, not_found}
    end.

-doc """
Return the list of currently registered listener names.

Order matches `supervisor:which_children/1` — typically reverse
start-order. The roadrunner application must be running.
""".
-spec listeners() -> [atom()].
listeners() ->
    [
        Name
     || {Name, _Pid, _Type, Mods} <- supervisor:which_children(roadrunner_sup),
        Mods =:= [roadrunner_listener]
    ].

-doc """
Emit `[roadrunner, drain, acknowledged]` for the current request, signalling
to subscribers that a long-running handler (`{loop, ...}` or WebSocket)
has observed and is honoring an in-flight `roadrunner_listener:drain/2`
broadcast. Handlers should call this from their `handle_info/3` (loop)
or `handle_frame/2` (websocket) when they pattern-match on
`{roadrunner_drain, _}` and decide to wind down.

`Req` is the request map the handler received. Returns `ok`. Calling
this when no drain is in flight is harmless — subscribers see a stray
event and ignore it — but the documented usage is post-drain-receipt.

For SREs computing "how much grace did the handler use," see
`acknowledge_drain/2` which threads the `Deadline` from the
`{roadrunner_drain, Deadline}` message into the event metadata.
""".
-spec acknowledge_drain(roadrunner_http1:request()) -> ok.
acknowledge_drain(Req) when is_map(Req) ->
    roadrunner_telemetry:drain_acknowledged(drain_metadata(Req, undefined)).

-doc """
Same as `acknowledge_drain/1` but threads the drain `Deadline`
(in milliseconds, the second element of the `{roadrunner_drain, Deadline}`
message a handler received) into the telemetry metadata so subscribers
can compute `Deadline - erlang:monotonic_time(millisecond)` for the
remaining grace period.
""".
-spec acknowledge_drain(roadrunner_http1:request(), integer()) -> ok.
acknowledge_drain(Req, Deadline) when is_map(Req), is_integer(Deadline) ->
    roadrunner_telemetry:drain_acknowledged(drain_metadata(Req, Deadline)).

-spec drain_metadata(roadrunner_http1:request(), integer() | undefined) -> map().
drain_metadata(Req, Deadline) ->
    #{
        listener_name => maps:get(listener_name, Req, undefined),
        peer => maps:get(peer, Req, undefined),
        request_id => maps:get(request_id, Req, undefined),
        deadline => Deadline
    }.
