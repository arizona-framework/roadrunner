-module(roadrunner_http2_stream_response).
-moduledoc false.

%% HTTP/2 `{stream, ...}` response — body delivered as one or more
%% DATA frames, with optional trailers as a closing HEADERS frame.
%%
%% Mirrors `roadrunner_stream_response` so the handler-facing
%% `Send/2` API stays protocol-agnostic. Translation table:
%%
%% | `Send(Data, FinFlag)` | h1 wire | h2 wire |
%% |---|---|---|
%% | `Send(Data, nofin)` | one chunk | DATA, no END_STREAM |
%% | `Send(Data, fin)` | chunk + `0\\r\\n\\r\\n` | DATA + END_STREAM |
%% | `Send(Data, {fin, Trailers})` | chunk + `0` + trailers | DATA + HEADERS + END_STREAM |
%%
%% Empty data is special-cased to match the h1 behavior:
%% - `Send(<<>>, nofin)` is a no-op (no zero-length DATA frame).
%% - `Send(<<>>, fin)` emits an empty DATA frame with END_STREAM.
%% - `Send(<<>>, {fin, Trailers})` emits the trailer HEADERS frame
%%   (with END_STREAM) and no DATA.
%%
%% The `Send` callback runs in the worker process and synchronously
%% round-trips with the conn process for each emission — `Send`
%% returns only after the conn has written the corresponding frame
%% on the wire (or queued it pending a `WINDOW_UPDATE`). This
%% threads natural backpressure: a slow consumer stalls the worker
%% without us having to explicitly buffer.
%%
%% If the handler returns without calling `Send(_, fin)` /
%% `{fin, _}` we auto-close the stream with an empty `END_STREAM`
%% DATA frame so the peer doesn't see a half-open stream.

-export([run/5]).

%% Process-dict flag: set once Send observed a fin variant. Lives
%% in the WORKER's process dict (not the conn's), so isolation
%% across streams is automatic.
-define(FIN_KEY, '$roadrunner_http2_stream_fin').

-doc """
Send the response HEADERS (no `END_STREAM`) to the conn process,
invoke the user's stream fun with a `Send/2` callback, and ensure
the stream is closed by the time we return. Runs in the worker
process; every frame is synchronously round-tripped through the
conn (which owns HPACK encoder state and serialises wire writes).
""".
-spec run(
    pid(),
    pos_integer(),
    roadrunner_http:status(),
    roadrunner_http:headers(),
    roadrunner_handler:stream_fun()
) -> ok.
run(ConnPid, StreamId, Status, Headers, Fun) ->
    %% Every frame below waits on the conn's ack: monitor it so a dead conn
    %% wakes the worker instead of leaving it blocked.
    _ = roadrunner_http2_worker_sync:monitor_conn(ConnPid),
    ok = roadrunner_http2_worker_sync:send_headers(ConnPid, StreamId, Status, Headers, false),
    erase(?FIN_KEY),
    Send = fun(Data, FinFlag) -> do_send(ConnPid, StreamId, Data, FinFlag) end,
    _ = Fun(Send),
    erase(?FIN_KEY) =:= true orelse do_send(ConnPid, StreamId, <<>>, fin),
    ok.

do_send(ConnPid, StreamId, Data, nofin) ->
    %% Ship as iodata. The conn fast-paths single-frame sends
    %% without materialising and only flattens when chunking
    %% across window/MAX_FRAME_SIZE boundaries.
    send_nonempty(ConnPid, StreamId, Data);
do_send(ConnPid, StreamId, Data, fin) ->
    ok = roadrunner_http2_worker_sync:send_data(ConnPid, StreamId, Data, iolist_size(Data), true),
    put(?FIN_KEY, true),
    ok;
do_send(ConnPid, StreamId, Data, {fin, Trailers}) ->
    %% Trailers go out after the status, so an injected one cannot become
    %% a 500. One pass crashes on the RFC 9110 §5.5 CR/LF/NUL check here in
    %% the worker (so the conn resets just this stream and the malformed
    %% bytes never reach the client) and strips the connection-specific
    %% fields RFC 9113 §8.2.2 forbids. Run it before any of the body goes
    %% out.
    WireTrailers = roadrunner_http:strip_connection_specific_fields_safe(Trailers),
    ok = send_nonempty(ConnPid, StreamId, Data),
    ok = sync_send_trailers(ConnPid, StreamId, WireTrailers),
    put(?FIN_KEY, true),
    ok.

%% DATA without END_STREAM, skipped when empty (no zero-length frame).
send_nonempty(ConnPid, StreamId, Data) ->
    case iolist_size(Data) of
        0 -> ok;
        Size -> roadrunner_http2_worker_sync:send_data(ConnPid, StreamId, Data, Size, false)
    end.

sync_send_trailers(ConnPid, StreamId, Trailers) ->
    roadrunner_http2_worker_sync:sync(ConnPid, fun(Ref) ->
        _ = (ConnPid ! {h2_send_trailers, self(), Ref, StreamId, Trailers}),
        ok
    end).
