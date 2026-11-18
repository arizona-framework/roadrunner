%% The connection options: the listener options flattened and resolved once,
%% at listener start (`roadrunner_listener:build_proto_opts/2`), and copied
%% into every acceptor and connection. Shared by the modules that read it:
%% the listener that builds it, the acceptor, the HTTP/1.1, HTTP/2 and
%% HTTP/3 connection loops, their stream workers and the WebSocket session.
%% Matching it by field keeps each read off a map lookup. Private: not part
%% of the roadrunner API.
%%
%% A protocol's fields keep the defaults below when that protocol is off,
%% and an optional feature's when it is off. A record built by hand (tests)
%% sets only what it needs: the defaults are the listener's, except
%% `accept_priority` (`normal`: the acceptor keeps its priority) and
%% `ws_buffer` (`undefined`: a session keeps the socket's buffer).
-record(proto_opts, {
    dispatch :: roadrunner_conn:dispatch(),
    middlewares = [] :: roadrunner_middleware:middlewares(),
    max_content_length = 10485760 :: non_neg_integer(),
    %% WebSocket inbound size caps. `ws_max_frame_size` bounds a single
    %% frame's declared payload (enforced before buffering);
    %% `ws_max_message_size` bounds a reassembled message (the running sum
    %% of fragment payloads, and the decompressed size under
    %% permessage-deflate).
    ws_max_frame_size = 10485760 :: non_neg_integer(),
    ws_max_message_size = 10485760 :: non_neg_integer(),
    %% inet `buffer` for a WebSocket session: a fixed size,
    %% `{adaptive, Base, Max}` (the listener's default: from `Base`, its
    %% `idle_recv_buffer`, up to `Max`, its `recv_buffer`), or `undefined`
    %% to keep the socket's buffer.
    ws_buffer = undefined :: pos_integer() | {adaptive, pos_integer(), pos_integer()} | undefined,
    %% Idle ms after which a WebSocket session hibernates; `infinity` never
    %% hibernates on idle.
    ws_hibernate_after = infinity :: pos_integer() | infinity,
    %% Whether a WebSocket upgrade accepts permessage-deflate, and with
    %% which zlib settings (`roadrunner_ws:compress_config/1`).
    ws_compress = false :: false | roadrunner_ws:compress_config(),
    %% Ms of client silence after which a WebSocket session closes;
    %% `infinity` never does.
    ws_idle_timeout = infinity :: pos_integer() | infinity,
    %% How a WebSocket session reads its socket: `once`, or up to `N` reads
    %% per arm (the listener's `ws.active`); `undefined` is `once` on plain
    %% TCP and `16` on TLS.
    ws_active = undefined :: once | 1..32767 | undefined,
    %% A WebSocket session's heap floor
    %% (`roadrunner_ws_session:raise_heap_floor/1`): the least heap, in
    %% words, a `handle_info/2` must have needed to raise it, and the most
    %% it rises to, `0` when off (the listener's `ws.heap_floor` `min` and
    %% `max`).
    ws_heap_floor_min = 2586 :: non_neg_integer(),
    ws_heap_floor_max = 0 :: non_neg_integer(),
    request_timeout = 30000 :: non_neg_integer(),
    %% Bound on the TLS handshake in the accept path; see the
    %% `tls_handshake_timeout` listener opt.
    tls_handshake_timeout = 5000 :: pos_integer(),
    keep_alive_timeout = 60000 :: non_neg_integer(),
    max_keep_alive_requests = infinity :: infinity | pos_integer(),
    max_clients = 16384 :: pos_integer(),
    client_counter :: counters:counters_ref(),
    %% Per-listener drain registry (`{Pid}` rows). The listener always sets
    %% it; `undefined` (a record built by hand) registers nothing.
    drain_table = undefined :: ets:table() | undefined,
    requests_counter :: atomics:atomics_ref(),
    rejected_counter :: atomics:atomics_ref(),
    %% Aggregate in-flight ceiling for the multiplexed protocols (h2/h3): a
    %% cap on concurrent live stream-worker processes across the whole
    %% listener, independent of `max_clients` and `max_concurrent_streams`.
    %% `infinity` disables it. `inflight_counter` is the live gauge
    %% (acquired before a worker spawns, released on its `DOWN`, by the
    %% `slot_keeper` once the worker's connection has closed);
    %% `throttled_counter` is the cumulative count of streams refused at the
    %% ceiling. h1 is bounded by `max_clients` and uses these only in shed
    %% mode, where the ceiling is one budget across every protocol.
    max_concurrent_requests = infinity :: infinity | pos_integer(),
    %% What happens to a request over that ceiling.
    overload = refuse :: roadrunner_conn:overload(),
    %% The listener's slot keeper (`roadrunner_overload_queue`), started
    %% when the ceiling is finite: a closing h2/h3 conn hands it the slots
    %% of the workers still running, so they stay counted until those
    %% workers end. `undefined` with no ceiling.
    slot_keeper = undefined :: pid() | undefined,
    inflight_counter = undefined :: counters:counters_ref() | undefined,
    throttled_counter :: atomics:atomics_ref(),
    %% Per-peer request-rate guard (off by default). `rate_limit` carries the
    %% resolved config + per-listener ETS bucket store when the `rate_limit`
    %% opt is set, else `undefined`. `rate_limited_counter` is the cumulative
    %% count of requests refused at the per-peer rate, mirroring
    %% `throttled_counter`, surfaced in `roadrunner_listener:info/1` (stays 0
    %% when the guard is off).
    rate_limit = undefined :: undefined | roadrunner_conn:rate_limit(),
    rate_limited_counter :: atomics:atomics_ref(),
    min_bytes_per_second = 100 :: non_neg_integer(),
    body_buffering = auto :: roadrunner_listener:body_buffering(),
    listener_name = undefined :: atom(),
    %% When `false`, conns skip registering in the listener's drain registry
    %% (`drain_table`). The registry is the mechanism
    %% `roadrunner_listener:drain/2` uses to broadcast
    %% `{roadrunner_drain, Deadline}` to in-flight conns; loop / SSE /
    %% WebSocket handlers depend on it. Short-lived h1 workloads can opt out
    %% to skip the insert and delete per conn.
    graceful_drain = true :: boolean(),
    %% Acceptor process priority (`roadrunner_acceptor`): `high` accepts
    %% promptly and drops to `normal` while rejecting at `max_clients`;
    %% `normal` keeps the acceptor at `normal`.
    accept_priority = normal :: high | normal,
    %% When `true`, `roadrunner_conn_loop:awaiting_shoot/3` reads and strips a
    %% PROXY-protocol header (an L4 balancer prepends it) before serving, and
    %% the request peer is the real client. TCP-only; the listener rejects it
    %% on an HTTP/3-only listener.
    proxy_protocol = false :: boolean(),
    %% The compiled `real_ip` listener option (`roadrunner_real_ip:compile/1`),
    %% `undefined` when the option is off.
    real_ip = undefined :: roadrunner_real_ip:config() | undefined,
    %% TLS options for a TLS listener that also reads the PROXY protocol: it
    %% accepts plain TCP (the header comes before any TLS bytes) and the conn
    %% upgrades each socket with these once the header is in. `undefined` on
    %% every other listener; a TLS listener without the PROXY protocol
    %% handshakes the socket `ssl:listen` accepted.
    tls_upgrade = undefined :: [ssl:tls_server_option()] | undefined,
    %% Enabled protocols as a flat atom list in user-supplied (ALPN
    %% preference) order. On plain TCP with `[http2]`,
    %% `roadrunner_conn_loop:serve/5` routes straight to the h2 conn loop;
    %% with both `http1` and `http2` it picks the loop from each connection's
    %% first bytes. Each protocol's tuning is flattened onto the `http1_*`,
    %% `http2_*` and `http3_*` fields below, at their defaults when the
    %% protocol is off. The user-facing nested shape
    %% (`{http2, #{conn_window => N, ...}}`) is documented in
    %% `t:roadrunner_listener:opts/0`.
    protocols = [http1] :: [http1 | http2 | http3, ...],
    %% HTTP/2 receive-window tuning (RFC 9113 §6.5.2 / §6.9.2).
    %% `http2_window_refill_threshold` is `undefined` unless set: each
    %% window then refills at half its peak.
    http2_conn_window = 16#7FFFFFFF :: 1..16#7FFFFFFF,
    http2_stream_window = 16777216 :: 1..16#7FFFFFFF,
    http2_window_refill_threshold = undefined :: 1..16#7FFFFFFF | undefined,
    http2_max_concurrent_streams = 100 :: 1..16#7FFFFFFF,
    http2_max_header_block = 16384 :: 1..16#7FFFFFFF,
    http2_max_header_list_size = 32768 :: 1..16#7FFFFFFF,
    http2_active = 16 :: once | 1..32767,
    %% The HTTP/2 `ping_policy`, one field per setting, all `undefined` when
    %% it is `false` (`roadrunner_conn_loop_http2:ping_policy/1`).
    http2_ping_min_time = undefined :: 1..16#FFFFFFFF | undefined,
    http2_ping_permit_without_stream = undefined :: boolean() | undefined,
    http2_ping_max_strikes = undefined :: 0..16#7FFFFFFF | undefined,
    %% The HTTP/2 `connection_age`, both fields `undefined` when it is
    %% `false`.
    http2_connection_age_max = undefined :: 1..16#FFFFFFFF | undefined,
    http2_connection_age_grace = undefined :: 0..16#FFFFFFFF | infinity | undefined,
    %% HTTP/3 tuning, flattened from `{http3, #{...}}`.
    http3_listeners = 8 :: 1..1024,
    http3_max_header_block = 16384 :: 1..16#7FFFFFFF,
    http3_max_streams_bidi = 100 :: 1..16#7FFFFFFF,
    http3_max_field_section_size = 32768 :: 1..16#7FFFFFFF,
    %% SETTINGS_QPACK_MAX_TABLE_CAPACITY (RFC 9204 §5): the dynamic table
    %% the peer's encoder may fill, by default the size of HTTP/2's default
    %% HPACK table; 0 turns the dynamic table off.
    http3_qpack_max_table_capacity = 4096 :: 0..16#7FFFFFFF,
    http3_qpack_blocked_streams = 16 :: 0..16#7FFFFFFF,
    %% HTTP/1 inbound size limits and close linger, flattened from
    %% `{http1, #{...}}`.
    http1_max_request_line = 8192 :: 1..16#7FFFFFFF,
    http1_max_header_line = 8192 :: 1..16#7FFFFFFF,
    http1_max_header_block = 10240 :: 1..16#7FFFFFFF,
    http1_max_header_count = 100 :: 1..16#7FFFFFFF,
    http1_linger_timeout = 1000 :: 0..16#7FFFFFFF,
    %% Set only when `{http1, #{active => ...}}` is given; `undefined`, the
    %% conn picks by transport.
    http1_active = undefined :: once | 1..32767 | undefined,
    %% Idle ms after which an HTTP/1.1 or HTTP/2 connection hibernates; `0`
    %% (the listener's `hibernate_after` unset) never does.
    hibernate_after = 0 :: non_neg_integer(),
    %% `{Idle, Max}` on a plain-TCP listener whose sockets start at
    %% `idle_recv_buffer` (`Idle`) below `recv_buffer` (`Max`): an HTTP/1.1
    %% connection grows its buffer to `Max` before it reads a large body
    %% (`roadrunner_conn_loop:grow_buffer/2`), an h2c one at its first DATA
    %% payload (`roadrunner_conn_loop_http2:grow_buffer/2`). `undefined` on
    %% TLS.
    grow_recv_buffer = undefined :: {pos_integer(), pos_integer()} | undefined,
    %% The `Alt-Svc` value an HTTP/1.1 or HTTP/2 response advertises HTTP/3
    %% with, when the listener co-serves it on a fixed port.
    alt_svc = undefined :: binary() | undefined,
    %% The most heap, in words, an HTTP/1.1 connection raises its
    %% `min_heap_size` to (`roadrunner_conn_loop:raise_heap_floor/1`), or an
    %% HTTP/2 or HTTP/3 connection starts its stream workers at
    %% (`roadrunner_stream_worker:conn_heap_floor/1`). `undefined` when
    %% `handler_spawn.heap_floor` is `false`.
    heap_floor = undefined :: pos_integer() | undefined,
    %% Flattened spawn config for every handler-running process: the public
    %% `handler_spawn => #{opts}` listener opt over the defaults.
    handler_spawn_opts = [{fullsweep_after, 0}] :: [proc_lib:start_spawn_option()]
}).
