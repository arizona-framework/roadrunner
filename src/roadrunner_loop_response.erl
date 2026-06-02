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
    Headers = [{~"transfer-encoding", ~"chunked"} | UserHeaders],
    Head = roadrunner_http1:response(Status, Headers, ~""),
    _ = roadrunner_telemetry:response_send(
        roadrunner_transport:send(Socket, Head), loop_response_head
    ),
    Push = make_push(Socket),
    info_loop(Socket, Handler, Push, State).

%% Selective receive on every Erlang message → handler:handle_info/3,
%% **except** the OTP-internal shapes, which are answered via
%% `roadrunner_loop_sys` rather than delivered to the user handler:
%% `{system, _, _}` goes to the `sys` protocol handler, `{'$gen_call', _, _}`
%% is replied `{error, not_supported}`, and `{'$gen_cast', _}` is a no-op.
%% Non-OTP messages fall through to the catch-all `Info` clause. On
%% `{stop, _}` we emit the size-0 chunked terminator and return.
%%
%% **No `after` clause:** the loop blocks indefinitely until the
%% handler returns `{stop, _}` from `handle_info/3`. A handler that
%% never receives a stop-triggering message keeps the connection
%% open forever; that's the contract for `{loop, ...}` responses
%% (e.g. SSE feeds).
-spec info_loop(roadrunner_transport:socket(), module(), roadrunner_handler:push_fun(), term()) ->
    ok.
info_loop(Socket, Handler, Push, State) ->
    receive
        {system, From, Req} ->
            Resume = fun(S) -> info_loop(Socket, Handler, Push, S) end,
            roadrunner_loop_sys:handle_system(Req, From, State, Resume);
        {'$gen_call', From, _} ->
            ok = roadrunner_loop_sys:gen_call_unsupported(From),
            info_loop(Socket, Handler, Push, State);
        {'$gen_cast', _} ->
            info_loop(Socket, Handler, Push, State);
        Info ->
            case Handler:handle_info(Info, Push, State) of
                {ok, NewState} ->
                    info_loop(Socket, Handler, Push, NewState);
                {stop, _NewState} ->
                    _ = roadrunner_transport:send(Socket, ~"0\r\n\r\n"),
                    ok
            end
    end.

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
