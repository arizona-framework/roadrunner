-module(cactus_ws_session).
-moduledoc """
Per-connection WebSocket session — runs the frame loop in its own
`gen_statem` process after `cactus_conn:upgrade_to_websocket/4`
hands the socket off.

The session owns the socket for its lifetime: the parent `cactus_conn`
launcher (`run/4`) starts the session, transfers controlling-process,
sends the `socket_ready` startup signal (mirroring the conn's `shoot`
pattern), and waits via a monitor for the session to terminate.
When the session exits — peer close frame, recv error, frame parse
error, or handler-driven `{close, _}` — the launcher returns and the
parent's `[cactus, listener, conn_close]` telemetry fires after.

States:
- `awaiting_socket` — gates the frame loop until controlling-process
  has transferred and the launcher has sent `socket_ready`.
- `frame_loop` — parse/dispatch one frame, emit telemetry, recv more
  bytes if the buffer doesn't yet hold a full frame.

Telemetry: `[cactus, ws, upgrade]` fires from `run/4` once the
launcher has decided to enter the session; `[cactus, ws, frame_in]`
and `[cactus, ws, frame_out]` fire from the gen_statem itself for
every frame.
""".

-behaviour(gen_statem).

-export([run/4]).
-export([init/1, callback_mode/0, terminate/3]).
-export([awaiting_socket/3, frame_loop/3]).

-record(data, {
    socket :: cactus_transport:socket(),
    buffer :: binary(),
    mod :: module(),
    mod_state :: term(),
    ctx :: map()
}).

-doc """
Run the WebSocket session synchronously: spawn the gen_statem,
write the 101 upgrade response, transfer socket ownership, and
await termination. The gen_statem is started **before** the 101
hits the wire so a start failure can fall back to 500 without
leaving the upgrade response sent with no process owning the
socket. Returns `ok` once the session has ended (or the
handshake check fails — in which case 400 has been sent and
the gen_statem is never started).
""".
-spec run(cactus_transport:socket(), cactus_http1:request(), module(), term()) -> ok.
run(Socket, Req, Mod, State) ->
    case cactus_ws:handshake_response(cactus_req:headers(Req)) of
        {ok, Status, RespHeaders, _} ->
            UpgradeResp = cactus_http1:response(Status, RespHeaders, ~""),
            run_session(Socket, Req, Mod, State, UpgradeResp);
        {error, _} ->
            _ = cactus_transport:send(
                Socket,
                cactus_http1:response(
                    400,
                    [{~"content-length", ~"0"}, {~"connection", ~"close"}],
                    ~""
                )
            ),
            ok
    end.

-spec run_session(
    cactus_transport:socket(), cactus_http1:request(), module(), term(), iodata()
) -> ok.
run_session(Socket, Req, Mod, State, UpgradeResp) ->
    Ctx = ws_context(Req, Mod),
    %% Start the gen_statem **before** writing the 101 to the wire so a
    %% start failure never leaves the upgrade response sent with no
    %% process owning the socket. `start` (not `start_link`) — the
    %% conn is intentionally unlinked from its children so a session
    %% crash never propagates to the conn process. We synchronise via
    %% a monitor instead.
    case gen_statem:start(?MODULE, {Socket, Mod, State, Ctx}, []) of
        {ok, Pid} ->
            ok = cactus_telemetry:ws_upgrade(Ctx),
            _ = cactus_telemetry:response_send(
                cactus_transport:send(Socket, UpgradeResp), websocket_upgrade_response
            ),
            Ref = monitor(process, Pid),
            ok = cactus_transport:controlling_process(Socket, Pid),
            Pid ! socket_ready,
            receive
                {'DOWN', Ref, process, Pid, _Reason} -> ok
            end;
        {error, _Reason} ->
            %% Couldn't start the session — the 101 was never on the
            %% wire, so we can fall back to 500 without a protocol leak.
            _ = cactus_transport:send(
                Socket,
                cactus_http1:response(
                    500,
                    [{~"content-length", ~"0"}, {~"connection", ~"close"}],
                    ~""
                )
            ),
            ok
    end.

-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() -> [state_functions, state_enter].

-spec init({cactus_transport:socket(), module(), term(), map()}) ->
    {ok, awaiting_socket, #data{}} | {stop, {bad_handler, module()}}.
init({Socket, Mod, State, Ctx}) ->
    %% Reject unloadable handlers up front so `gen_statem:start/3`
    %% returns `{error, _}` and the launcher's 500 fallback runs —
    %% otherwise the session would crash later inside `handle_frame`
    %% with the 101 already on the wire.
    case
        code:ensure_loaded(Mod) =:= {module, Mod} andalso
            erlang:function_exported(Mod, handle_frame, 2)
    of
        true ->
            {ok, awaiting_socket, #data{
                socket = Socket,
                buffer = <<>>,
                mod = Mod,
                mod_state = State,
                ctx = Ctx
            }};
        false ->
            {stop, {bad_handler, Mod}}
    end.

-spec awaiting_socket(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:event_handler_result(atom()).
awaiting_socket(enter, _Old, _Data) ->
    keep_state_and_data;
awaiting_socket(info, socket_ready, Data) ->
    {next_state, frame_loop, Data, [{next_event, internal, recv}]}.

%% Each `recv` event blocks on `cactus_transport:recv/3` with `infinity`
%% timeout when the buffer doesn't yet hold a full frame — the session
%% sleeps until the peer sends bytes, the peer closes, or the framework
%% detects a transport error. The session exits via `{stop, normal, _}`
%% on close or parse error; idle sessions live indefinitely.
-spec frame_loop(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:event_handler_result(atom()).
frame_loop(enter, _Old, _Data) ->
    keep_state_and_data;
frame_loop(internal, recv, #data{socket = Socket, buffer = Buf} = Data) ->
    case cactus_ws:parse_frame(Buf) of
        {ok, Frame, NewBuffer} ->
            ok = cactus_telemetry:ws_frame_in(
                (Data#data.ctx)#{opcode => maps:get(opcode, Frame)},
                payload_size(Frame)
            ),
            handle_frame(Frame, Data#data{buffer = NewBuffer});
        {more, _} ->
            case cactus_transport:recv(Socket, 0, infinity) of
                {ok, Bytes} ->
                    {keep_state, Data#data{buffer = <<Buf/binary, Bytes/binary>>}, [
                        {next_event, internal, recv}
                    ]};
                {error, _} ->
                    {stop, normal, Data}
            end;
        {error, _} ->
            {stop, normal, Data}
    end.

-spec terminate(term(), atom(), #data{}) -> ok.
terminate(_Reason, _State, _Data) ->
    ok.

%% --- frame dispatch ---

-spec handle_frame(cactus_ws:frame(), #data{}) ->
    gen_statem:event_handler_result(atom()).
handle_frame(#{opcode := close}, Data) ->
    ok = send_ws_frame(Data, close, ~""),
    {stop, normal, Data};
handle_frame(#{opcode := ping, payload := P}, Data) ->
    ok = send_ws_frame(Data, pong, P),
    {keep_state, Data, [{next_event, internal, recv}]};
handle_frame(#{opcode := pong}, Data) ->
    %% Server is not pinging clients yet — pong from client is just dropped.
    {keep_state, Data, [{next_event, internal, recv}]};
handle_frame(Frame, #data{mod = Mod, mod_state = State} = Data) ->
    case Mod:handle_frame(Frame, State) of
        {reply, OutFrames, NewState} ->
            _ = send_ws_frames(Data, OutFrames),
            {keep_state, Data#data{mod_state = NewState}, [{next_event, internal, recv}]};
        {ok, NewState} ->
            {keep_state, Data#data{mod_state = NewState}, [{next_event, internal, recv}]};
        {close, _NewState} ->
            ok = send_ws_frame(Data, close, ~""),
            {stop, normal, Data}
    end.

%% --- helpers ---

-spec ws_context(cactus_http1:request(), module()) -> map().
ws_context(Req, Mod) ->
    #{
        listener_name => maps:get(listener_name, Req, undefined),
        peer => maps:get(peer, Req, undefined),
        request_id => maps:get(request_id, Req, undefined),
        module => Mod
    }.

-spec payload_size(cactus_ws:frame()) -> non_neg_integer().
payload_size(#{payload := P}) -> byte_size(P).

%% Single outbound frame — wraps `cactus_transport:send/2` with a
%% `[cactus, ws, frame_out]` event so subscribers see every frame the
%% session writes (auto-pong, close, and unary handler replies).
-spec send_ws_frame(#data{}, cactus_ws:opcode(), iodata()) -> ok.
send_ws_frame(#data{socket = Socket, ctx = Ctx}, Opcode, Payload) ->
    ok = cactus_telemetry:ws_frame_out(
        Ctx#{opcode => Opcode}, iolist_size(Payload)
    ),
    _ = cactus_transport:send(Socket, cactus_ws:encode_frame(Opcode, Payload, true)),
    ok.

%% Batched outbound frames from a handler `{reply, [...]}` return —
%% emit telemetry per frame (so subscribers can count by opcode), then
%% write all frames in a single TCP send to avoid partial-write
%% fragmentation.
-spec send_ws_frames(#data{}, [{cactus_ws:opcode(), iodata()}]) ->
    ok | {error, term()}.
send_ws_frames(#data{socket = Socket, ctx = Ctx}, OutFrames) ->
    lists:foreach(
        fun({Op, Payload}) ->
            ok = cactus_telemetry:ws_frame_out(
                Ctx#{opcode => Op}, iolist_size(Payload)
            )
        end,
        OutFrames
    ),
    Iodata = [cactus_ws:encode_frame(Op, Payload, true) || {Op, Payload} <- OutFrames],
    cactus_transport:send(Socket, Iodata).
