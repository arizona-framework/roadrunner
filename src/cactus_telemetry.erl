-module(cactus_telemetry).
-moduledoc """
Telemetry event emitters for cactus.

Centralizes the event names and the metadata shape so subscribers
have one module to grep for and tests have one place to attach.

## Events

- `[cactus, request, start]` — fired by `cactus_conn` once a request's
  headers parse and `request_id` is assigned, before the
  middleware/handler pipeline is invoked.

  - **Measurements:** `system_time` (`erlang:system_time/0`).
  - **Metadata:** `request_id`, `peer`, `method`, `path`, `scheme`,
    `listener_name`.

- `[cactus, request, stop]` — fired after the handler's response is
  written to the wire (or, for `stream`/`loop`/`websocket`, after the
  initial dispatch returns).

  - **Measurements:** `duration` in `native` time units. Convert
    with `erlang:convert_time_unit(Duration, native, microsecond)`.
  - **Metadata:** start metadata + `status` (response code, `101`
    for websocket upgrades) and `response_kind`
    (`buffered | stream | loop | websocket`).

- `[cactus, request, exception]` — fired when the
  middleware/handler pipeline raises. The exception is rethrown
  after the event is emitted so the conn's existing 500-on-crash
  path is preserved.

  - **Measurements:** `duration`.
  - **Metadata:** start metadata + `kind` (`error | exit | throw`)
    and `reason`.

- `[cactus, response, send_failed]` — fired when a primary response
  write (`buffered_response`, `stream_response_head`,
  `loop_response_head`, or `websocket_upgrade_response`) returns
  `{error, _}`. Status line was already going on the wire, so the
  conn closes shortly after; this event lets operators correlate
  the failure with the `request_id` from the conn's `logger`
  process metadata.

  - **Measurements:** `system_time`.
  - **Metadata:** `phase`, `reason`, plus the conn's logger
    process metadata (`request_id`, `peer`, `method`, `path`).

- `[cactus, listener, accept]` — fired in the conn process once
  the acceptor's `shoot` signal has been received and the peername
  is known. Subscribers can use this to drive a "live connections"
  gauge or correlate with `[cactus, listener, conn_close]`.

  - **Measurements:** `system_time`.
  - **Metadata:** `listener_name`, `peer`.

- `[cactus, listener, conn_close]` — fired when the conn process is
  about to exit (after the keep-alive loop ends, before the after-
  clause releases the slot). `requests_served` is the count of
  successfully-parsed requests on this conn; parse failures and
  silent timeout/slow-client kicks are NOT counted.

  - **Measurements:** `duration` in `native` time units.
  - **Metadata:** `listener_name`, `peer`, `requests_served`.

- `[cactus, ws, upgrade]` — fired in the conn process once the
  WebSocket handshake response has been written. Marks the
  transition from HTTP/1.1 keep-alive into the WS frame loop.

  - **Measurements:** `system_time`.
  - **Metadata:** `listener_name`, `peer`, `request_id`, `module`
    (the `cactus_ws_handler` module driving the loop).

- `[cactus, ws, frame_in]` — fired for every frame parsed from the
  client, including control frames (`ping`, `pong`, `close`) that
  the conn handles internally before delegating to the user
  handler.

  - **Measurements:** `system_time`, `payload_size` (bytes).
  - **Metadata:** `listener_name`, `peer`, `request_id`, `module`,
    `opcode` (`text | binary | continuation | close | ping | pong`).

- `[cactus, ws, frame_out]` — fired for every frame written back to
  the client: handler `{reply, ...}` outputs, automatic pong
  responses, and the close frame on shutdown. Each frame in a
  batched `{reply, [F1, F2, ...]}` produces one event.

  - **Measurements:** `system_time`, `payload_size` (bytes).
  - **Metadata:** `listener_name`, `peer`, `request_id`, `module`,
    `opcode`.

The `start_time` value returned by `request_start/1` must be passed
back into `request_stop/3` / `request_exception/4` to compute
`duration`. Subscribers can wire up via `telemetry:attach/4` in
production or `telemetry_test:attach_event_handlers/2` in tests.
""".

-export([
    request_start/1,
    request_stop/3,
    request_exception/4,
    response_send/2,
    listener_accept/1,
    listener_conn_close/2,
    request_rejected/1,
    slots_reconciled/1,
    drain_acknowledged/1,
    ws_upgrade/1,
    ws_frame_in/2,
    ws_frame_out/2
]).

-export_type([metadata/0]).

-type metadata() :: #{
    request_id := binary(),
    peer := {inet:ip_address(), inet:port_number()} | undefined,
    method := binary(),
    path := binary(),
    scheme := http | https,
    listener_name := atom()
}.

-doc "Emit `[cactus, request, start]` and return the start time.".
-spec request_start(metadata()) -> integer().
request_start(Metadata) ->
    StartMono = erlang:monotonic_time(),
    telemetry:execute(
        [cactus, request, start],
        #{system_time => erlang:system_time()},
        Metadata
    ),
    StartMono.

-doc """
Emit `[cactus, request, stop]` with `duration = now - StartMono` and
the start metadata merged with `Extra` (status + response_kind).
""".
-spec request_stop(integer(), metadata(), map()) -> ok.
request_stop(StartMono, Metadata, Extra) ->
    telemetry:execute(
        [cactus, request, stop],
        #{duration => erlang:monotonic_time() - StartMono},
        maps:merge(Metadata, Extra)
    ),
    ok.

-doc """
Emit `[cactus, request, exception]` with `duration` and the start
metadata annotated with `kind`/`reason`.
""".
-spec request_exception(integer(), metadata(), atom(), term()) -> ok.
request_exception(StartMono, Metadata, Class, Reason) ->
    telemetry:execute(
        [cactus, request, exception],
        #{duration => erlang:monotonic_time() - StartMono},
        Metadata#{kind => Class, reason => Reason}
    ),
    ok.

-doc """
Inspect a primary-write `gen_tcp:send`/`ssl:send` result. On `ok`,
this is a no-op. On `{error, _}`, it emits
`[cactus, response, send_failed]` with the conn's logger process
metadata merged in plus a `phase` tag, then logs `?LOG_NOTICE`. The
original send result is returned so callers can chain.
""".
-spec response_send(ok | {error, term()}, atom()) -> ok | {error, term()}.
response_send(ok, _Phase) ->
    ok;
response_send({error, Reason} = Err, Phase) ->
    telemetry:execute(
        [cactus, response, send_failed],
        #{system_time => erlang:system_time()},
        merge_logger_metadata(#{phase => Phase, reason => Reason})
    ),
    logger:notice(#{
        msg => "cactus response send failed",
        phase => Phase,
        reason => Reason
    }),
    Err.

%% Pull `request_id`/`peer`/`method`/`path` from the conn's logger
%% process metadata if it has been set; otherwise the failure happened
%% before `cactus_conn:set_request_logger_metadata/1` ran (rare —
%% pre-handshake) and the event metadata is just `phase`/`reason`.
-spec merge_logger_metadata(map()) -> map().
merge_logger_metadata(Extra) ->
    case logger:get_process_metadata() of
        undefined -> Extra;
        Md when is_map(Md) -> maps:merge(Md, Extra)
    end.

-doc """
Emit `[cactus, listener, accept]` and return the start time so
`listener_conn_close/2` can compute the connection's duration.
""".
-spec listener_accept(map()) -> integer().
listener_accept(Metadata) ->
    StartMono = erlang:monotonic_time(),
    telemetry:execute(
        [cactus, listener, accept],
        #{system_time => erlang:system_time()},
        Metadata
    ),
    StartMono.

-doc """
Emit `[cactus, listener, conn_close]` with the connection's wall-
clock duration and the supplied metadata (which should include
`requests_served`).
""".
-spec listener_conn_close(integer(), map()) -> ok.
listener_conn_close(StartMono, Metadata) ->
    telemetry:execute(
        [cactus, listener, conn_close],
        #{duration => erlang:monotonic_time() - StartMono},
        Metadata
    ),
    ok.

-doc """
Emit `[cactus, request, rejected]` when a request is dropped at the
parser/limit layer before any handler runs (malformed request line,
header CRLF injection, header count or block size limits exceeded,
oversized Content-Length, transfer-encoding conflicts, etc.). Lets
ops tooling track protocol-attack-shaped traffic without scraping
debug logs. `Metadata` should include `listener_name`, `peer`, and
`reason` (the parser's error atom).
""".
-spec request_rejected(map()) -> ok.
request_rejected(Metadata) ->
    telemetry:execute(
        [cactus, request, rejected],
        #{system_time => erlang:system_time()},
        Metadata
    ),
    ok.

-doc """
Emit `[cactus, listener, slots_reconciled]` when the optional
`slot_reconciliation` reaper releases orphan slots that the
`kill`-bypasses-`terminate` path left behind. `Metadata` should
include `listener_name`, `released` (count), and `counter_was`
(value before reconciliation).
""".
-spec slots_reconciled(map()) -> ok.
slots_reconciled(Metadata) ->
    telemetry:execute(
        [cactus, listener, slots_reconciled],
        #{system_time => erlang:system_time()},
        Metadata
    ),
    ok.

-doc """
Emit `[cactus, drain, acknowledged]` when a long-running handler
(`{loop, ...}` response or WebSocket session) participates in a
graceful shutdown. SREs running a `cactus_listener:drain/2` use
this signal to distinguish handlers that honored the deadline from
those that needed to be force-killed once the timeout expired.

`Metadata` should include `listener_name`, `request_id`, `peer`,
and `module` so subscribers can correlate with `[cactus, request, _]`
events.
""".
-spec drain_acknowledged(map()) -> ok.
drain_acknowledged(Metadata) ->
    telemetry:execute(
        [cactus, drain, acknowledged],
        #{system_time => erlang:system_time()},
        Metadata
    ),
    ok.

-doc "Emit `[cactus, ws, upgrade]` as the conn enters the WebSocket loop.".
-spec ws_upgrade(map()) -> ok.
ws_upgrade(Metadata) ->
    telemetry:execute(
        [cactus, ws, upgrade],
        #{system_time => erlang:system_time()},
        Metadata
    ),
    ok.

-doc "Emit `[cactus, ws, frame_in]` for one parsed inbound frame.".
-spec ws_frame_in(map(), non_neg_integer()) -> ok.
ws_frame_in(Metadata, PayloadSize) ->
    telemetry:execute(
        [cactus, ws, frame_in],
        #{system_time => erlang:system_time(), payload_size => PayloadSize},
        Metadata
    ),
    ok.

-doc "Emit `[cactus, ws, frame_out]` for one outbound frame.".
-spec ws_frame_out(map(), non_neg_integer()) -> ok.
ws_frame_out(Metadata, PayloadSize) ->
    telemetry:execute(
        [cactus, ws, frame_out],
        #{system_time => erlang:system_time(), payload_size => PayloadSize},
        Metadata
    ),
    ok.
