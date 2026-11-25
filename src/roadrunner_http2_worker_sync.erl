-module(roadrunner_http2_worker_sync).
-moduledoc false.

%% Worker -> conn synchronous frame round-trip, shared by the h2 stream /
%% loop response emitters (a buffered response goes one way, see
%% `roadrunner_http2_stream_worker:send_buffered/5`).
%% `sync/2` sends a frame request to the conn (via `SendFun`, handed the
%% write's `Ref`) and blocks for the conn's answer to that write, given
%% once on every path while the conn lives: `{h2_send_ack, Ref}` once it
%% is on the wire, or `{h2_send_reset, Ref, StreamId, Why}` when the
%% stream is reset first (or was already gone). The reset the conn tells
%% the worker itself (`{h2_stream_reset, _, Why}`) ends the wait too. A
%% reset exits the worker with `stream_reset`, the reset put back in the
%% mailbox as `{h2_stream_reset, StreamId, Why}` for the code the exit
%% unwinds to learn why (`roadrunner_grpc` reports a call the server cut).
%%
%% `monitor_conn/1` is called once per worker by the stream / loop
%% emitters, before their first sync (a buffered response never waits on
%% the conn, so it skips the monitor), so a `sync/2` blocked on an ack also
%% wakes if the conn process dies. The
%% ack never arrives once the conn is gone, so without the monitor the
%% worker would block until the conn's TCP teardown reaped it; the
%% monitor turns that into a prompt `conn_down` exit. The worker is
%% monitored (not linked) by the conn, so on a conn crash it is
%% otherwise orphaned with no signal of its own.

-export([monitor_conn/1, sync/2, send_headers/5, send_data/5]).

-doc false.
-spec monitor_conn(pid()) -> reference().
monitor_conn(ConnPid) ->
    monitor(process, ConnPid).

-doc false.
-spec sync(pid(), fun((reference()) -> ok)) -> ok.
sync(ConnPid, SendFun) ->
    Ref = make_ref(),
    ok = SendFun(Ref),
    receive
        {h2_send_ack, Ref} ->
            ok;
        {h2_send_reset, Ref, StreamId, Why} ->
            _ = (self() ! {h2_stream_reset, StreamId, Why}),
            exit(stream_reset);
        {h2_stream_reset, _StreamId, _Why} = Reset ->
            _ = (self() ! Reset),
            exit(stream_reset);
        {'DOWN', _MonRef, process, ConnPid, _Reason} ->
            exit(conn_down)
    end.

%% Send a HEADERS frame for `StreamId` and wait for the conn's ack.
-doc false.
-spec send_headers(
    pid(), pos_integer(), roadrunner_http:status(), roadrunner_http:headers(), boolean()
) -> ok.
send_headers(ConnPid, StreamId, Status, Headers, EndStream) ->
    sync(ConnPid, fun(Ref) ->
        _ = (ConnPid ! {h2_send_headers, self(), Ref, StreamId, Status, Headers, EndStream}),
        ok
    end).

%% Send DATA for `StreamId` and wait for the conn's ack. `Size` is
%% `iolist_size(Data)`, taken by the caller in this worker: a handler's
%% non-iodata `Data` crashes the worker there, so the conn resets just
%% this stream instead of crashing on it with every stream it carries,
%% and the conn reads the size instead of walking the data again.
-doc false.
-spec send_data(pid(), pos_integer(), iodata(), non_neg_integer(), boolean()) -> ok.
send_data(ConnPid, StreamId, Data, Size, EndStream) ->
    sync(ConnPid, fun(Ref) ->
        _ = (ConnPid ! {h2_send_data, self(), Ref, StreamId, Data, Size, EndStream}),
        ok
    end).
