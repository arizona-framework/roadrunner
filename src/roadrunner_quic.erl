-module(roadrunner_quic).
-moduledoc false.

%% The control API the HTTP/3 layer (`roadrunner_conn_loop_http3`,
%% `roadrunner_http3_stream_worker`) calls on a native QUIC connection: the
%% same surface the dep's `quic` module gave, so the h3 files change only the
%% `quic:*` -> `roadrunner_quic:*` qualifier.
%%
%% The native connection is a hand-rolled `proc_lib` loop, not a gen_statem, so
%% this module replicates `gen_statem:call` semantics itself: a `make_ref`
%% tagged round-trip with a temporary monitor. A control request goes as
%% `{quic_call, self(), Ref, Request}` and a stream write as `{quic_send,
%% self(), Ref, Sid, IoData, Fin}`; both are answered by the connection with
%% `{quic_reply, Ref, Result}`. The connection only ever sends to its owner
%% asynchronously (`{quic, Conn, Event}`), so these synchronous calls never
%% deadlock: the call tree is one-directional (owner/worker -> connection).
%%
%% A connection that dies before replying exits the caller with
%% `{quic_conn_down, Reason}`, the same shape `gen_statem:call` gives for a
%% dead callee (the owner is linked to the connection and tearing down anyway).

-export([
    peername/1,
    open_unidirectional_stream/1,
    send_data/4,
    reset_stream/3,
    stop_sending/3,
    close/2,
    close/3
]).

-doc "The connection's peer address. Answers in the handshaking phase, before connected.".
-spec peername(pid()) -> {ok, {inet:ip_address(), inet:port_number()}}.
peername(Conn) ->
    call(Conn, peername).

-doc "Allocate a server-initiated unidirectional stream id (the h3 control/encoder/decoder streams).".
-spec open_unidirectional_stream(pid()) -> {ok, non_neg_integer()}.
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

-doc "Abort the send side of a stream with a RESET_STREAM carrying the h3 error code.".
-spec reset_stream(pid(), non_neg_integer(), non_neg_integer()) -> ok.
reset_stream(Conn, StreamId, ErrorCode) ->
    call(Conn, {reset_stream, StreamId, ErrorCode}).

-doc "Ask the peer to stop sending on a stream with a STOP_SENDING carrying the h3 error code.".
-spec stop_sending(pid(), non_neg_integer(), non_neg_integer()) -> ok.
stop_sending(Conn, StreamId, ErrorCode) ->
    call(Conn, {stop_sending, StreamId, ErrorCode}).

-doc "Close the connection with an h3 error code (an application CONNECTION_CLOSE, no reason phrase).".
-spec close(pid(), non_neg_integer()) -> ok.
close(Conn, ErrorCode) ->
    call(Conn, {close, ErrorCode}).

-doc "Close the connection with an h3 error code and a reason phrase.".
-spec close(pid(), non_neg_integer(), binary()) -> ok.
close(Conn, ErrorCode, Reason) ->
    call(Conn, {close, ErrorCode, Reason}).

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
