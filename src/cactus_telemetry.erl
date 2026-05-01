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

The `start_time` value returned by `request_start/1` must be passed
back into `request_stop/3` / `request_exception/4` to compute
`duration`. Subscribers can wire up via `telemetry:attach/4` in
production or `telemetry_test:attach_event_handlers/2` in tests.
""".

-export([
    request_start/1,
    request_stop/3,
    request_exception/4
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
