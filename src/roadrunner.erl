-module(roadrunner).
-moduledoc """
Public API for the roadrunner HTTP server.

Listeners are supervised by `roadrunner_sup`: starting a listener adds a
`roadrunner_listener` child, stopping one terminates and forgets it. The
roadrunner application must be running (typically via
`application:ensure_all_started(roadrunner)`).

Configure listeners via the `t:roadrunner_listener:opts/0` map; see
that type for the full set of available keys, defaults, and tuning
rationale.
""".

-export([start_listener/2, stop_listener/1, listeners/0]).
-export([acknowledge_drain/1, acknowledge_drain/2]).

-doc """
Start a listener as a supervised child of the roadrunner application.

`Name` becomes the listener's registered atom; pass the same name to
`stop_listener/1` later. Returns `{ok, Pid}` on success or `{error, _}`
if a child with the same name already exists or the listen socket
cannot be opened.

`Opts` is a `t:roadrunner_listener:opts/0` map — see that type for
the full set of keys, per-key defaults, and tuning rationale.

The supervisor restarts a listener that crashes. A listener stopped by
`roadrunner_listener:drain/2` stays down; calling `start_listener/2`
again with the same name starts it fresh.
""".
-spec start_listener(Name :: atom(), roadrunner_listener:opts()) ->
    {ok, pid()} | {error, term()}.
start_listener(Name, Opts) when is_atom(Name), is_map(Opts) ->
    ChildSpec = #{
        id => Name,
        start => {roadrunner_listener, start_link, [Name, Opts]},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [roadrunner_listener]
    },
    case supervisor:start_child(roadrunner_sup, ChildSpec) of
        {ok, _Pid} = Ok ->
            Ok;
        {error, already_present} ->
            %% A drained listener exits normally and stays behind as a
            %% stopped child; replace it.
            ok = supervisor:delete_child(roadrunner_sup, Name),
            start_listener(Name, Opts);
        {error, _} = Err ->
            Err
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
Return the names of the running listeners. A listener stopped by
`roadrunner_listener:drain/2` is not included.

Order matches `supervisor:which_children/1` — typically reverse
start-order. The roadrunner application must be running.
""".
-spec listeners() -> [atom()].
listeners() ->
    [
        Name
     || {Name, Pid, _Type, Mods} <- supervisor:which_children(roadrunner_sup),
        is_pid(Pid),
        Mods =:= [roadrunner_listener]
    ].

-doc """
Emit the `drain_acknowledged` event for the current request, signalling
to the `roadrunner_event_handler` that a long-running handler
(`{loop, ...}` or WebSocket) has observed and is honoring an in-flight
`roadrunner_listener:drain/2` broadcast. Handlers should call this from their `handle_info/3` (loop)
or `handle_frame/2` (websocket) when they pattern-match on
`{roadrunner_drain, _}` and decide to wind down.

`Req` is the request map the handler received. Returns `ok`. Calling
this when no drain is in flight is harmless (the event handler sees a
stray event), but the documented usage is post-drain-receipt.

For SREs computing "how much grace did the handler use," see
`acknowledge_drain/2` which threads the `Deadline` from the
`{roadrunner_drain, Deadline}` message into the event.
""".
-spec acknowledge_drain(roadrunner_req:request()) -> ok.
acknowledge_drain(Req) when is_map(Req) ->
    roadrunner_event:drain_acknowledged(Req, undefined).

-doc """
Same as `acknowledge_drain/1` but threads the drain `Deadline`
(in milliseconds, the second element of the `{roadrunner_drain, Deadline}`
message a handler received) into the event so the event handler
can compute `Deadline - erlang:monotonic_time(millisecond)` for the
remaining grace period.
""".
-spec acknowledge_drain(roadrunner_req:request(), integer()) -> ok.
acknowledge_drain(Req, Deadline) when is_map(Req), is_integer(Deadline) ->
    roadrunner_event:drain_acknowledged(Req, Deadline).
