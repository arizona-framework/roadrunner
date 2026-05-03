-module(roadrunner_loop_response).
-moduledoc """
Per-connection `{loop, ...}` response — message-driven streaming.

Called by `roadrunner_conn_loop:dispatch_response/4` after a handler
returns `{loop, Status, Headers, State}`. Writes the status line +
chunked headers, then runs a recursive selective-receive loop that
dispatches every Erlang message through `Module:handle_info/3`. The
handler's `Push(Data)` callback frames the data as one chunk and
writes it. On `{stop, _NewState}` the loop emits the size-0 chunked
terminator and returns.

**Runs in the conn process**, not a child — handlers commonly do
`self() ! Msg` or `register(Name, self())` from `handle/1`,
expecting the loop to share their mailbox. Splitting into a child
process would break that contract; the loop stays inline.

## Mailbox contract

The conn is a plain `proc_lib`-spawned loop, not a `gen_*` behaviour,
so it doesn't speak the OTP `sys` / `gen_call` / `gen_cast` protocols.
The receive selectively skips those shapes (`{system, _, _}`,
`{'$gen_call', _, _}`, `{'$gen_cast', _}`) so a misuse like
`gen_server:call(ConnPid, _)` doesn't accidentally surface as an
`handle_info/3` event to the user handler. Concretely:

- `sys:get_state/1`, `sys:trace/2`, `gen_server:call/2,3` and
  friends against the conn process will appear to hang — the
  caller should expect to time out.
- Any other Erlang message reaches the handler's `handle_info/3`
  verbatim. Handlers should pattern-match defensively (with a
  catch-all clause) rather than crash on unexpected messages.
""".

-export([run/5]).

-doc """
Send the chunked-response head, then enter the message-receive
loop. Returns when the handler's `handle_info/3` returns `{stop, _}`.
""".
-spec run(
    roadrunner_transport:socket(),
    roadrunner_http1:status(),
    roadrunner_http1:headers(),
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
%% **except** OTP-internal shapes (`{system, _, _}` for the `sys`
%% protocol, `{'$gen_call', _, _}` and `{'$gen_cast', _}` for
%% gen_server/gen_statem requests). Those would only reach the conn
%% via misuse (the conn is a plain proc_lib loop, not a gen_*) and
%% delivering them to the user handler would surface a confusing
%% shape it has no reason to pattern-match on. Skipping leaves them
%% in the mailbox; they're dropped when the conn exits. On
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
        Info when
            not (is_tuple(Info) andalso
                (element(1, Info) =:= system orelse
                    element(1, Info) =:= '$gen_call' orelse
                    element(1, Info) =:= '$gen_cast'))
        ->
            case Handler:handle_info(Info, Push, State) of
                {ok, NewState} ->
                    info_loop(Socket, Handler, Push, NewState);
                {stop, _NewState} ->
                    _ = roadrunner_transport:send(Socket, ~"0\r\n\r\n"),
                    ok
            end
    end.

%% Push fun handed to the user handler. Same special-case as
%% `roadrunner_stream_response:stream_frame/2` (Phase 3): zero-length
%% data would encode as `0\r\n\r\n` — the chunked terminator —
%% which would end the response mid-loop. Skip empty pushes.
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
