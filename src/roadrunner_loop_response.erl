-module(roadrunner_loop_response).
-moduledoc false.

%% Per-connection `{loop, ...}` response — message-driven streaming.
%%
%% Called by `roadrunner_conn_loop:dispatch_response/4` after a handler
%% returns `{loop, Status, Headers, State}`. Writes the status line +
%% chunked headers, then runs a recursive selective-receive loop that
%% dispatches every Erlang message through `Module:handle_info/3`. The
%% handler's `Push(Data)` callback frames the data as one chunk and
%% writes it. On `{stop, _NewState}` the loop emits the size-0 chunked
%% terminator and returns.
%%
%% **Runs in the conn process**, not a child — handlers commonly do
%% `self() ! Msg` or `register(Name, self())` from `handle/1`,
%% expecting the loop to share their mailbox. Splitting into a child
%% process would break that contract; the loop stays inline.
%%
%% ## Mailbox contract
%%
%% The conn is a plain `proc_lib`-spawned loop, not a `gen_*` behaviour,
%% but it still answers the OTP message shapes (via `roadrunner_loop_sys`)
%% so they don't leak to the user handler:
%%
%% - `{system, _, _}` — `sys:get_state/1`, `sys:replace_state/2`,
%%   `sys:get_status/1` and `sys:terminate/2` work (`get_state` returns the
%%   handler state). Live tracing (`sys:trace`/`sys:log`) installs but emits
%%   no events: the loop does not thread `sys:handle_debug/4` per message.
%% - `{'$gen_call', _, _}` — replied `{error, not_supported}`, so
%%   `gen_server:call(ConnPid, _)` fails fast instead of hanging.
%% - `{'$gen_cast', _}` — a no-op (casts expect no reply).
%% - Any other Erlang message reaches the handler's `handle_info/3`
%%   verbatim. Handlers should pattern-match defensively (with a
%%   catch-all clause) rather than crash on unexpected messages.
%%
%% ## Client disconnect
%%
%% The socket is armed `{active, once}` before the loop blocks, so a
%% peer close/error arrives as a mailbox message the selective receive
%% can match — otherwise a passive, unread socket only reveals the dead
%% peer on the next write, which may be minutes away on a quiet SSE
%% channel. On close/error the loop delivers one final
%% `{roadrunner_disconnect, closed}` through `handle_info/3` (the
%% handler's chance to drop subscriptions) and then ends without writing
%% the chunked terminator — the wire is already gone. Inbound bytes (an
%% h1 streaming response is unidirectional) re-arm and are discarded.

-export([run/5]).

-doc """
Send the chunked-response head, then enter the message-receive
loop. Returns when the handler's `handle_info/3` returns `{stop, _}`.
""".
-spec run(
    roadrunner_transport:socket(),
    roadrunner_http:status(),
    roadrunner_http:headers(),
    module(),
    term()
) -> ok.
run(Socket, Status, UserHeaders, Handler, State) ->
    %% A loop response always closes the connection (the conn loop force-
    %% closes once this returns), so advertise it on the wire per RFC 9112
    %% §9.6 — without it a fronting proxy treats the connection as reusable
    %% and can race a request onto a socket we are about to drop.
    Headers = [{~"transfer-encoding", ~"chunked"}, {~"connection", ~"close"} | UserHeaders],
    Head = roadrunner_http1:response(Status, Headers, ~""),
    _ = roadrunner_telemetry:response_send(
        roadrunner_transport:send(Socket, Head), loop_response_head
    ),
    Push = make_push(Socket),
    %% Active-mode tags for this transport (`{tcp, tcp_closed, tcp_error}`
    %% / `{ssl, ssl_closed, ssl_error}`), matched in `info_loop` so a peer
    %% close surfaces as a message rather than only on the next write.
    Tags = roadrunner_transport:messages(Socket),
    arm_and_loop(Socket, Tags, Handler, Push, State).

%% Arm `{active, once}` and enter the loop. If arming fails the socket
%% is already gone, so deliver the disconnect straight away. Shared by
%% `run/5` (initial arm) and the inbound-data clause (re-arm).
-spec arm_and_loop(
    roadrunner_transport:socket(),
    {atom(), atom(), atom()},
    module(),
    roadrunner_handler:push_fun(),
    term()
) -> ok.
arm_and_loop(Socket, Tags, Handler, Push, State) ->
    case roadrunner_transport:setopts(Socket, [{active, once}]) of
        ok -> info_loop(Socket, Tags, Handler, Push, State);
        {error, _} -> deliver_disconnect(Handler, Push, State, closed)
    end.

%% Selective receive on every Erlang message → handler:handle_info/3,
%% **except** the active-mode socket events and the OTP-internal shapes.
%% The transport's close/error tags deliver a final
%% `{roadrunner_disconnect, closed}` and end the loop (no terminator —
%% the wire is gone); its data tag re-arms and discards inbound bytes.
%% The OTP shapes are answered via `roadrunner_loop_sys` rather than
%% delivered to the user handler: `{system, _, _}` goes to the `sys`
%% protocol handler, `{'$gen_call', _, _}` is replied
%% `{error, not_supported}`, and `{'$gen_cast', _}` is a no-op. Non-OTP
%% messages fall through to the catch-all `Info` clause. On `{stop, _}`
%% we emit the size-0 chunked terminator and return.
%%
%% **No `after` clause:** absent a peer disconnect the loop blocks
%% indefinitely until the handler returns `{stop, _}` from
%% `handle_info/3`. A handler that never receives a stop-triggering
%% message keeps the connection open until the client goes away; that's
%% the contract for `{loop, ...}` responses (e.g. SSE feeds).
-spec info_loop(
    roadrunner_transport:socket(),
    {atom(), atom(), atom()},
    module(),
    roadrunner_handler:push_fun(),
    term()
) -> ok.
info_loop(Socket, {DataTag, ClosedTag, ErrorTag} = Tags, Handler, Push, State) ->
    receive
        {ClosedTag, _} ->
            deliver_disconnect(Handler, Push, State, closed);
        {ErrorTag, _, _} ->
            deliver_disconnect(Handler, Push, State, closed);
        {DataTag, _, _} ->
            %% Inbound bytes on a unidirectional streaming response (the
            %% request body was already read before dispatch); discard
            %% them and re-arm so the next socket event is still seen.
            arm_and_loop(Socket, Tags, Handler, Push, State);
        {system, From, Req} ->
            Resume = fun(S) -> info_loop(Socket, Tags, Handler, Push, S) end,
            roadrunner_loop_sys:handle_system(Req, From, State, Resume);
        {'$gen_call', From, _} ->
            ok = roadrunner_loop_sys:gen_call_unsupported(From),
            info_loop(Socket, Tags, Handler, Push, State);
        {'$gen_cast', _} ->
            info_loop(Socket, Tags, Handler, Push, State);
        Info ->
            case Handler:handle_info(Info, Push, State) of
                {ok, NewState} ->
                    info_loop(Socket, Tags, Handler, Push, NewState);
                {stop, _NewState} ->
                    _ = roadrunner_transport:send(Socket, ~"0\r\n\r\n"),
                    ok
            end
    end.

%% Hand the handler one final `{roadrunner_disconnect, Reason}` so it can
%% drop subscriptions / stop work, then end the loop. The wire is gone:
%% we neither write the chunked terminator nor honour the return (the
%% channel is dead either way). A handler with no matching clause falls
%% through to its catch-all; the loop ends regardless.
-spec deliver_disconnect(module(), roadrunner_handler:push_fun(), term(), closed) -> ok.
deliver_disconnect(Handler, Push, State, Reason) ->
    _ = Handler:handle_info({roadrunner_disconnect, Reason}, Push, State),
    ok.

%% Push fun handed to the user handler. Same special-case as
%% `roadrunner_stream_response:stream_frame/2`: zero-length data
%% would encode as `0\r\n\r\n` — the chunked terminator — which
%% would end the response mid-loop. Skip empty pushes.
-spec make_push(roadrunner_transport:socket()) -> roadrunner_handler:push_fun().
make_push(Socket) ->
    fun(Data) ->
        case iolist_size(Data) of
            0 ->
                ok;
            N ->
                roadrunner_transport:send(Socket, [
                    integer_to_binary(N, 16),
                    ~"\r\n",
                    Data,
                    ~"\r\n"
                ])
        end
    end.
