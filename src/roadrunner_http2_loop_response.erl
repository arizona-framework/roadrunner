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
%% are answered via `roadrunner_loop_sys` rather than surfacing in
%% `handle_info/3`: `sys:get_state/1` & friends work, and
%% `gen_server:call/2,3` against the worker gets `{error, not_supported}`
%% instead of hanging (see `roadrunner_loop_response` for the full contract).
%%
%% On `{stop, _NewState}` the worker emits an empty DATA frame with
%% END_STREAM and returns; the conn cleans up the stream slot via the
%% worker's `'DOWN'` signal.
%%
%% If the client goes away first, the loop hands the handler one final
%% `{roadrunner_disconnect, Reason}` through `handle_info/3` (its chance
%% to drop subscriptions) and ends without the END_STREAM DATA frame —
%% the wire is gone. `Reason` is `reset` when the peer cancelled this
%% stream (`RST_STREAM`, surfaced by the conn as `{h2_stream_reset, _}`)
%% or `conn_down` when the owning conn process died (the worker's monitor
%% `'DOWN'`).

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
            %% Connection gone — give the handler its disconnect and stop.
            deliver_disconnect(Handler, Push, State, conn_down);
        {h2_stream_reset, StreamId} ->
            %% The conn reset this stream (peer RST_STREAM, or a protocol
            %% violation on the conn side) and already dropped it. Hand
            %% the handler the disconnect and stop; no END_STREAM frame —
            %% the stream is gone.
            deliver_disconnect(Handler, Push, State, reset);
        {system, From, Req} ->
            Resume = fun(S) -> info_loop(ConnPid, StreamId, Handler, Push, S) end,
            roadrunner_loop_sys:handle_system(Req, From, State, Resume);
        {'$gen_call', From, _} ->
            ok = roadrunner_loop_sys:gen_call_unsupported(From),
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

%% Hand the handler one final `{roadrunner_disconnect, Reason}` so it can
%% drop subscriptions / stop work, then end the loop. The stream/conn is
%% gone: we neither emit the END_STREAM frame nor honour the return.
-spec deliver_disconnect(module(), roadrunner_handler:push_fun(), term(), reset | conn_down) -> ok.
deliver_disconnect(Handler, Push, State, Reason) ->
    _ = Handler:handle_info({roadrunner_disconnect, Reason}, Push, State),
    ok.

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
