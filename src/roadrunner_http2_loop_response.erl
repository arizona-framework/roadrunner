-module(roadrunner_http2_loop_response).
-moduledoc false.

%% HTTP/2 `{loop, _}` response: message-driven streaming over h2 DATA frames.
%%
%% Mirrors `roadrunner_loop_response` (the h1 path) but runs in the
%% per-stream worker process and emits DATA frames via the conn's
%% `{h2_send_data, ...}` message protocol. Same mailbox contract as
%% h1: a handler's `self() ! Msg` and `register/2` calls from
%% `handle/1` work because the worker IS the dispatch process. OTP
%% shapes (`{system, _, _}`, `{'$gen_call', _, _}`, `{'$gen_cast', _}`)
%% are silently dropped via dedicated receive clauses; we're a plain
%% spawn, not a `gen_*`, so `gen_server:call/2,3` against the worker
%% will time out instead of surfacing in `handle_info/3`.
%%
%% On `{stop, _NewState}` the worker emits an empty DATA frame with
%% END_STREAM and returns; the conn cleans up the stream slot via the
%% worker's `'DOWN'` signal.

-export([run/5]).

-doc """
Send the response HEADERS, then enter the message-receive loop.
Returns when the handler's `handle_info/3` returns `{stop, _}`.
""".
-spec run(
    pid(),
    pos_integer(),
    roadrunner_http:status(),
    roadrunner_http:headers(),
    {module(), term()}
) -> ok.
run(ConnPid, StreamId, Status, Headers, {Handler, State}) ->
    sync_send_headers(ConnPid, StreamId, Status, Headers, false),
    %% The worker already monitors the conn (see
    %% `roadrunner_http2_stream_worker:init/4`), so an idle `info_loop`
    %% blocked waiting for a message wakes on the conn's `DOWN` instead
    %% of leaking once the conn is gone.
    Push = make_push(ConnPid, StreamId),
    info_loop(ConnPid, StreamId, Handler, Push, State).

-spec info_loop(
    pid(), pos_integer(), module(), roadrunner_handler:push_fun(), term()
) -> ok.
info_loop(ConnPid, StreamId, Handler, Push, State) ->
    receive
        {'DOWN', _MonRef, process, ConnPid, _Reason} ->
            %% Connection gone — stop looping.
            ok;
        {h2_stream_reset, StreamId} ->
            %% The conn reset this stream (peer RST_STREAM, or a
            %% protocol violation on the conn side) and already dropped
            %% it. Stop looping rather than forwarding the reset to the
            %% handler's `handle_info/3` as if it were application data.
            ok;
        {system, _, _} ->
            info_loop(ConnPid, StreamId, Handler, Push, State);
        {'$gen_call', _, _} ->
            info_loop(ConnPid, StreamId, Handler, Push, State);
        {'$gen_cast', _} ->
            info_loop(ConnPid, StreamId, Handler, Push, State);
        Info ->
            case Handler:handle_info(Info, Push, State) of
                {ok, NewState} ->
                    info_loop(ConnPid, StreamId, Handler, Push, NewState);
                {stop, _NewState} ->
                    sync_send_data(ConnPid, StreamId, <<>>, true),
                    ok
            end
    end.

%% Push fun handed to the user handler. Empty data is a no-op: an
%% empty DATA frame would be legal on the wire but doesn't advance
%% the response, and matching h1's behaviour (which skips empty
%% chunks to avoid emitting the chunked terminator prematurely)
%% keeps the two paths symmetric. Non-empty pushes ship as iodata;
%% the conn fast-paths single-frame sends without materialising and
%% only flattens when chunking across window/MAX_FRAME_SIZE.
-spec make_push(pid(), pos_integer()) -> roadrunner_handler:push_fun().
make_push(ConnPid, StreamId) ->
    fun(Data) ->
        case iolist_size(Data) of
            0 ->
                ok;
            _ ->
                sync_send_data(ConnPid, StreamId, Data, false),
                ok
        end
    end.

%% Sync helpers: send a frame request to the conn and block on its ack
%% via the shared `roadrunner_http2_worker_sync`.

-spec sync_send_headers(
    pid(),
    pos_integer(),
    roadrunner_http:status(),
    roadrunner_http:headers(),
    boolean()
) -> ok.
sync_send_headers(ConnPid, StreamId, Status, Headers, EndStream) ->
    roadrunner_http2_worker_sync:sync(ConnPid, fun(Ref) ->
        _ =
            (ConnPid !
                {h2_send_headers, self(), Ref, StreamId, Status, Headers, EndStream}),
        ok
    end).

-spec sync_send_data(pid(), pos_integer(), iodata(), boolean()) -> ok.
sync_send_data(ConnPid, StreamId, Data, EndStream) ->
    roadrunner_http2_worker_sync:sync(ConnPid, fun(Ref) ->
        _ =
            (ConnPid !
                {h2_send_data, self(), Ref, StreamId, Data, EndStream}),
        ok
    end).
