-module(cactus_ws_handler).
-moduledoc """
Behaviour for WebSocket handlers.

After a successful upgrade — signaled by a regular `cactus_handler`
returning `{websocket, Module, State}` (wired in a later slice-6
feature) — the connection process drives a frame loop that calls
`handle_frame/2` for each non-control frame received from the client.

Control frames (`ping`/`close`) are auto-handled by the connection
layer and **never** reach the user callback. The handler may reply
with zero or more frames (each `{Opcode, Payload}` — always
`Fin = true`) or signal `{close, State}` to terminate the session
gracefully. State is passed through unchanged by the framework.

Init and terminate callbacks are intentionally omitted at this stage
— the initial `State` flows in via the upgrade tuple, and most
handlers don't need bespoke teardown.
""".

-callback handle_frame(Frame :: cactus_ws:frame(), State :: term()) ->
    {reply, Frames :: [{cactus_ws:opcode(), iodata()}], NewState :: term()}
    | {ok, NewState :: term()}
    | {close, NewState :: term()}.
