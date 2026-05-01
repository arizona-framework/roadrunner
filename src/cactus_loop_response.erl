-module(cactus_loop_response).
-moduledoc """
Per-connection `{loop, ...}` response — message-driven streaming.

Called by `cactus_conn_statem`'s dispatching state after a
handler returns `{loop, Status, Headers, State}`. Writes the
status line + chunked headers, then runs a recursive selective-
receive loop that dispatches every Erlang message through
`Module:handle_info/3`. The handler's `Push(Data)` callback frames
the data as one chunk and writes it. On `{stop, _NewState}` the
loop emits the size-0 chunked terminator and returns.

**Runs in the conn process**, not a child — handlers commonly do
`self() ! Msg` or `register(Name, self())` from `handle/1`,
expecting the loop to share their mailbox. Splitting into a child
process would break that contract; the loop stays inline.

## Mailbox contract

Because the loop runs synchronously in the conn's `gen_statem`
process and uses `receive` directly, the conn's gen_statem is
**not** processing events while the loop is active. The loop
explicitly skips well-known OTP-internal message shapes
(`{system, _, _}`, `{'$gen_call', _, _}`, `{'$gen_cast', _}`)
so they remain in the mailbox and `gen_statem` resumes their
normal handling once the loop returns. Concretely:

- `sys:get_state/1`, `sys:trace/2`, `sys:replace_state/2` against
  the conn process while it is in a loop response will appear to
  hang — the caller should expect to time out.
- `gen_statem:call/2,3` against the conn process is unsupported
  and will hang the same way.
- Any other Erlang message reaches the handler's
  `handle_info/3` verbatim. Handlers should pattern-match
  defensively (with a catch-all clause) rather than crash on
  unexpected messages.
""".

-export([run/5]).

-doc """
Send the chunked-response head, then enter the message-receive
loop. Returns when the handler's `handle_info/3` returns `{stop, _}`.
""".
-spec run(
    cactus_transport:socket(),
    cactus_http1:status(),
    cactus_http1:headers(),
    module(),
    term()
) -> ok.
run(Socket, Status, UserHeaders, Handler, State) ->
    Headers = [{~"transfer-encoding", ~"chunked"} | UserHeaders],
    Head = cactus_http1:response(Status, Headers, ~""),
    _ = cactus_telemetry:response_send(
        cactus_transport:send(Socket, Head), loop_response_head
    ),
    Push = make_push(Socket),
    info_loop(Socket, Handler, Push, State).

%% Selective receive on every Erlang message → handler:handle_info/3,
%% **except** OTP-internal shapes (`{system, _, _}` for `sys` protocol,
%% `{'$gen_call', _, _}` and `{'$gen_cast', _}` for `gen_statem`
%% requests), which stay in the mailbox so the gen_statem resumes
%% their normal handling after this loop returns. On `{stop, _}` we
%% emit the size-0 chunked terminator and return.
-spec info_loop(cactus_transport:socket(), module(), cactus_handler:push_fun(), term()) -> ok.
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
                    _ = cactus_transport:send(Socket, ~"0\r\n\r\n"),
                    ok
            end
    end.

%% Push fun handed to the user handler. Same special-case as
%% `cactus_stream_response:stream_frame/2` (Phase 3): zero-length
%% data would encode as `0\r\n\r\n` — the chunked terminator —
%% which would end the response mid-loop. Skip empty pushes.
-spec make_push(cactus_transport:socket()) -> cactus_handler:push_fun().
make_push(Socket) ->
    fun(Data) ->
        case iolist_size(Data) of
            0 ->
                ok;
            N ->
                cactus_transport:send(Socket, [
                    integer_to_binary(N, 16),
                    ~"\r\n",
                    Data,
                    ~"\r\n"
                ])
        end
    end.
