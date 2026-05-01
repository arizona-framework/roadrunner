-module(cactus_ws_handler).
-moduledoc """
Behaviour for WebSocket handlers.

After a successful upgrade — signaled by a regular `cactus_handler`
returning `{websocket, Module, State}` — the connection process
drives a frame loop that calls `handle_frame/2` for each non-control
frame received from the client.

Control frames (`ping`/`close`) are auto-handled by the connection
layer and **never** reach the user callback. The handler may reply
with zero or more frames (each `{Opcode, Payload}` — always
`Fin = true`) or signal `{close, State}` to terminate the session
gracefully. State is passed through unchanged by the framework.

The 4-tuple `{reply, Frames, NewState, Opts}` and 3-tuple
`{ok, NewState, Opts}` variants accept an opt list. Currently
recognized opt:

- `hibernate` — after the framework finishes processing this event
  (and any other queued events), the session process hibernates
  until the next inbound frame. Useful for mostly-idle WebSocket
  endpoints (chat, notifications, LiveView channels) — drops the
  per-process heap to ~1KB and saves significant memory at scale.
  Hibernation has a per-wake CPU cost (~tens of microseconds for
  the GC), so don't enable it for high-frequency frame patterns.

Init and terminate callbacks are intentionally omitted at this stage
— the initial `State` flows in via the upgrade tuple, and most
handlers don't need bespoke teardown.
""".

-type opt() :: hibernate.

-callback handle_frame(Frame :: cactus_ws:frame(), State :: term()) ->
    {reply, Frames :: [{cactus_ws:opcode(), iodata()}], NewState :: term()}
    | {reply, Frames :: [{cactus_ws:opcode(), iodata()}], NewState :: term(), [opt()]}
    | {ok, NewState :: term()}
    | {ok, NewState :: term(), [opt()]}
    | {close, NewState :: term()}.

-export_type([opt/0]).
