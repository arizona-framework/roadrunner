-module(roadrunner_http2_worker_sync).
-moduledoc false.

%% Worker -> conn synchronous frame round-trip, shared by the h2 stream
%% worker (buffered responses) and the stream / loop response emitters.
%% `sync/2` sends a frame request to the conn (via `SendFun`) and blocks
%% for the conn's `{h2_send_ack, Ref}`; a conn-side stream reset
%% (`{h2_stream_reset, _}`) exits the worker with `stream_reset`.
%%
%% `monitor_conn/1` is called once per worker, before the first sync, so
%% a `sync/2` blocked on an ack also wakes if the conn process dies. The
%% ack never arrives once the conn is gone, so without the monitor the
%% worker would block until the conn's TCP teardown reaped it; the
%% monitor turns that into a prompt `conn_down` exit. The worker is
%% monitored (not linked) by the conn, so on a conn crash it is
%% otherwise orphaned with no signal of its own.

-export([monitor_conn/1, sync/2]).

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
        {h2_send_ack, Ref} -> ok;
        {h2_stream_reset, _StreamId} -> exit(stream_reset);
        {'DOWN', _MonRef, process, ConnPid, _Reason} -> exit(conn_down)
    end.
