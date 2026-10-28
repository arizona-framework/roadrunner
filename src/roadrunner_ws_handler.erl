-module(roadrunner_ws_handler).
-moduledoc """
Behaviour for WebSocket handlers.

After a successful upgrade — signaled by a regular `roadrunner_handler`
returning `{websocket, Module, State}` (or `{websocket, Module, State,
Opts}` with `t:upgrade_opts/0`) — the session
drives a frame loop that calls `handle_frame/2` for each non-control
frame received from the client.

Control frames are handled by the session: it answers a `ping` with a
`pong` and a `close` with the closing handshake. A handler that exports
the optional `handle_control/2` also sees each `ping` and `pong`; a
`close` never reaches the handler (`terminate/2` reports it). The handler may reply
with zero or more frames (each `{Opcode, Payload}` — always
`Fin = true`) or signal close to terminate the session gracefully:

- `{close, State}` sends an empty close frame (RFC 6455 §5.5.1
  permits this).
- `{close, Code, Reason, State}` sends a close frame carrying the
  status code and reason text. `Code` must be a code a server may
  send: 1000-1003, 1007-1014 (RFC 6455 §7.4 and the IANA registry:
  1012 service restart, 1013 try again later, 1014 bad gateway), or
  3000-4999. `Reason` is iodata that must be
  valid UTF-8 and at most 123 bytes (a control frame's payload limit,
  RFC 6455 §5.5). The framework crashes the session on invalid
  `Code` / `Reason` rather than emit a malformed close frame.
- `{close, Code, Reason, Frames, State}` sends `Frames`, then that
  close frame, in the same write.

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

The optional `terminate/2` callback runs once when the session ends in
an orderly way, with the reason it ended, for handlers that need to
release something the session owned.

All callbacks share the same return shape — `{reply, Frames,
NewState}`, `{ok, NewState}`, `{close, NewState}`, or
`{close, Code, Reason, NewState}`, optionally with a 4-tuple
`Opts` list for `hibernate` on the reply / ok shapes.
""".

-doc """
Per-event option flags. Currently only `hibernate` is recognized;
when included in a 4-tuple callback return, the framework hibernates
the session process after the event finishes processing.
""".
-type opt() :: hibernate.

-doc """
Unified return shape for all `roadrunner_ws_handler` callbacks.

- `{reply, Frames, NewState}` — emit each `{Opcode, Payload}` frame
  (always with FIN=true) and keep the session open.
- `{reply, Frames, NewState, Opts}` — same, with an opt list (e.g.
  `[hibernate]`).
- `{ok, NewState}` — no outbound frames, keep the session open.
- `{ok, NewState, Opts}` — same, with an opt list.
- `{close, NewState}` — send an empty close frame and terminate.
- `{close, Code, Reason, NewState}` — send a close frame carrying
  `Code` (a server-permitted code: RFC 6455 §7.4 and the IANA close code
  registry, see the module docs) and UTF-8 `Reason`.
  The framework crashes the session if `Code` / `Reason` is invalid
  rather than emit a malformed close.
- `{close, Code, Reason, Frames, NewState}` — emit `Frames`, then that
  close frame, and terminate.
""".
-type result() ::
    {reply, Frames :: [{roadrunner_ws:opcode(), iodata()}], NewState :: term()}
    | {reply, Frames :: [{roadrunner_ws:opcode(), iodata()}], NewState :: term(), [opt()]}
    | {ok, NewState :: term()}
    | {ok, NewState :: term(), [opt()]}
    | {close, NewState :: term()}
    | {close, Code :: roadrunner_ws:close_code(), Reason :: iodata(), NewState :: term()}
    | {close, Code :: roadrunner_ws:close_code(), Reason :: iodata(),
        Frames :: [{roadrunner_ws:opcode(), iodata()}], NewState :: term()}.

-doc """
Optional. Runs once in the session process after the 101 has been
written to the wire and before the first frame is read, with the
state from the upgrade tuple `{websocket, Module, State[, Opts]}`. Use it
to register pubsub subscriptions, start linked workers, or push
priming frames at connect-time. Returns the same shape as
`handle_frame/2`. Handlers that don't export this callback skip
the init step.
""".
-callback init(State :: term()) -> result().

-doc """
Invoked for each non-control frame received from the client, after
the framework has reassembled fragmented messages (so the handler
always sees a complete `text` or `binary` payload). Returns one of
the `result/0` shapes: reply with frames, stay open, close
gracefully, or close with a code + reason. Control frames
(`ping`/`pong`/`close`) are auto-handled by the framework and
never reach this callback.
""".
-callback handle_frame(Frame :: roadrunner_ws:frame(), State :: term()) -> result().

-doc """
Optional. Receives any Erlang message delivered to the session
process that isn't a transport `active`-mode event. Use for
pubsub / asynchronous push patterns. Returns the same shape as
`handle_frame/2`. Handlers that don't export this callback have
unknown messages dropped silently.
""".
-callback handle_info(Info :: term(), State :: term()) -> result().

-doc """
Optional. Fires when the listener broadcasts `{roadrunner_drain,
Deadline}` (typically during a deploy via
`roadrunner_listener:drain/2` or `roadrunner_listener:notify_drain/2`).
The session pid is auto-joined into the listener's pg drain group at
upgrade time, so every WS session sees the broadcast.

`Deadline` is the integer monotonic-time millisecond after which the
listener will hard-kill conns that haven't wound down. Handlers can
subtract `erlang:monotonic_time(millisecond)` to compute remaining
grace.

Returns the same shape as `handle_frame/2`: push final frames, keep
the session open, or close gracefully (typically `{close, 1000, ~"",
NewState}` so the client reconnects to the new server version).
Handlers that don't export this callback let the session keep
running until the deadline expires; the listener then sends
`exit(Pid, shutdown)`.
""".
-callback handle_drain(Deadline :: integer(), State :: term()) -> result().

-doc """
Why a session ended, as `terminate/2` gets it:

- `normal` — the handler closed it (a `close` return).
- `remote` — the client sent a close frame.
- `shutdown` — the handler closed it from `handle_drain/2`, as the
  listener drains.
- `timeout` — the client sent nothing for the session's `idle_timeout`
  (`t:upgrade_opts/0`).
- `{error, Reason}` — the connection or the client failed: `closed`
  when the socket closed without a close frame, the transport's error,
  or the close the session sent for a client error (`protocol_error`,
  `invalid_payload`, or the cap a frame or message went over:
  `max_frame_size`, `max_message_size`).
""".
-type terminate_reason() :: normal | remote | shutdown | timeout | {error, term()}.

-doc """
Options for one session, the 4th element of a `{websocket, Module, State,
Opts}` upgrade. Each falls back to the listener's `ws` option of the same
name (`t:roadrunner_listener:ws_opts/0`):

- `headers` — added to the `101 Switching Protocols` response (e.g. a
  `set-cookie`). The handshake's own headers (`upgrade`, `connection`,
  `sec-websocket-accept`, `sec-websocket-extensions`) win: an entry
  naming one of them is dropped, as is a `content-length` or
  `transfer-encoding`, which a 1xx response must not carry.
- `compress` — whether to accept the client's permessage-deflate offer.
- `idle_timeout` — close the session (code 1001, `terminate/2` gets
  `timeout`) when the client sent nothing for this many milliseconds;
  checked once per interval, so within two of them. `infinity` turns off
  a listener-wide one for this session.
- `max_frame_size`, `max_message_size`, `recv_buffer`,
  `hibernate_after`, `active` — as the listener's (`hibernate_after` also takes
  `infinity`, to turn the listener's off for this session).
- `fullsweep_after`, `max_heap_size` — the session process's garbage
  collection settings (`erlang:spawn_opt/4`).

The values are the application's to get right, as the rest of a
response is: they are not checked at the upgrade, and a key not listed
here crashes it.
""".
-type upgrade_opts() :: #{
    headers => roadrunner_http:headers(),
    compress => boolean(),
    idle_timeout => pos_integer() | infinity,
    max_frame_size => 0..16#7FFFFFFF,
    max_message_size => 0..16#7FFFFFFF,
    recv_buffer => 1..16#7FFFFFFF,
    hibernate_after => pos_integer() | infinity,
    active => once | 1..32767,
    fullsweep_after => non_neg_integer(),
    max_heap_size => erlang:max_heap_size()
}.

-doc """
Optional. Runs once in the session process as the session ends, after
any final frames (including the close) went out, with the reason it
ended and the last state. The return value is ignored. Use it to
release what the session holds that its exit would not.

It is not called when a callback crashes, or when the session is killed
(the listener's drain deadline passing for a handler without
`handle_drain/2`).
""".
-callback terminate(Reason :: terminate_reason(), State :: term()) -> term().

-doc """
Optional. Gets each `ping` and `pong` frame the client sends, as a
`#{opcode := ping | pong, payload := Payload}` frame map, after the
session answered a `ping` with its `pong`. Returns the same shape as
`handle_frame/2`. Handlers that don't export it never see control
frames.
""".
-callback handle_control(Frame :: roadrunner_ws:frame(), State :: term()) -> result().

-optional_callbacks([init/1, handle_info/2, handle_drain/2, handle_control/2, terminate/2]).

-export_type([opt/0, result/0, terminate_reason/0, upgrade_opts/0]).
