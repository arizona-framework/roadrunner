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
    listener_conn_close/2
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
