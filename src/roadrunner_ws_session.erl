-module(roadrunner_ws_session).
-moduledoc """
Per-connection WebSocket session — runs the frame loop in its own
`gen_statem` process after `roadrunner_conn:upgrade_to_websocket/4`
hands the socket off.

The session owns the socket for its lifetime: the parent `roadrunner_conn`
launcher (`run/4`) starts the session, transfers controlling-process,
sends the `socket_ready` startup signal (mirroring the conn's `shoot`
pattern), and waits via a monitor for the session to terminate.
When the session exits — peer close frame, recv error, frame parse
error, or handler-driven `{close, _}` — the launcher returns and the
parent's `[roadrunner, listener, conn_close]` telemetry fires after.

States:
- `awaiting_socket` — gates the frame loop until controlling-process
  has transferred and the launcher has sent `socket_ready`.
- `frame_loop` — parse/dispatch frames as they arrive; the socket
  is in active-once mode so bytes arrive as `info` events and the
  gen_statem returns to its main loop between frames.

## Active-mode reads

`frame_loop` uses active-once reads (`roadrunner_transport:setopts(_,
[{active, once}])`): after each event the state callback returns,
gen_statem is idle in its main loop, and `hibernate` actions
actually take effect. Without active mode we'd be blocked inside
`roadrunner_transport:recv/3` and hibernation would be a no-op.

## Handler hibernation opt-in

The `roadrunner_ws_handler` callback supports an optional 4-tuple
return shape: `{reply, OutFrames, NewState, Opts}` and
`{ok, NewState, Opts}`, where `Opts` is a list that may contain
`hibernate`. When present, the gen_statem hibernates after this
event is fully processed — process heap drops to ~1KB until the
next inbound frame wakes it up. For an idle WebSocket session
this is the difference between holding ~5–8KB of process memory
indefinitely vs. ~1KB.

3-tuple returns (`{reply, OutFrames, NewState}`, `{ok, NewState}`,
`{close, NewState}`) stay valid — the 4-tuple is purely additive.

## Optional handler callbacks

`init/1` runs once on the awaiting_socket → frame_loop transition,
**before** the first inbound frame; the handler can push priming
frames or refuse the session by returning `{close, _}`. `handle_info/2`
receives any non-transport info message (a pubsub broadcast a handler
subscribed to in `init/1`, an exit signal from a linked worker, etc.)
and returns the same shape as `handle_frame/2`. Both are
`-optional_callbacks` — handlers that don't export them get the
old behavior (no init action, stray info dropped silently). Whether
each is exported is cached in `#data` at session start so the BIF
check doesn't run on every event.

Telemetry: `[roadrunner, ws, upgrade]` fires from `run/4` once the
launcher has decided to enter the session; `[roadrunner, ws, frame_in]`
and `[roadrunner, ws, frame_out]` fire from the gen_statem itself for
every frame.
""".

-behaviour(gen_statem).

-export([run/4]).
-export([init/1, callback_mode/0, terminate/3]).
-export([awaiting_socket/3, frame_loop/3]).

-record(data, {
    socket :: roadrunner_transport:socket(),
    buffer :: binary(),
    mod :: module(),
    mod_state :: term(),
    ctx :: map(),
    %% Cached results of `erlang:function_exported/3` for the optional
    %% callbacks. Computed once in `init/1` and read on every event so
    %% the BIF call doesn't run on the hot path (handle_info can fire
    %% per pubsub message — caching turns a ~50ns BIF into a record
    %% read).
    has_init :: boolean(),
    has_handle_info :: boolean(),
    %% permessage-deflate (RFC 7692) state. `pmd_params = undefined`
    %% means the extension was NOT negotiated; the session bypasses
    %% all compression machinery on the hot path.
    pmd_params :: roadrunner_ws:permessage_deflate_params() | undefined,
    inflate_z :: zlib:zstream() | undefined,
    deflate_z :: zlib:zstream() | undefined,
    %% When mid-fragmented-compressed-message, accumulates the raw
    %% (still-compressed) fragment payloads. On FIN we concatenate,
    %% append the per-message trailer (\x00\x00\xff\xff), and inflate.
    %% `undefined` = not currently in a compressed message.
    compressed_acc :: undefined | iodata(),
    %% Opcode of the in-progress compressed message (text | binary) —
    %% needed to rebuild the synthesized FIN frame for the handler.
    compressed_opcode :: undefined | text | binary
}).

%% Per-message DEFLATE trailer (RFC 7692 §7.2.1). Sender strips it
%% from the deflate output; receiver appends it before inflating to
%% terminate the deflate block.
-define(PMD_TAIL, <<0, 0, 16#FF, 16#FF>>).

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
-spec run(roadrunner_transport:socket(), roadrunner_http1:request(), module(), term()) -> ok.
run(Socket, Req, Mod, State) ->
    case roadrunner_ws:handshake_response(roadrunner_req:headers(Req)) of
        {ok, Status, RespHeaders, _, Negotiated} ->
            UpgradeResp = roadrunner_http1:response(Status, RespHeaders, ~""),
            run_session(Socket, Req, Mod, State, UpgradeResp, Negotiated);
        {error, _} ->
            _ = roadrunner_transport:send(
                Socket,
                roadrunner_http1:response(
                    400,
                    [{~"content-length", ~"0"}, {~"connection", ~"close"}],
                    ~""
                )
            ),
            ok
    end.

-spec run_session(
    roadrunner_transport:socket(),
    roadrunner_http1:request(),
    module(),
    term(),
    iodata(),
    roadrunner_ws:negotiated()
) -> ok.
run_session(Socket, Req, Mod, State, UpgradeResp, Negotiated) ->
    Ctx = ws_context(Req, Mod),
    %% Start the gen_statem **before** writing the 101 to the wire so a
    %% start failure never leaves the upgrade response sent with no
    %% process owning the socket. `start` (not `start_link`) — the
    %% conn is intentionally unlinked from its children so a session
    %% crash never propagates to the conn process. We synchronise via
    %% a monitor instead.
    case gen_statem:start(?MODULE, {Socket, Mod, State, Ctx, Negotiated}, []) of
        {ok, Pid} ->
            ok = roadrunner_telemetry:ws_upgrade(Ctx),
            _ = roadrunner_telemetry:response_send(
                roadrunner_transport:send(Socket, UpgradeResp), websocket_upgrade_response
            ),
            Ref = monitor(process, Pid),
            ok = roadrunner_transport:controlling_process(Socket, Pid),
            Pid ! socket_ready,
            receive
                {'DOWN', Ref, process, Pid, _Reason} -> ok
            end;
        {error, _Reason} ->
            %% Couldn't start the session — the 101 was never on the
            %% wire, so we can fall back to 500 without a protocol leak.
            _ = roadrunner_transport:send(
                Socket,
                roadrunner_http1:response(
                    500,
                    [{~"content-length", ~"0"}, {~"connection", ~"close"}],
                    ~""
                )
            ),
            ok
    end.

-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() -> [state_functions, state_enter].

-spec init({
    roadrunner_transport:socket(), module(), term(), map(), roadrunner_ws:negotiated()
}) ->
    {ok, awaiting_socket, #data{}} | {stop, {bad_handler, module()}}.
init({Socket, Mod, State, Ctx, Negotiated}) ->
    %% Reject unloadable handlers up front so `gen_statem:start/3`
    %% returns `{error, _}` and the launcher's 500 fallback runs —
    %% otherwise the session would crash later inside `handle_frame`
    %% with the 101 already on the wire.
    case
        code:ensure_loaded(Mod) =:= {module, Mod} andalso
            erlang:function_exported(Mod, handle_frame, 2)
    of
        true ->
            {PmdParams, InflateZ, DeflateZ} = init_pmd(Negotiated),
            {ok, awaiting_socket, #data{
                socket = Socket,
                buffer = <<>>,
                mod = Mod,
                mod_state = State,
                ctx = Ctx,
                has_init = erlang:function_exported(Mod, init, 1),
                has_handle_info = erlang:function_exported(Mod, handle_info, 2),
                pmd_params = PmdParams,
                inflate_z = InflateZ,
                deflate_z = DeflateZ,
                compressed_acc = undefined,
                compressed_opcode = undefined
            }};
        false ->
            {stop, {bad_handler, Mod}}
    end.

%% Set up the inflate / deflate contexts when permessage-deflate was
%% negotiated. Inflate uses the client's max-window-bits (server's
%% inflate decompresses what the client deflated). Deflate uses the
%% server's max-window-bits. RFC 7692 §7.2.1 specifies raw DEFLATE
%% (no zlib header), so windowBits is negative in zlib's convention.
-spec init_pmd(roadrunner_ws:negotiated()) ->
    {undefined, undefined, undefined}
    | {roadrunner_ws:permessage_deflate_params(), zlib:zstream(), zlib:zstream()}.
init_pmd(none) ->
    {undefined, undefined, undefined};
init_pmd({permessage_deflate, Params, _ResponseValue}) ->
    #{
        client_max_window_bits := ClientWB,
        server_max_window_bits := ServerWB
    } = Params,
    InflateZ = zlib:open(),
    ok = zlib:inflateInit(InflateZ, -ClientWB),
    DeflateZ = zlib:open(),
    ok = zlib:deflateInit(DeflateZ, default, deflated, -ServerWB, 8, default),
    {Params, InflateZ, DeflateZ}.

-spec awaiting_socket(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:event_handler_result(atom()).
awaiting_socket(enter, _Old, _Data) ->
    keep_state_and_data;
awaiting_socket(info, socket_ready, #data{has_init = true, mod = Mod, mod_state = State} = Data) ->
    %% Run the optional `init/1` callback once, here at the
    %% awaiting_socket → frame_loop boundary. Placing it here (and not
    %% in `frame_loop(enter, ...)`) means it fires **once** per session
    %% by construction, regardless of any future state additions that
    %% might re-enter `frame_loop`.
    apply_handler_result(Mod:init(State), Data, false, fun continue_to_frame_loop/2);
awaiting_socket(info, socket_ready, Data) ->
    {next_state, frame_loop, Data}.

-spec frame_loop(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:event_handler_result(atom()).
frame_loop(enter, _Old, #data{socket = Socket} = Data) ->
    %% Arm the socket for one chunk of inbound bytes. Each event below
    %% re-arms after parsing whatever's in the buffer, so the
    %% gen_statem is back in its main loop receive between events —
    %% which is the only place `hibernate` actions can take effect.
    arm_or_stop(Socket, Data, []);
frame_loop(info, Msg, #data{socket = Socket} = Data) ->
    {DataTag, ClosedTag, ErrorTag} = roadrunner_transport:messages(Socket),
    %% `_Sock` discarded — one socket per gen_statem (captured in
    %% `#data.socket` at init). If we ever support multi-socket
    %% sessions, match `Sock = element(2, Socket)` here.
    case Msg of
        {DataTag, _Sock, Bytes} ->
            process_buffer(append_buffer(Data, Bytes), false);
        {ClosedTag, _Sock} ->
            {stop, normal, Data};
        {ErrorTag, _Sock, _Reason} ->
            {stop, normal, Data};
        _Other ->
            %% Forward to handler's optional handle_info/2 if exported,
            %% otherwise drop. Mirrors handle_frame's reply / hibernate
            %% / close return shapes.
            handle_info_msg(Msg, Data, false)
    end.

-spec terminate(term(), atom(), #data{}) -> ok.
terminate(_Reason, _State, #data{inflate_z = InflateZ, deflate_z = DeflateZ}) ->
    %% The runtime would clean these up on process exit anyway, but
    %% explicit release means the zlib NIF reclaims its working
    %% buffers immediately rather than waiting on GC.
    close_zlib(InflateZ),
    close_zlib(DeflateZ),
    ok.

-spec close_zlib(zlib:zstream() | undefined) -> ok.
close_zlib(undefined) -> ok;
close_zlib(Z) -> zlib:close(Z).

%% --- frame dispatch ---

%% Drain every complete frame out of the buffer in a single callback
%% pass, accumulating any handler-requested `hibernate` opt. When the
%% buffer doesn't hold a full frame, re-arm the socket and yield;
%% gen_statem will then process its (currently empty) event queue and
%% honor the hibernate flag if any handler set it.
-spec process_buffer(#data{}, boolean()) ->
    gen_statem:event_handler_result(atom()).
process_buffer(#data{socket = Socket, buffer = Buf, pmd_params = Pmd} = Data, HibernateAcc) ->
    Opts =
        case Pmd of
            undefined -> #{};
            _ -> #{allow_rsv1 => true}
        end,
    case roadrunner_ws:parse_frame(Buf, Opts) of
        {ok, Frame, NewBuffer} ->
            ok = roadrunner_telemetry:ws_frame_in(
                (Data#data.ctx)#{opcode => maps:get(opcode, Frame)},
                payload_size(Frame)
            ),
            handle_frame(Frame, Data#data{buffer = NewBuffer}, HibernateAcc);
        {more, _} ->
            arm_or_stop(Socket, Data, hibernate_actions(HibernateAcc));
        {error, _} ->
            {stop, normal, Data}
    end.

-spec append_buffer(#data{}, binary()) -> #data{}.
append_buffer(#data{buffer = Buf} = Data, Bytes) ->
    Data#data{buffer = <<Buf/binary, Bytes/binary>>}.

-spec hibernate_actions(boolean()) -> [hibernate].
hibernate_actions(true) -> [hibernate];
hibernate_actions(false) -> [].

%% Re-arm the active-mode socket and yield with `Actions`. Stops the
%% session cleanly if the socket is dead — matching `setopts/2`
%% strictly with `ok = ...` would crash on a peer-closed socket
%% before terminate/3 runs, polluting ops dashboards with badmatch
%% noise for what's a normal end-of-session event.
-spec arm_or_stop(
    roadrunner_transport:socket(), #data{}, [gen_statem:enter_action()]
) ->
    gen_statem:event_handler_result(atom()).
arm_or_stop(Socket, Data, Actions) ->
    case roadrunner_transport:setopts(Socket, [{active, once}]) of
        ok -> {keep_state, Data, Actions};
        {error, _} -> {stop, normal, Data}
    end.

-spec handle_frame(roadrunner_ws:frame(), #data{}, boolean()) ->
    gen_statem:event_handler_result(atom()).
handle_frame(#{opcode := close}, Data, _Hibernate) ->
    ok = send_ws_frame(Data, close, ~""),
    {stop, normal, Data};
handle_frame(#{opcode := ping, payload := P}, Data, Hibernate) ->
    ok = send_ws_frame(Data, pong, P),
    process_buffer(Data, Hibernate);
handle_frame(#{opcode := pong}, Data, Hibernate) ->
    %% Server is not pinging clients yet — pong from client is dropped.
    process_buffer(Data, Hibernate);
handle_frame(Frame, Data, Hibernate) ->
    %% Data frames (text / binary / continuation) — may be compressed
    %% per RFC 7692 if permessage-deflate negotiated. The PMD path
    %% buffers fragments then inflates on FIN; uncompressed frames
    %% take the regular dispatch shape.
    case classify_data_frame(Frame, Data) of
        {compressed_first, NewData} ->
            handle_compressed_fragment(Frame, NewData, Hibernate);
        compressed_continuation ->
            handle_compressed_fragment(Frame, Data, Hibernate);
        regular ->
            dispatch_data_frame(Frame, Data, Hibernate)
    end.

%% Determine whether this data frame is part of a PMD-compressed
%% message. RFC 7692 §6.1: only the FIRST fragment of a compressed
%% message has RSV1=1. Continuation frames within a compressed
%% message have RSV1=0 but are still part of the compressed payload.
-spec classify_data_frame(roadrunner_ws:frame(), #data{}) ->
    {compressed_first, #data{}} | compressed_continuation | regular.
classify_data_frame(#{opcode := continuation}, #data{compressed_acc = undefined}) ->
    %% Continuation outside a compressed message → not compressed.
    regular;
classify_data_frame(#{opcode := continuation}, _Data) ->
    %% Continuation inside a compressed message → still compressed.
    compressed_continuation;
classify_data_frame(#{rsv1 := true, opcode := Op}, #data{pmd_params = Pmd} = Data) when
    Pmd =/= undefined, (Op =:= text orelse Op =:= binary)
->
    %% First (or only) fragment of a compressed message.
    {compressed_first, Data#data{compressed_opcode = Op}};
classify_data_frame(_Frame, _Data) ->
    regular.

%% Buffer this fragment's payload. On FIN, concatenate, append the
%% per-message DEFLATE trailer, inflate, and dispatch the
%% reconstituted message to the user handler as a single frame.
-spec handle_compressed_fragment(roadrunner_ws:frame(), #data{}, boolean()) ->
    gen_statem:event_handler_result(atom()).
handle_compressed_fragment(
    #{fin := false, payload := P}, #data{compressed_acc = Acc} = Data, Hibernate
) ->
    NewAcc =
        case Acc of
            undefined -> [P];
            _ -> [Acc, P]
        end,
    process_buffer(Data#data{compressed_acc = NewAcc}, Hibernate);
handle_compressed_fragment(
    #{fin := true, payload := P},
    #data{compressed_acc = Acc, compressed_opcode = Op} = Data,
    Hibernate
) ->
    Compressed = iolist_to_binary(
        case Acc of
            undefined -> [P, ?PMD_TAIL];
            _ -> [Acc, P, ?PMD_TAIL]
        end
    ),
    case inflate_message(Data, Compressed) of
        {ok, Inflated, Data1} ->
            Synthesized = #{fin => true, rsv1 => false, opcode => Op, payload => Inflated},
            dispatch_data_frame(
                Synthesized,
                Data1#data{compressed_acc = undefined, compressed_opcode = undefined},
                Hibernate
            );
        {error, _} ->
            {stop, normal, Data}
    end.

-spec inflate_message(#data{}, binary()) -> {ok, binary(), #data{}} | {error, term()}.
inflate_message(#data{inflate_z = Z, pmd_params = Params} = Data, Compressed) ->
    try
        Iolist = zlib:inflate(Z, Compressed),
        Data1 =
            case maps:get(client_no_context_takeover, Params, false) of
                true ->
                    ok = zlib:inflateReset(Z),
                    Data;
                false ->
                    Data
            end,
        {ok, iolist_to_binary(Iolist), Data1}
    catch
        _:Reason -> {error, Reason}
    end.

-spec dispatch_data_frame(roadrunner_ws:frame(), #data{}, boolean()) ->
    gen_statem:event_handler_result(atom()).
dispatch_data_frame(Frame, #data{mod = Mod, mod_state = State} = Data, Hibernate) ->
    apply_handler_result(Mod:handle_frame(Frame, State), Data, Hibernate, fun process_buffer/2).

-spec handle_info_msg(term(), #data{}, boolean()) ->
    gen_statem:event_handler_result(atom()).
handle_info_msg(Msg, #data{has_handle_info = true, mod = Mod, mod_state = State} = Data, Hibernate) ->
    apply_handler_result(Mod:handle_info(Msg, State), Data, Hibernate, fun continue_arm/2);
handle_info_msg(_Msg, #data{has_handle_info = false, socket = Socket} = Data, _Hibernate) ->
    arm_or_stop(Socket, Data, []).

%% Named continue functions used by `apply_handler_result` — pass these
%% by reference instead of allocating a closure per invocation.
%% `process_buffer/2` (already named) is the continue for handle_frame.
-spec continue_arm(#data{}, boolean()) -> gen_statem:event_handler_result(atom()).
continue_arm(#data{socket = Socket} = Data, Hibernate) ->
    arm_or_stop(Socket, Data, hibernate_actions(Hibernate)).

-spec continue_to_frame_loop(#data{}, boolean()) -> gen_statem:event_handler_result(atom()).
continue_to_frame_loop(Data, true) ->
    {next_state, frame_loop, Data, [hibernate]};
continue_to_frame_loop(Data, false) ->
    {next_state, frame_loop, Data}.

-spec apply_handler_result(
    roadrunner_ws_handler:result(),
    #data{},
    boolean(),
    fun((#data{}, boolean()) -> gen_statem:event_handler_result(atom()))
) -> gen_statem:event_handler_result(atom()).
apply_handler_result(Result, Data, Hibernate, Continue) ->
    case Result of
        {reply, OutFrames, NewState} ->
            _ = send_ws_frames(Data, OutFrames),
            Continue(Data#data{mod_state = NewState}, Hibernate);
        {reply, OutFrames, NewState, Opts} when is_list(Opts) ->
            _ = send_ws_frames(Data, OutFrames),
            Continue(
                Data#data{mod_state = NewState},
                Hibernate orelse lists:member(hibernate, Opts)
            );
        {ok, NewState} ->
            Continue(Data#data{mod_state = NewState}, Hibernate);
        {ok, NewState, Opts} when is_list(Opts) ->
            Continue(
                Data#data{mod_state = NewState},
                Hibernate orelse lists:member(hibernate, Opts)
            );
        {close, _NewState} ->
            ok = send_ws_frame(Data, close, ~""),
            {stop, normal, Data}
    end.

%% --- helpers ---

-spec ws_context(roadrunner_http1:request(), module()) -> map().
ws_context(Req, Mod) ->
    #{
        listener_name => maps:get(listener_name, Req, undefined),
        peer => maps:get(peer, Req, undefined),
        request_id => maps:get(request_id, Req, undefined),
        module => Mod
    }.

-spec payload_size(roadrunner_ws:frame()) -> non_neg_integer().
payload_size(#{payload := P}) -> byte_size(P).

%% Single outbound frame — wraps `roadrunner_transport:send/2` with a
%% `[roadrunner, ws, frame_out]` event so subscribers see every frame the
%% session writes (auto-pong, close, and unary handler replies).
%%
%% When permessage-deflate is active and the opcode is text/binary the
%% payload is deflated and emitted with RSV1=1. Control frames (close
%% / ping / pong) and continuations are NEVER compressed — RFC 7692
%% §6.1 forbids compressing control frames; continuations carry no
%% RSV1 even inside a compressed message (we never emit a
%% multi-fragment outbound message anyway, so the question is moot).
-spec send_ws_frame(#data{}, roadrunner_ws:opcode(), iodata()) -> ok.
send_ws_frame(#data{socket = Socket, ctx = Ctx} = Data, Opcode, Payload) ->
    ok = roadrunner_telemetry:ws_frame_out(
        Ctx#{opcode => Opcode}, iolist_size(Payload)
    ),
    Encoded = encode_outbound(Data, Opcode, Payload),
    _ = roadrunner_transport:send(Socket, Encoded),
    ok.

%% Batched outbound frames from a handler `{reply, [...]}` return —
%% emit telemetry per frame (so subscribers can count by opcode), then
%% write all frames in a single TCP send to avoid partial-write
%% fragmentation.
-spec send_ws_frames(#data{}, [{roadrunner_ws:opcode(), iodata()}]) ->
    ok | {error, term()}.
send_ws_frames(#data{socket = Socket, ctx = Ctx} = Data, OutFrames) ->
    lists:foreach(
        fun({Op, Payload}) ->
            ok = roadrunner_telemetry:ws_frame_out(
                Ctx#{opcode => Op}, iolist_size(Payload)
            )
        end,
        OutFrames
    ),
    Iodata = [encode_outbound(Data, Op, Payload) || {Op, Payload} <- OutFrames],
    roadrunner_transport:send(Socket, Iodata).

-spec encode_outbound(#data{}, roadrunner_ws:opcode(), iodata()) -> iodata().
encode_outbound(#data{pmd_params = undefined}, Opcode, Payload) ->
    %% No PMD negotiated — straight encode.
    roadrunner_ws:encode_frame(Opcode, Payload, true);
encode_outbound(_Data, Opcode, Payload) when
    Opcode =:= close; Opcode =:= ping; Opcode =:= pong; Opcode =:= continuation
->
    %% Control frames must not be compressed (RFC 7692 §6.1). We
    %% never emit continuation outbound either, but treat it the
    %% same as a control for safety.
    roadrunner_ws:encode_frame(Opcode, Payload, true);
encode_outbound(Data, Opcode, Payload) ->
    %% text / binary with PMD — deflate, strip per-message tail,
    %% emit single frame with RSV1=1.
    Compressed = deflate_message(Data, Payload),
    roadrunner_ws:encode_frame(Opcode, Compressed, true, #{rsv1 => true}).

%% Deflate a full message payload. Reads inside `try` so a zlib
%% failure (e.g. context corruption) gives a clean session exit
%% rather than a bare badmatch in the calling shape. Strips the
%% trailing 4-byte deflate tail per RFC 7692 §7.2.1 — receivers
%% append it back before inflating.
-spec deflate_message(#data{}, iodata()) -> binary().
deflate_message(#data{deflate_z = Z, pmd_params = Params}, Payload) ->
    Iolist = zlib:deflate(Z, Payload, sync),
    case maps:get(server_no_context_takeover, Params, false) of
        true -> ok = zlib:deflateReset(Z);
        false -> ok
    end,
    Bin = iolist_to_binary(Iolist),
    %% Strip the per-message tail (last 4 bytes of `0x00 0x00 0xff 0xff`).
    %% `sync` flush always emits these, so it's safe to chop.
    Size = byte_size(Bin),
    binary:part(Bin, 0, Size - 4).
