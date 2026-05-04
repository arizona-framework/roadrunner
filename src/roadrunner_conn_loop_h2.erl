-module(roadrunner_conn_loop_h2).
-moduledoc """
HTTP/2 (RFC 9113) connection process.

**Phase H1 stub.** This module is invoked from `roadrunner_conn_loop`'s
post-`shoot` dispatch when the TLS handshake negotiated `h2` AND the
listener has `http2_enabled => true`. The current implementation
sends an empty SETTINGS frame followed by GOAWAY(NO_ERROR) and exits
cleanly — h2 ALPN advertisement and the dispatch fork work, but no
streams are accepted yet.

Subsequent phases (per the H2 plan) will build out:

- Phase H2: connection preface read + SETTINGS exchange + ACK.
- Phase H3: full frame codec (HEADERS, DATA, PRIORITY, RST_STREAM,
  PING, WINDOW_UPDATE, PUSH_PROMISE, CONTINUATION).
- Phase H4: HPACK header compression (RFC 7541).
- Phase H5+: stream state machine, multiplexing, flow control,
  stream response shapes, drain, telemetry, compression integration.

Until then this stub keeps the dispatch path live so we can verify
ALPN selection end-to-end without committing to any stream
semantics.
""".

-export([enter/5]).

%% Pre-encoded frames for the H1 stub. Real frame encoding lands in
%% the Phase H3 codec. RFC 9113 §6.5: SETTINGS frame header is
%% 9 bytes — 24-bit length + 8-bit type (4) + 8-bit flags (0) +
%% 32-bit reserved+stream_id (0). Empty payload because we have
%% nothing to advertise yet (defaults are fine for a connection
%% we're about to GOAWAY).
-define(EMPTY_SETTINGS, <<0:24, 4, 0, 0:32>>).

%% RFC 9113 §6.8: GOAWAY frame is type 7, stream id 0, payload =
%% 32-bit reserved+last_stream_id + 32-bit error_code + optional
%% debug data. last_stream_id = 0 (we processed nothing);
%% error_code = NO_ERROR (0). Total payload 8 bytes.
-define(GOAWAY_NO_ERROR, <<8:24, 7, 0, 0:32, 0:32, 0:32>>).

-doc """
Top-level entry from the HTTP/1.1 dispatch fork. Owns the socket
from this point on; takes responsibility for releasing the listener
slot and firing `[roadrunner, listener, conn_close]` telemetry.
""".
-spec enter(
    roadrunner_transport:socket(),
    roadrunner_conn:proto_opts(),
    atom(),
    {inet:ip_address(), inet:port_number()} | undefined,
    integer()
) -> no_return().
enter(Socket, ProtoOpts, ListenerName, Peer, StartMono) ->
    proc_lib:set_label({roadrunner_conn_loop_h2, ListenerName, Peer}),
    %% Phase H1 stub: announce the connection, immediately tear it
    %% down. The peer sees a real h2 conn (preface SETTINGS) followed
    %% by an explicit GOAWAY rather than a TCP RST, so its error
    %% reporting is meaningful.
    _ = roadrunner_transport:send(Socket, [?EMPTY_SETTINGS, ?GOAWAY_NO_ERROR]),
    roadrunner_telemetry:listener_conn_close(StartMono, #{
        listener_name => ListenerName,
        peer => Peer,
        requests_served => 0
    }),
    ok = roadrunner_conn:release_slot(ProtoOpts),
    ok = roadrunner_transport:close(Socket),
    exit(normal).
