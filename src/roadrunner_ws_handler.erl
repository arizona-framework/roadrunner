-module(roadrunner_ws_handler).
-moduledoc """
Behaviour for WebSocket handlers.

After a successful upgrade — signaled by a regular `roadrunner_handler`
returning `{websocket, Module, State}` — the connection process
drives a frame loop that calls `handle_frame/2` for each non-control
frame received from the client.

Control frames (`ping`/`close`) are auto-handled by the connection
layer and **never** reach the user callback. The handler may reply
with zero or more frames (each `{Opcode, Payload}` — always
`Fin = true`) or signal close to terminate the session gracefully:

- `{close, State}` sends an empty close frame (RFC 6455 §5.5.1
  permits this).
- `{close, Code, Reason, State}` sends a close frame carrying the
  status code and reason text. `Code` must be a code the spec
  permits the server to send (1000-1003, 1007-1011, 1014, or
  3000-4999 per RFC 6455 §7.4). `Reason` is iodata that must be
  valid UTF-8. The framework crashes the session on invalid
  `Code` / `Reason` rather than emit a malformed close frame.

State is passed through unchanged by the framework.

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

The optional `init/1` callback runs once in the session process
after the 101 has been written to the wire and before the first
frame is read. It receives the state passed via the upgrade tuple
and may emit zero or more frames or close immediately. Use it to
register pubsub subscriptions, start linked workers, or push
priming frames at connect-time (e.g. a snapshot the client
expects before sending its first frame).

The optional `handle_info/2` callback receives any Erlang message
delivered to the session process that is not a transport
`active`-mode tuple (data/closed/error). Use it for pubsub /
asynchronous push patterns where the handler subscribes to topics
in `init/1` or `handle_frame/2` and forwards inbound messages to
the WebSocket peer. Handlers that don't export this callback have
unknown messages dropped silently.

A `terminate` callback is intentionally NOT provided — most handlers
don't need bespoke teardown, and the conn process's drain plus
listener slot reconciliation cover the lifecycle bookkeeping.

All callbacks share the same return shape — `{reply, Frames,
NewState}`, `{ok, NewState}`, `{close, NewState}`, or
`{close, Code, Reason, NewState}`, optionally with a 4-tuple
`Opts` list for `hibernate` on the reply / ok shapes.
""".

-type opt() :: hibernate.

-type result() ::
    {reply, Frames :: [{roadrunner_ws:opcode(), iodata()}], NewState :: term()}
    | {reply, Frames :: [{roadrunner_ws:opcode(), iodata()}], NewState :: term(), [opt()]}
    | {ok, NewState :: term()}
    | {ok, NewState :: term(), [opt()]}
    | {close, NewState :: term()}
    | {close, Code :: roadrunner_ws:close_code(), Reason :: iodata(), NewState :: term()}.

-callback init(State :: term()) -> result().
-callback handle_frame(Frame :: roadrunner_ws:frame(), State :: term()) -> result().
-callback handle_info(Info :: term(), State :: term()) -> result().

-optional_callbacks([init/1, handle_info/2]).

-export_type([opt/0, result/0]).
