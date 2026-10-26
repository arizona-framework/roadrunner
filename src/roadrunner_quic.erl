-module(roadrunner_quic).
-moduledoc false.

%% The control API the HTTP/3 layer (`roadrunner_conn_loop_http3`,
%% `roadrunner_http3_stream_worker`) calls on a native QUIC connection.
%%
%% The native connection is a hand-rolled `proc_lib` loop, not a gen_statem, so
%% this module replicates `gen_statem:call` semantics itself: a `make_ref`
%% tagged round-trip with a temporary monitor. A control request goes as
%% `{quic_call, self(), Ref, Request}` and a stream write as `{quic_send,
%% self(), Ref, Sid, IoData, Fin}`; both are answered by the connection with
%% `{quic_reply, Ref, Result}`. A stream's final write can go one way instead
%% (`{quic_send_final, Sid, IoData}`, never answered). The connection only
%% ever sends to its owner asynchronously (`{quic, Conn, Event}`), so these
%% synchronous calls never deadlock: the call tree is one-directional
%% (owner/worker -> connection).
%%
%% A connection that dies before replying exits the caller with
%% `{quic_conn_down, Reason}`, the same shape `gen_statem:call` gives for a
%% dead callee (the owner is linked to the connection and tearing down anyway).

-export([
    peername/1,
    sockname/1,
    tls_info/1,
    open_unidirectional_stream/1,
    send_data/4,
    send_final/3,
    reset_stream/3,
    stop_sending/3,
    consumed/3,
    close/2,
    close/3,
    close_when_done/3
]).

-doc "The connection's peer address. Answers in the handshaking phase, before connected.".
-spec peername(pid()) -> {ok, {inet:ip_address(), inet:port_number()}}.
peername(Conn) ->
    call(Conn, peername).

-doc "The connection's local address: the listener socket's address and port.".
-spec sockname(pid()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
sockname(Conn) ->
    call(Conn, sockname).

-doc """
The connection's TLS session, in the shape of `ssl:connection_information/1`:
`protocol` (always TLS 1.3, RFC 9001 §4.2) and `selected_cipher_suite`.
""".
-spec tls_info(pid()) -> {ok, ssl:connection_info()}.
tls_info(Conn) ->
    call(Conn, tls_info).

-doc """
Allocate a server-initiated unidirectional stream id (the h3 control/encoder/decoder
streams). `{error, stream_limit}` when the peer's stream limit allows no more
(RFC 9000 §4.6); the connection then signals STREAMS_BLOCKED to the peer.
""".
-spec open_unidirectional_stream(pid()) -> {ok, non_neg_integer()} | {error, stream_limit}.
open_unidirectional_stream(Conn) ->
    call(Conn, open_uni).

-doc """
Write stream data (an iolist of h3 frames), optionally finishing the stream.
Returns once the connection has accepted it, the synchronous point that gives
the stream worker flow-control back-pressure.
""".
-spec send_data(pid(), non_neg_integer(), iodata(), boolean()) -> ok | {error, term()}.
send_data(Conn, StreamId, IoData, Fin) ->
    Ref = make_ref(),
    Mon = monitor(process, Conn),
    _ = Conn ! {quic_send, self(), Ref, StreamId, IoData, Fin},
    await(Conn, Ref, Mon).

-doc """
Write a stream's last data (an iolist of h3 frames) and finish it, one way:
nothing is answered, so the writer neither waits for the connection nor
gets back-pressure. For a writer with nothing left to send on the stream
(a buffered response); the connection sends the bytes as flow control
allows. A graceful close waits for them (`close_when_done/3`).
""".
-spec send_final(pid(), non_neg_integer(), iodata()) -> ok.
send_final(Conn, StreamId, IoData) ->
    _ = Conn ! {quic_send_final, StreamId, IoData},
    ok.

-doc "Abort the send side of a stream with a RESET_STREAM carrying the h3 error code.".
-spec reset_stream(pid(), non_neg_integer(), non_neg_integer()) -> ok.
reset_stream(Conn, StreamId, ErrorCode) ->
    call(Conn, {reset_stream, StreamId, ErrorCode}).

-doc "Ask the peer to stop sending on a stream with a STOP_SENDING carrying the h3 error code.".
-spec stop_sending(pid(), non_neg_integer(), non_neg_integer()) -> ok.
stop_sending(Conn, StreamId, ErrorCode) ->
    call(Conn, {stop_sending, StreamId, ErrorCode}).

-doc """
Report `Bytes` of a request stream consumed, on a connection whose request
streams grant their credit as it is read (`stream_credit => on_read`): the
connection grants the peer more once enough of the stream's window is read.
Asynchronous, so the reader never waits on it.
""".
-spec consumed(pid(), non_neg_integer(), non_neg_integer()) -> ok.
consumed(Conn, StreamId, Bytes) ->
    _ = Conn ! {quic_consumed, StreamId, Bytes},
    ok.

-doc "Close the connection with an h3 error code (an application CONNECTION_CLOSE, no reason phrase).".
-spec close(pid(), non_neg_integer()) -> ok.
close(Conn, ErrorCode) ->
    call(Conn, {close, ErrorCode}).

-doc "Close the connection with an h3 error code and a reason phrase.".
-spec close(pid(), non_neg_integer(), binary()) -> ok.
close(Conn, ErrorCode, Reason) ->
    call(Conn, {close, ErrorCode, Reason}).

-doc """
Close the connection gracefully with an h3 error code and a reason phrase:
the CONNECTION_CLOSE goes out once every response is sent, that is once no
stream holds unsent bytes and every client request stream the peer started
has its FIN on the wire or was reset. The owner then gets `{closed,
drained}`. A connection already closing just answers `ok`.
""".
-spec close_when_done(pid(), non_neg_integer(), binary()) -> ok.
close_when_done(Conn, ErrorCode, Reason) ->
    call(Conn, {close_when_done, ErrorCode, Reason}).

%% =============================================================================
%% Internal
%% =============================================================================

-spec call(pid(), term()) -> term().
call(Conn, Request) ->
    Ref = make_ref(),
    Mon = monitor(process, Conn),
    _ = Conn ! {quic_call, self(), Ref, Request},
    await(Conn, Ref, Mon).

%% Wait for the connection's reply, or exit if it dies first (matching
%% gen_statem:call against a dead callee).
-spec await(pid(), reference(), reference()) -> term().
await(Conn, Ref, Mon) ->
    receive
        {quic_reply, Ref, Result} ->
            _ = demonitor(Mon, [flush]),
            Result;
        {'DOWN', Mon, process, Conn, Reason} ->
            exit({quic_conn_down, Reason})
    end.
