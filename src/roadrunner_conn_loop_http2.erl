-module(roadrunner_conn_loop_http2).
-moduledoc """
HTTP/2 (RFC 9113) connection process.

**Phase H2.** This module is invoked from `roadrunner_conn_loop`'s
post-`shoot` dispatch when the TLS handshake negotiated `h2` AND the
listener has `http2_enabled => true`.

Current behavior:

1. Send our initial SETTINGS frame (RFC 9113 §3.4 — server-side
   preface is just a SETTINGS frame, no preface bytes).
2. Read the 24-byte client connection preface
   (`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`, RFC 9113 §3.4).
3. Read the client's initial SETTINGS frame (must arrive immediately
   after the preface per §3.4).
4. ACK the client's SETTINGS.
5. Send GOAWAY(NO_ERROR, last_stream_id=0) and close the connection.

Step 5 is the "stops here" choice for Phase H2: we've completed the
mandatory connection-level handshake, but the stream state machine
isn't built yet (Phase H5+), so we tell the client we're done in a
way that's RFC-friendly. Real h2 clients see a clean shutdown
rather than a stalled connection.

Subsequent phases (per the H2 plan) will replace step 5 with the
real frame demux loop.
""".

-export([enter/5]).

%% RFC 9113 §3.4 client connection preface — fixed 24 bytes:
%% `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`.
-define(PREFACE, ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").
-define(PREFACE_LEN, 24).

%% Read deadline for each step of the handshake. The whole exchange
%% should complete in a few RTTs at most; long reads here are signs
%% of a stuck/abandoned client.
-define(HANDSHAKE_TIMEOUT, 10000).

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
    proc_lib:set_label({roadrunner_conn_loop_http2, ListenerName, Peer}),
    LocalSettings = roadrunner_http2_settings:new(),
    handshake(Socket, ProtoOpts, ListenerName, Peer, StartMono, LocalSettings).

%% Phase H2 handshake: announce our SETTINGS, read preface + client
%% SETTINGS, ACK, then GOAWAY. Any read/parse error short-circuits
%% to the same exit-clean path.
-spec handshake(
    roadrunner_transport:socket(),
    roadrunner_conn:proto_opts(),
    atom(),
    {inet:ip_address(), inet:port_number()} | undefined,
    integer(),
    roadrunner_http2_settings:settings()
) -> no_return().
handshake(Socket, ProtoOpts, ListenerName, Peer, StartMono, LocalSettings) ->
    OurSettings = roadrunner_http2_settings:initial_settings_frame(LocalSettings),
    case roadrunner_transport:send(Socket, OurSettings) of
        ok -> read_preface(Socket, ProtoOpts, ListenerName, Peer, StartMono);
        {error, _} -> exit_clean(Socket, ProtoOpts, ListenerName, Peer, StartMono)
    end.

-spec read_preface(
    roadrunner_transport:socket(),
    roadrunner_conn:proto_opts(),
    atom(),
    {inet:ip_address(), inet:port_number()} | undefined,
    integer()
) -> no_return().
read_preface(Socket, ProtoOpts, ListenerName, Peer, StartMono) ->
    case roadrunner_transport:recv(Socket, ?PREFACE_LEN, ?HANDSHAKE_TIMEOUT) of
        {ok, ?PREFACE} ->
            read_client_settings(Socket, ProtoOpts, ListenerName, Peer, StartMono);
        %% Wrong preface bytes or recv error — peer isn't speaking h2
        %% (or speaking it correctly). Bail without GOAWAY: the
        %% conversation isn't established yet.
        _ ->
            exit_clean(Socket, ProtoOpts, ListenerName, Peer, StartMono)
    end.

-spec read_client_settings(
    roadrunner_transport:socket(),
    roadrunner_conn:proto_opts(),
    atom(),
    {inet:ip_address(), inet:port_number()} | undefined,
    integer()
) -> no_return().
read_client_settings(Socket, ProtoOpts, ListenerName, Peer, StartMono) ->
    case read_frame_header(Socket) of
        {ok, Length, 4, Flags, 0} ->
            read_client_settings_payload(
                Socket, ProtoOpts, ListenerName, Peer, StartMono, Length, Flags
            );
        %% Anything other than a connection-level (stream id 0)
        %% SETTINGS frame is a §3.4 protocol error. Send GOAWAY and
        %% bail. The error code distinction (PROTOCOL_ERROR vs
        %% NO_ERROR) is refined in Phase H3 once the real frame
        %% codec lands.
        _ ->
            _ = send_goaway(Socket),
            exit_clean(Socket, ProtoOpts, ListenerName, Peer, StartMono)
    end.

%% After we know the leading frame is a non-ACK SETTINGS, drain its
%% payload, ACK it, then GOAWAY (Phase H2 endpoint — streams not
%% accepted yet).
-spec read_client_settings_payload(
    roadrunner_transport:socket(),
    roadrunner_conn:proto_opts(),
    atom(),
    {inet:ip_address(), inet:port_number()} | undefined,
    integer(),
    non_neg_integer(),
    non_neg_integer()
) -> no_return().
read_client_settings_payload(Socket, ProtoOpts, ListenerName, Peer, StartMono, 0, 0) ->
    %% Empty SETTINGS body, no ACK flag — peer accepted defaults.
    %% ACK and proceed to graceful shutdown.
    Ack = roadrunner_http2_settings:settings_ack_frame(),
    _ = roadrunner_transport:send(Socket, [Ack, ?GOAWAY_NO_ERROR]),
    exit_clean(Socket, ProtoOpts, ListenerName, Peer, StartMono);
read_client_settings_payload(Socket, ProtoOpts, ListenerName, Peer, StartMono, Length, 0) when
    Length > 0
->
    case roadrunner_transport:recv(Socket, Length, ?HANDSHAKE_TIMEOUT) of
        {ok, Payload} ->
            %% Apply for type-checking + future use (Phase H3+ will
            %% honor max_frame_size etc). The result is discarded
            %% here because Phase H2 is handshake-only.
            _ = roadrunner_http2_settings:apply_payload(
                Payload, roadrunner_http2_settings:new()
            ),
            Ack = roadrunner_http2_settings:settings_ack_frame(),
            _ = roadrunner_transport:send(Socket, [Ack, ?GOAWAY_NO_ERROR]),
            exit_clean(Socket, ProtoOpts, ListenerName, Peer, StartMono);
        _ ->
            exit_clean(Socket, ProtoOpts, ListenerName, Peer, StartMono)
    end;
read_client_settings_payload(Socket, ProtoOpts, ListenerName, Peer, StartMono, _, _Flags) ->
    %% A SETTINGS frame with the ACK flag set MUST have an empty
    %% payload (RFC 9113 §6.5). Either the flag is set with a body,
    %% or some other non-zero flag combination — both are protocol
    %% errors. GOAWAY and bail.
    _ = send_goaway(Socket),
    exit_clean(Socket, ProtoOpts, ListenerName, Peer, StartMono).

%% Read a 9-byte HTTP/2 frame header. Returns the parsed length /
%% type / flags / stream id, or `error` on short read or transport
%% failure.
-spec read_frame_header(roadrunner_transport:socket()) ->
    {ok, non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
    | error.
read_frame_header(Socket) ->
    case roadrunner_transport:recv(Socket, 9, ?HANDSHAKE_TIMEOUT) of
        {ok, <<Length:24, Type, Flags, _Reserved:1, StreamId:31>>} ->
            {ok, Length, Type, Flags, StreamId};
        _ ->
            error
    end.

-spec send_goaway(roadrunner_transport:socket()) -> ok | {error, term()}.
send_goaway(Socket) ->
    roadrunner_transport:send(Socket, ?GOAWAY_NO_ERROR).

-spec exit_clean(
    roadrunner_transport:socket(),
    roadrunner_conn:proto_opts(),
    atom(),
    {inet:ip_address(), inet:port_number()} | undefined,
    integer()
) -> no_return().
exit_clean(Socket, ProtoOpts, ListenerName, Peer, StartMono) ->
    roadrunner_telemetry:listener_conn_close(StartMono, #{
        listener_name => ListenerName,
        peer => Peer,
        requests_served => 0
    }),
    ok = roadrunner_conn:release_slot(ProtoOpts),
    ok = roadrunner_transport:close(Socket),
    exit(normal).
