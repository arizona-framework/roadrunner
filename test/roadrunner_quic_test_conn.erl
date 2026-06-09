-module(roadrunner_quic_test_conn).
-moduledoc false.

%% In-test native QUIC CLIENT connection: a proc_lib process that connects to
%% the native server over UDP, completes the QUIC + TLS 1.3 handshake, and
%% then carries 1-RTT application streams. The client counterpart to
%% roadrunner_quic_connection. It owns its own UDP socket and reads it
%% directly (unlike the server shell, which the listener feeds). The
%% packet/frame/key pipeline is the production roadrunner_quic_* modules
%% (role-agnostic); the TLS handshake is driven by
%% roadrunner_quic_test_handshake over the client primitives in
%% roadrunner_quic_test_client.
%%
%% Once connected, the owner opens streams (open_bidi/open_uni) and writes
%% with send/4; the loop sends each as a STREAM frame in a 1-RTT packet and
%% delivers received stream data back to the owner as
%% {quic_test_stream, Conn, StreamId, Data, Fin}. The h3 framing on top is
%% roadrunner_quic_test_h3.
%%
%% The CID flow (RFC 9000 §17.2/§7.2): the client picks a random Initial DCID
%% (the server's Initial-key + original_destination_connection_id anchor) and
%% a random source CID; the server replies addressed to the client's source
%% CID and carries its own SCID, which the client then uses as the
%% destination CID for its Handshake and 1-RTT packets.
%%
%% Decryption is two-phase: the client decrypts the server Initial with the
%% Initial keys to recover the ServerHello, derives the handshake keys from
%% it, then decrypts the Handshake-level packets (carrying EE/Cert/CertVerify/
%% Finished). recv drops packets whose level has no key yet, so re-running it
%% over the buffered datagrams as keys unlock reassembles the full flight.

-include_lib("public_key/include/public_key.hrl").

-export([connect/2, close/1, open_bidi/1, open_uni/1, send/4, reset_stream/3, stop_sending/3]).

%% v1 connection-id length and signature scheme (the test cert is RSA).
-define(CID_LEN, 8).
-define(SIG_SCHEME, 16#0804).
%% Max stream bytes per 1-RTT packet, leaving room for the short header,
%% STREAM frame header, and AEAD tag within the MTU.
-define(MAX_STREAM_CHUNK, 1000).
-define(RECV_TIMEOUT, 3000).
-define(CONNECT_TIMEOUT, 8000).

%% Handshake message types (RFC 8446 §4).
-define(CERTIFICATE, 11).
-define(FINISHED, 20).

-record(conn, {
    socket :: roadrunner_quic_socket:socket(),
    host :: inet:ip_address() | inet:hostname(),
    port :: inet:port_number(),
    scid :: binary(),
    server_scid :: binary() | undefined,
    eph_priv :: binary(),
    ch_framed :: binary(),
    server_initial_keys :: roadrunner_quic_keys:keys(),
    hs_keys ::
        #{server := roadrunner_quic_keys:keys(), client := roadrunner_quic_keys:keys()}
        | undefined,
    app_server_keys :: roadrunner_quic_keys:keys() | undefined,
    app_client_keys :: roadrunner_quic_keys:keys() | undefined,
    owner :: pid() | undefined,
    finished_sent = false :: boolean(),
    %% Client Handshake-level packet number space (RFC 9000 §12.3): the
    %% address-validation PING takes pn 0, the client Finished pn 1.
    hs_pn = 0 :: non_neg_integer(),
    datagrams = [] :: [binary()],
    %% 1-RTT stream state (RFC 9000 §2.1 client-initiated stream ids).
    next_bidi = 0 :: non_neg_integer(),
    next_uni = 2 :: non_neg_integer(),
    send_pn = 0 :: non_neg_integer(),
    send_offsets = #{} :: #{non_neg_integer() => non_neg_integer()},
    recv_streams = #{} :: #{non_neg_integer() => roadrunner_quic_stream:t()}
}).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Connect to the native QUIC server at `Host`/`Port` and complete the
handshake. Blocks until the connection is established (the server's
HANDSHAKE_DONE arrives) or the handshake fails. Returns the connection pid.
""".
-spec connect(inet:ip_address() | inet:hostname(), inet:port_number()) ->
    {ok, pid()} | {error, term()}.
connect(Host, Port) ->
    Ref = make_ref(),
    Parent = self(),
    {Pid, Mon} = spawn_monitor(fun() -> init(Parent, Ref, Host, Port) end),
    receive
        {Ref, connected} ->
            erlang:demonitor(Mon, [flush]),
            {ok, Pid};
        {Ref, {error, Reason}} ->
            erlang:demonitor(Mon, [flush]),
            {error, Reason};
        {'DOWN', Mon, process, Pid, Reason} ->
            {error, {client_crashed, Reason}}
    after ?CONNECT_TIMEOUT ->
        erlang:demonitor(Mon, [flush]),
        exit(Pid, kill),
        {error, handshake_timeout}
    end.

-doc "Close the connection and its socket.".
-spec close(pid()) -> ok.
close(Pid) ->
    Pid ! stop,
    ok.

-doc "Allocate a client-initiated bidirectional stream id (RFC 9000 §2.1).".
-spec open_bidi(pid()) -> non_neg_integer().
open_bidi(Pid) ->
    call(Pid, open_bidi).

-doc "Allocate a client-initiated unidirectional stream id (RFC 9000 §2.1).".
-spec open_uni(pid()) -> non_neg_integer().
open_uni(Pid) ->
    call(Pid, open_uni).

-doc """
Send `Data` on `StreamId` in a 1-RTT packet, with the FIN bit when `Fin`.
Received stream data is delivered to the connection owner as
`{quic_test_stream, Conn, StreamId, Data, Fin}`.
""".
-spec send(pid(), non_neg_integer(), iodata(), boolean()) -> ok.
send(Pid, StreamId, Data, Fin) ->
    Ref = make_ref(),
    Pid ! {send, self(), Ref, StreamId, Data, Fin},
    receive
        {Ref, ok} -> ok
    after 5000 ->
        {error, timeout}
    end.

-doc """
Send a RESET_STREAM for `StreamId` with `ErrorCode` (RFC 9000 §19.4). The
final size is the number of bytes already sent on the stream; declaring a
smaller one than the peer received is a FINAL_SIZE_ERROR (§4.5), so the loop
fills it in from its per-stream send offset.
""".
-spec reset_stream(pid(), non_neg_integer(), non_neg_integer()) -> ok.
reset_stream(Pid, StreamId, ErrorCode) ->
    cast_frame(Pid, {reset_stream, StreamId, ErrorCode}).

-doc "Send a STOP_SENDING for `StreamId` with `ErrorCode` (RFC 9000 §19.5).".
-spec stop_sending(pid(), non_neg_integer(), non_neg_integer()) -> ok.
stop_sending(Pid, StreamId, ErrorCode) ->
    cast_frame(Pid, {stop_sending, StreamId, ErrorCode}).

cast_frame(Pid, Frame) ->
    Ref = make_ref(),
    Pid ! {frame, self(), Ref, Frame},
    receive
        {Ref, ok} -> ok
    after 5000 ->
        {error, timeout}
    end.

call(Pid, Request) ->
    Ref = make_ref(),
    Pid ! {Request, self(), Ref},
    receive
        {Ref, Result} -> Result
    after 5000 ->
        {error, timeout}
    end.

%% =============================================================================
%% Handshake
%% =============================================================================

-spec init(pid(), reference(), inet:ip_address() | inet:hostname(), inet:port_number()) -> ok.
init(Parent, Ref, Host, Port) ->
    {ok, Socket} = roadrunner_quic_socket:open(0),
    Dcid0 = crypto:strong_rand_bytes(?CID_LEN),
    Scid = crypto:strong_rand_bytes(?CID_LEN),
    {EphPub, EphPriv} = crypto:generate_key(ecdh, x25519),
    ChFramed = roadrunner_quic_test_client:client_hello_framed(?SIG_SCHEME, EphPub, Scid),
    %% Send the Initial carrying the ClientHello (padded to 1200 by seal/6).
    ClientInitialKeys = roadrunner_quic_keys:initial_client(Dcid0),
    Initial = roadrunner_quic_test_client:seal(
        initial, 0, ClientInitialKeys, [{crypto, 0, ChFramed}], Dcid0, Scid
    ),
    ok = roadrunner_quic_socket:send(Socket, Host, Port, Initial),
    Conn = #conn{
        socket = Socket,
        host = Host,
        port = Port,
        scid = Scid,
        eph_priv = EphPriv,
        ch_framed = ChFramed,
        owner = Parent,
        server_initial_keys = roadrunner_quic_keys:initial_server(Dcid0)
    },
    case handshake(Conn) of
        {ok, Conn1} ->
            %% Switch to active-once so the loop's single receive wakes on
            %% both owner control calls and inbound datagrams; a blocking
            %% socket recv would starve owner calls while the peer is idle.
            ok = roadrunner_quic_socket:activate(Socket),
            Parent ! {Ref, connected},
            connected_loop(Conn1);
        {error, Reason} ->
            _ = roadrunner_quic_socket:close(Socket),
            Parent ! {Ref, {error, Reason}},
            ok
    end.

%% Read one datagram, buffer it, and drive the handshake as far as the
%% buffered datagrams allow, until connected or a timeout.
-spec handshake(#conn{}) -> {ok, #conn{}} | {error, term()}.
handshake(Conn) ->
    case roadrunner_quic_socket:recv(Conn#conn.socket, ?RECV_TIMEOUT) of
        {ok, _Peer, Datagram} ->
            Buffered = Conn#conn{datagrams = Conn#conn.datagrams ++ [Datagram]},
            case advance(learn_server_scid(Buffered)) of
                {connected, Conn1} -> {ok, Conn1};
                {continue, Conn1} -> handshake(Conn1);
                {error, Reason} -> {error, Reason}
            end;
        {error, timeout} ->
            {error, handshake_timeout}
    end.

%% The server addresses its reply to the client's source CID and carries its
%% own SCID in its first long header; capture it for the client's later
%% Handshake and 1-RTT destination CID.
-spec learn_server_scid(#conn{}) -> #conn{}.
learn_server_scid(#conn{server_scid = undefined, datagrams = [First | _]} = Conn) ->
    case roadrunner_quic_packet:long_header_info(First) of
        {ok, #{scid := ServerScid}} -> Conn#conn{server_scid = ServerScid};
        _ -> Conn
    end;
learn_server_scid(Conn) ->
    Conn.

-spec advance(#conn{}) -> {continue | connected, #conn{}} | {error, term()}.
advance(#conn{finished_sent = false, hs_keys = undefined} = Conn) ->
    %% Need the ServerHello to derive the handshake keys.
    case server_hello(Conn) of
        incomplete ->
            {continue, Conn};
        {ok, ServerHelloFramed} ->
            HsKeys = roadrunner_quic_test_handshake:handshake_keys(
                #{eph_priv => Conn#conn.eph_priv, client_hello_framed => Conn#conn.ch_framed},
                ServerHelloFramed
            ),
            %% A Handshake-level packet from the client validates its address and
            %% lifts the server's 3x anti-amplification limit (RFC 9000 §8.1), so
            %% the server flushes the rest of its flight. Send a PING now, before
            %% the whole flight is in hand: a larger flight (e.g. a cert chain)
            %% exceeds the 3x budget, and the server stalls without it.
            #{client := ClientHsKeys} = HsKeys,
            Conn1 = send_handshake_ping(Conn#conn{hs_keys = HsKeys}, ClientHsKeys),
            advance(Conn1)
    end;
advance(#conn{finished_sent = false} = Conn) ->
    %% Have the handshake keys; try to complete the server flight.
    case server_flight(Conn) of
        incomplete -> {continue, Conn};
        {ok, ServerHelloFramed, HandshakeBytes} -> complete(Conn, ServerHelloFramed, HandshakeBytes)
    end;
advance(#conn{finished_sent = true} = Conn) ->
    %% Finished sent; the server's HANDSHAKE_DONE confirms the handshake.
    case handshake_done_received(Conn) of
        true -> {connected, Conn};
        false -> {continue, Conn}
    end.

%% The contiguous Initial CRYPTO bytes, once they hold a complete ServerHello.
-spec server_hello(#conn{}) -> {ok, binary()} | incomplete.
server_hello(#conn{datagrams = Datagrams, server_initial_keys = Keys}) ->
    Bytes = roadrunner_quic_test_client:crypto_bytes(
        Datagrams, initial, #{initial => Keys}, ?CID_LEN
    ),
    case deframe_complete(Bytes) of
        {complete, [{2, _} | _]} -> {ok, Bytes};
        _ -> incomplete
    end.

%% The Initial ServerHello and the Handshake-level flight, once both reassemble
%% completely (the flight ends with the server Finished).
-spec server_flight(#conn{}) -> {ok, binary(), binary()} | incomplete.
server_flight(#conn{datagrams = Datagrams, server_initial_keys = SIK, hs_keys = #{server := SHK}}) ->
    ShBytes = roadrunner_quic_test_client:crypto_bytes(
        Datagrams, initial, #{initial => SIK}, ?CID_LEN
    ),
    HsBytes = roadrunner_quic_test_client:crypto_bytes(
        Datagrams, handshake, #{handshake => SHK}, ?CID_LEN
    ),
    case {deframe_complete(ShBytes), deframe_complete(HsBytes)} of
        {{complete, [{2, _} | _]}, {complete, Messages}} ->
            case lists:keymember(?FINISHED, 1, Messages) of
                true -> {ok, ShBytes, HsBytes};
                false -> incomplete
            end;
        _ ->
            incomplete
    end.

%% Drive the handshake to its end: verify the flight, send the client
%% Finished, and arm the application keys for HANDSHAKE_DONE.
-spec complete(#conn{}, binary(), binary()) -> {continue, #conn{}} | {error, term()}.
complete(Conn, ServerHelloFramed, HandshakeBytes) ->
    Config = #{
        eph_priv => Conn#conn.eph_priv,
        client_hello_framed => Conn#conn.ch_framed,
        server_pubkey => server_public_key(HandshakeBytes)
    },
    Flight = #{initial => ServerHelloFramed, handshake => HandshakeBytes},
    case roadrunner_quic_test_handshake:process_server_flight(Config, Flight) of
        {ok, #{installs := Installs, client_finished := ClientFinished}} ->
            Conn1 = send_client_finished(
                Conn, keys_for(handshake, client, Installs), ClientFinished
            ),
            {continue, Conn1#conn{
                finished_sent = true,
                app_server_keys = keys_for(application, server, Installs),
                app_client_keys = keys_for(application, client, Installs)
            }};
        {error, Reason} ->
            {error, Reason}
    end.

%% Send a bare Handshake-level PING to validate the client's address, lifting
%% the server's 3x anti-amplification limit (RFC 9000 §8.1) so it flushes the
%% rest of its flight.
-spec send_handshake_ping(#conn{}, roadrunner_quic_keys:keys()) -> #conn{}.
send_handshake_ping(Conn, ClientHsKeys) ->
    send_handshake(Conn, ClientHsKeys, [ping]).

%% Send the client Finished as a Handshake-level CRYPTO frame, addressed to
%% the server's SCID.
-spec send_client_finished(#conn{}, roadrunner_quic_keys:keys(), iolist()) -> #conn{}.
send_client_finished(Conn, ClientHsKeys, ClientFinished) ->
    send_handshake(Conn, ClientHsKeys, [{crypto, 0, iolist_to_binary(ClientFinished)}]).

%% Send a Handshake-level datagram carrying `Frames`, addressed to the server's
%% SCID, taking the next handshake packet number so each packet is distinct.
-spec send_handshake(#conn{}, roadrunner_quic_keys:keys(), [roadrunner_quic_frame:frame()]) ->
    #conn{}.
send_handshake(
    #conn{
        socket = Socket,
        host = Host,
        port = Port,
        scid = Scid,
        server_scid = ServerScid,
        hs_pn = Pn
    } = Conn,
    ClientHsKeys,
    Frames
) ->
    {Datagram, _Sent} = roadrunner_quic_send:datagram(
        #{handshake => #{frames => Frames, keys => ClientHsKeys, pn => Pn}}, ServerScid, Scid
    ),
    ok = roadrunner_quic_socket:send(Socket, Host, Port, Datagram),
    Conn#conn{hs_pn = Pn + 1}.

%% Whether the server's 1-RTT packets carry HANDSHAKE_DONE (RFC 9001 §4.1.2).
%% Short-header packets are addressed to the client's source CID.
-spec handshake_done_received(#conn{}) -> boolean().
handshake_done_received(#conn{datagrams = Datagrams, app_server_keys = AppKeys, scid = Scid}) ->
    Frames = roadrunner_quic_test_client:frames(
        Datagrams, application, #{application => AppKeys}, byte_size(Scid)
    ),
    lists:member(handshake_done, Frames).

%% The server's public key, from the leaf certificate in the flight, to verify
%% CertificateVerify.
-spec server_public_key(binary()) -> public_key:public_key().
server_public_key(HandshakeBytes) ->
    {complete, Messages} = deframe_complete(HandshakeBytes),
    {?CERTIFICATE, CertBody} = lists:keyfind(?CERTIFICATE, 1, Messages),
    [LeafDer | _] = roadrunner_quic_test_client:parse_certificate(CertBody),
    OtpCert = public_key:pkix_decode_cert(LeafDer, otp),
    Tbs = OtpCert#'OTPCertificate'.tbsCertificate,
    Spki = Tbs#'OTPTBSCertificate'.subjectPublicKeyInfo,
    Spki#'OTPSubjectPublicKeyInfo'.subjectPublicKey.

%% =============================================================================
%% Connected
%% =============================================================================

%% The 1-RTT loop: serve the owner's stream control calls and process the
%% server's 1-RTT datagrams, delivering received stream data to the owner.
%% The socket is active-once, so both owner calls and inbound datagrams
%% arrive as mailbox messages and a single receive handles both without a
%% blocking socket read that would delay owner calls while the peer is idle.
-spec connected_loop(#conn{}) -> ok.
connected_loop(#conn{socket = Socket} = Conn) ->
    receive
        {open_bidi, From, Ref} ->
            Id = Conn#conn.next_bidi,
            From ! {Ref, Id},
            connected_loop(Conn#conn{next_bidi = Id + 4});
        {open_uni, From, Ref} ->
            Id = Conn#conn.next_uni,
            From ! {Ref, Id},
            connected_loop(Conn#conn{next_uni = Id + 4});
        {send, From, Ref, StreamId, Data, Fin} ->
            Conn1 = send_stream(Conn, StreamId, Data, Fin),
            From ! {Ref, ok},
            connected_loop(Conn1);
        {frame, From, Ref, Frame} ->
            Conn1 = send_frame(Conn, Frame),
            From ! {Ref, ok},
            connected_loop(Conn1);
        stop ->
            %% RFC 9000 §10.2: send an application CONNECTION_CLOSE so the
            %% server tears the connection down promptly (its owner loop
            %% observes the close) instead of waiting out the idle timeout.
            _ = send_wire_frame(Conn, {connection_close, application, 0, 0, <<>>}),
            _ = roadrunner_quic_socket:close(Socket),
            ok;
        Message ->
            case roadrunner_quic_socket:from_message(Socket, Message) of
                {ok, _Peer, Datagram} ->
                    %% Re-arm before processing so the next datagram is already
                    %% queued while we work (1-RTT packets keep arriving).
                    ok = roadrunner_quic_socket:activate(Socket),
                    connected_loop(handle_app_datagram(Conn, Datagram));
                ignore ->
                    connected_loop(Conn)
            end
    end.

%% Send stream data, splitting it across 1-RTT packets so each datagram stays
%% within the MTU; the FIN rides the last chunk.
-spec send_stream(#conn{}, non_neg_integer(), iodata(), boolean()) -> #conn{}.
send_stream(Conn, StreamId, Data, Fin) ->
    send_stream_bin(Conn, StreamId, iolist_to_binary(Data), Fin).

-spec send_stream_bin(#conn{}, non_neg_integer(), binary(), boolean()) -> #conn{}.
send_stream_bin(Conn, StreamId, Bin, Fin) when byte_size(Bin) =< ?MAX_STREAM_CHUNK ->
    send_stream_packet(Conn, StreamId, Bin, Fin);
send_stream_bin(Conn, StreamId, Bin, Fin) ->
    <<Chunk:(?MAX_STREAM_CHUNK)/binary, Rest/binary>> = Bin,
    send_stream_bin(send_stream_packet(Conn, StreamId, Chunk, false), StreamId, Rest, Fin).

%% One STREAM frame on a 1-RTT (short-header) packet addressed to the server's
%% CID, tracking the per-stream offset and the 1-RTT packet number.
-spec send_stream_packet(#conn{}, non_neg_integer(), binary(), boolean()) -> #conn{}.
send_stream_packet(
    #conn{
        socket = Socket,
        host = Host,
        port = Port,
        scid = Scid,
        server_scid = ServerScid,
        app_client_keys = Keys,
        send_pn = Pn,
        send_offsets = Offsets
    } = Conn,
    StreamId,
    Chunk,
    Fin
) ->
    Offset = maps:get(StreamId, Offsets, 0),
    Frame = {stream, StreamId, Offset, Chunk, Fin},
    {Datagram, _Sent} = roadrunner_quic_send:datagram(
        #{application => #{frames => [Frame], keys => Keys, pn => Pn}}, ServerScid, Scid
    ),
    _ = roadrunner_quic_socket:send(Socket, Host, Port, Datagram),
    Conn#conn{send_pn = Pn + 1, send_offsets = Offsets#{StreamId => Offset + byte_size(Chunk)}}.

%% Send a single non-STREAM frame (RESET_STREAM, STOP_SENDING) on a 1-RTT
%% packet. A RESET_STREAM marker (no final size) is resolved here against the
%% bytes already sent on the stream, since a final size below the largest sent
%% offset is a FINAL_SIZE_ERROR (RFC 9000 §4.5).
-spec send_frame(
    #conn{}, {reset_stream, non_neg_integer(), non_neg_integer()} | roadrunner_quic_frame:frame()
) -> #conn{}.
send_frame(#conn{send_offsets = Offsets} = Conn, {reset_stream, StreamId, ErrorCode}) ->
    FinalSize = maps:get(StreamId, Offsets, 0),
    send_wire_frame(Conn, {reset_stream, StreamId, ErrorCode, FinalSize});
send_frame(Conn, Frame) ->
    send_wire_frame(Conn, Frame).

-spec send_wire_frame(#conn{}, roadrunner_quic_frame:frame()) -> #conn{}.
send_wire_frame(
    #conn{
        socket = Socket,
        host = Host,
        port = Port,
        scid = Scid,
        server_scid = ServerScid,
        app_client_keys = Keys,
        send_pn = Pn
    } = Conn,
    Frame
) ->
    {Datagram, _Sent} = roadrunner_quic_send:datagram(
        #{application => #{frames => [Frame], keys => Keys, pn => Pn}}, ServerScid, Scid
    ),
    _ = roadrunner_quic_socket:send(Socket, Host, Port, Datagram),
    Conn#conn{send_pn = Pn + 1}.

%% Decrypt a 1-RTT datagram and route its STREAM frames through per-stream
%% reassembly, delivering deliverable bytes to the owner.
-spec handle_app_datagram(#conn{}, binary()) -> #conn{}.
handle_app_datagram(#conn{app_server_keys = Keys, scid = Scid} = Conn, Datagram) ->
    Outcomes = roadrunner_quic_recv:datagram(
        Datagram, byte_size(Scid), #{application => Keys}, #{}
    ),
    Frames = lists:append([Fs || {ok, #{level := application, frames := Fs}} <- Outcomes]),
    lists:foldl(fun handle_app_frame/2, Conn, Frames).

-spec handle_app_frame(roadrunner_quic_frame:frame(), #conn{}) -> #conn{}.
handle_app_frame({stream, StreamId, Offset, Data, Fin}, Conn) ->
    deliver_stream(Conn, StreamId, Offset, Data, Fin);
handle_app_frame({reset_stream, StreamId, ErrorCode, _FinalSize}, #conn{owner = Owner} = Conn) ->
    _ = Owner ! {quic_test_stream_reset, self(), StreamId, ErrorCode},
    Conn;
handle_app_frame({connection_close, _Domain, ErrorCode, _FrameType, _Reason}, Conn) ->
    _ = Conn#conn.owner ! {quic_test_closed, self(), ErrorCode},
    Conn;
handle_app_frame(_Other, Conn) ->
    Conn.

-spec deliver_stream(#conn{}, non_neg_integer(), non_neg_integer(), binary(), boolean()) -> #conn{}.
deliver_stream(#conn{recv_streams = Streams, owner = Owner} = Conn, StreamId, Offset, Data, Fin) ->
    Stream0 = maps:get(StreamId, Streams, roadrunner_quic_stream:new()),
    case roadrunner_quic_stream:receive_data(Offset, Data, Fin, Stream0) of
        {ok, Deliverable, FinReached, Stream1} ->
            maybe_deliver(Owner, StreamId, Deliverable, FinReached),
            Conn#conn{recv_streams = Streams#{StreamId => Stream1}};
        {error, _Reason} ->
            Conn
    end.

%% Deliver new contiguous bytes (or a bare FIN) to the owner; a gap that
%% produced nothing new and no FIN is silent.
-spec maybe_deliver(pid(), non_neg_integer(), binary(), boolean()) -> ok.
maybe_deliver(_Owner, _StreamId, <<>>, false) ->
    ok;
maybe_deliver(Owner, StreamId, Deliverable, FinReached) ->
    _ = Owner ! {quic_test_stream, self(), StreamId, Deliverable, FinReached},
    ok.

%% =============================================================================
%% Internal
%% =============================================================================

%% Deframe as many complete handshake messages as the bytes hold; report
%% whether the buffer ends on a message boundary (`complete`) or needs more.
-spec deframe_complete(binary()) -> {complete | incomplete, [{byte(), binary()}]}.
deframe_complete(Bytes) ->
    deframe_complete(Bytes, []).

deframe_complete(<<>>, Acc) ->
    {complete, lists:reverse(Acc)};
deframe_complete(Bytes, Acc) ->
    case roadrunner_quic_tls_handshake:decode(Bytes) of
        {ok, {Type, Body}, Rest} -> deframe_complete(Rest, [{Type, Body} | Acc]);
        {more, _} -> {incomplete, lists:reverse(Acc)}
    end.

-spec keys_for(
    handshake | application,
    server | client,
    [roadrunner_quic_test_handshake:install()]
) -> roadrunner_quic_keys:keys().
keys_for(Level, Role, Installs) ->
    [Keys] = [K || {L, R, K} <- Installs, L =:= Level, R =:= Role],
    Keys.
