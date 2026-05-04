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
    %% In-progress message reassembly state. WebSocket data messages
    %% (text / binary) MAY span multiple fragments at the wire level
    %% (RFC 6455 §5.4). The session reassembles them before dispatch
    %% so the user handler always sees a complete message. Control
    %% frames may interleave between data fragments and don't disturb
    %% this state.
    %%
    %% `msg_acc = undefined` means no fragmented message is in
    %% progress. While in progress, the iodata accumulates fragment
    %% payloads (still compressed when `msg_compressed` is true);
    %% `msg_opcode` is the leading frame's opcode (text | binary)
    %% used to dispatch the complete message.
    msg_acc :: undefined | iodata(),
    msg_opcode :: undefined | text | binary,
    msg_compressed :: boolean(),
    %% Trailing UTF-8 bytes carried over from a previous fragment that
    %% form the start of a multi-byte sequence whose continuation
    %% bytes haven't arrived yet. RFC 6455 §8.1 + §5.4 require that
    %% text-message UTF-8 be validated **incrementally** (close 1007
    %% as soon as an invalid sequence is detected, not just at
    %% end-of-message). At most 3 bytes — the longest valid prefix of
    %% an incomplete UTF-8 sequence is 3 bytes (4-byte sequences are
    %% the maximum). Reset to `<<>>` between messages.
    %% NOT used for compressed messages — the compressed wire bytes
    %% aren't UTF-8 until inflated; validation runs on the inflated
    %% binary at FIN time.
    utf8_pending = <<>> :: binary(),
    %% Count of payload bytes already validated for the in-progress
    %% frame at the wire level. Lets the session sneak-peek the
    %% buffer between TCP chunks of a text frame and validate ONLY
    %% the new bytes — Autobahn 6.4.3/6.4.4 fail-fast cases where the
    %% invalid UTF-8 sequence arrives mid-frame across multiple TCP
    %% packets. Reset on every complete frame parse.
    frame_validated = 0 :: non_neg_integer()
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
                msg_acc = undefined,
                msg_opcode = undefined,
                msg_compressed = false,
                utf8_pending = <<>>,
                frame_validated = 0
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
    case early_validate_text(Data, Buf, Opts) of
        {ok, Data1} ->
            case roadrunner_ws:parse_frame(Buf, Opts) of
                {ok, Frame, NewBuffer} ->
                    ok = roadrunner_telemetry:ws_frame_in(
                        (Data1#data.ctx)#{opcode => maps:get(opcode, Frame)},
                        payload_size(Frame)
                    ),
                    %% Frame parsed. Carry `frame_validated` into
                    %% handle_frame so accumulate_fragment can skip
                    %% redundant per-fragment UTF-8 validation. The
                    %% reset happens AFTER fragment-level dispatch
                    %% (in `reset_msg/1`), so the next frame's
                    %% wire-level cursor starts from zero.
                    handle_frame(
                        Frame,
                        Data1#data{buffer = NewBuffer},
                        HibernateAcc
                    );
                {more, _} ->
                    arm_or_stop(Socket, Data1, hibernate_actions(HibernateAcc));
                {error, _} ->
                    {stop, normal, Data1}
            end;
        invalid_utf8 ->
            close_with(close_invalid_payload(), reset_msg(Data))
    end.

%% Sneak-peek a partially-buffered frame and validate any NEW
%% text-payload bytes that have arrived since the last process_buffer
%% pass. This is the fail-fast path for Autobahn 6.4.3/6.4.4 cases —
%% invalid UTF-8 spread across multiple TCP chunks of a SINGLE frame
%% gets caught before the frame even completes.
%%
%% Skipped when the in-progress frame isn't a fresh text data frame
%% (binary, control, continuation, or compressed all bypass — they
%% have their own validation paths or no encoding constraint).
-spec early_validate_text(#data{}, binary(), roadrunner_ws:parse_opts()) ->
    {ok, #data{}} | invalid_utf8.
early_validate_text(Data, Buf, Opts) ->
    case roadrunner_ws:peek_frame_header(Buf, Opts) of
        {ok,
            #{
                opcode := text,
                rsv1 := false,
                mask_key := MaskKey,
                payload_offset := Off,
                total_payload_len := TotalLen
            },
            Available} ->
            #data{frame_validated = AlreadyValidated, utf8_pending = Pending} = Data,
            ToValidate = min(Available, TotalLen) - AlreadyValidated,
            case ToValidate > 0 of
                false ->
                    {ok, Data};
                true ->
                    Slice = binary:part(Buf, Off + AlreadyValidated, ToValidate),
                    Unmasked = unmask_slice(Slice, MaskKey, AlreadyValidated),
                    case validate_incremental(text, false, Pending, Unmasked) of
                        {ok, NewPending} ->
                            {ok, Data#data{
                                utf8_pending = NewPending,
                                frame_validated = AlreadyValidated + ToValidate
                            }};
                        invalid_utf8 ->
                            invalid_utf8
                    end
            end;
        _ ->
            %% Header isn't peekable yet, OR the in-progress frame
            %% isn't a fresh uncompressed text frame — skip early
            %% validation. parse_frame will catch protocol errors;
            %% UTF-8 validation happens at fragment / FIN time.
            {ok, Data}
    end.

%% Unmask `Slice` where its first byte sits at `Offset` into the
%% logical payload (so the mask-key cycle is right). RFC 6455 §5.3
%% mask: payload[i] = masked[i] XOR maskKey[i mod 4].
-spec unmask_slice(binary(), binary(), non_neg_integer()) -> binary().
unmask_slice(Slice, MaskKey, Offset) ->
    iolist_to_binary(unmask_slice_loop(Slice, MaskKey, Offset)).

-spec unmask_slice_loop(binary(), binary(), non_neg_integer()) -> [byte()].
unmask_slice_loop(<<>>, _MaskKey, _I) ->
    [];
unmask_slice_loop(<<B, Rest/binary>>, MaskKey, I) ->
    M = binary:at(MaskKey, I rem 4),
    [B bxor M | unmask_slice_loop(Rest, MaskKey, I + 1)].

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
    %% Data frames (text / binary / continuation). Per RFC 6455 §5.4 a
    %% message MAY be fragmented across multiple frames at the wire
    %% level; the session reassembles them and dispatches the COMPLETE
    %% message to the user handler. Per RFC 7692, the first fragment
    %% of a compressed message has RSV1=1 — we track that flag for the
    %% whole message so the FIN handler knows to inflate.
    case classify_data_frame(Frame, Data) of
        {message_start, NewData} ->
            accumulate_fragment(Frame, NewData, Hibernate);
        message_continuation ->
            accumulate_fragment(Frame, Data, Hibernate);
        protocol_error ->
            %% Continuation arrived without a non-FIN start frame, OR
            %% a new data frame arrived mid-message. RFC 6455 §5.4
            %% says close with code 1002.
            close_with(close_protocol_error(), Data)
    end.

%% RFC 6455 §5.4 fragmentation rules:
%%   - Data message starts with text/binary, FIN=0 (multi-fragment) or
%%     FIN=1 (single-fragment).
%%   - Continuation frames carry on the message; FIN=1 closes it.
%%   - Once a non-FIN message has started, NO new text/binary may
%%     arrive until FIN; only continuations are valid mid-message.
-spec classify_data_frame(roadrunner_ws:frame(), #data{}) ->
    {message_start, #data{}} | message_continuation | protocol_error.
classify_data_frame(#{opcode := continuation}, #data{msg_acc = undefined}) ->
    protocol_error;
classify_data_frame(#{opcode := continuation}, _Data) ->
    message_continuation;
classify_data_frame(#{opcode := Op}, #data{msg_acc = Acc}) when
    Acc =/= undefined, (Op =:= text orelse Op =:= binary)
->
    protocol_error;
classify_data_frame(#{rsv1 := Rsv1, opcode := Op}, Data) when Op =:= text orelse Op =:= binary ->
    {message_start, Data#data{msg_opcode = Op, msg_compressed = Rsv1}}.

-spec accumulate_fragment(roadrunner_ws:frame(), #data{}, boolean()) ->
    gen_statem:event_handler_result(atom()).
accumulate_fragment(
    #{fin := false, payload := P} = _Frame,
    #data{msg_acc = Acc, msg_opcode = Op, msg_compressed = Compressed} = Data,
    Hibernate
) ->
    case fragment_validate(Op, Compressed, Data#data.utf8_pending, P, Data) of
        {ok, NewPending} ->
            NewAcc =
                case Acc of
                    undefined -> [P];
                    _ -> [Acc, P]
                end,
            process_buffer(
                Data#data{
                    msg_acc = NewAcc,
                    utf8_pending = NewPending,
                    %% Reset wire-level cursor so the NEXT frame's
                    %% bytes are validated from scratch when they
                    %% arrive.
                    frame_validated = 0
                },
                Hibernate
            );
        invalid_utf8 ->
            %% RFC 6455 §8.1: close 1007 on the first invalid UTF-8
            %% byte sequence — don't wait for FIN.
            close_with(close_invalid_payload(), reset_msg(Data))
    end;
accumulate_fragment(
    #{fin := true, payload := P} = _Frame,
    #data{
        msg_acc = Acc,
        msg_opcode = Op,
        msg_compressed = Compressed,
        utf8_pending = Pending
    } = Data,
    Hibernate
) ->
    case fragment_validate_fin(Op, Compressed, Pending, P, Data) of
        ok ->
            AssembledIolist =
                case Acc of
                    undefined -> [P];
                    _ -> [Acc, P]
                end,
            Reset = reset_msg(Data),
            case finalize_message(Reset, AssembledIolist, Compressed) of
                {ok, Payload, Data1} ->
                    %% For compressed messages, finalize_message inflated
                    %% the bytes — UTF-8 must be checked on the inflated
                    %% binary (the wire bytes are deflate-compressed, not
                    %% UTF-8). For uncompressed messages, validation has
                    %% already run incrementally above; skip redundant
                    %% full-message revalidation.
                    case post_finalize_validate(Op, Compressed, Payload) of
                        ok ->
                            Synthesized = #{
                                fin => true,
                                rsv1 => false,
                                opcode => Op,
                                payload => Payload
                            },
                            dispatch_data_frame(Synthesized, Data1, Hibernate);
                        invalid_utf8 ->
                            close_with(close_invalid_payload(), Data1)
                    end;
                {error, _} ->
                    close_with(close_protocol_error(), Reset)
            end;
        invalid_utf8 ->
            close_with(close_invalid_payload(), reset_msg(Data))
    end.

%% Validate the FIN fragment's bytes against the carried pending
%% prefix. For text messages, the fragment must complete any
%% in-progress sequence — incomplete UTF-8 trailing the message is
%% invalid. Compressed messages defer validation to post_finalize
%% because the wire bytes are deflate, not UTF-8.
-spec validate_fin_fragment(text | binary, boolean(), binary(), binary()) ->
    ok | invalid_utf8.
validate_fin_fragment(binary, _Compressed, _Pending, _Bytes) ->
    ok;
validate_fin_fragment(text, true, _Pending, _Bytes) ->
    ok;
validate_fin_fragment(text, false, Pending, Bytes) ->
    Combined = <<Pending/binary, Bytes/binary>>,
    case unicode:characters_to_binary(Combined, utf8, utf8) of
        Bin when is_binary(Bin) -> ok;
        %% Trailing bytes that didn't form a complete sequence are
        %% invalid at FIN time per RFC 6455 §8.1.
        {incomplete, _, _} -> invalid_utf8;
        {error, _, _} -> invalid_utf8
    end.

%% Skip fragment-level UTF-8 validation when the wire-level
%% `early_validate_text` already processed every byte of this
%% fragment (or the fragment is empty / non-text where validation is
%% a no-op anyway).
-spec fragment_validate(text | binary, boolean(), binary(), binary(), #data{}) ->
    {ok, binary()} | invalid_utf8.
fragment_validate(_Op, _Compressed, Pending, P, #data{frame_validated = Cursor}) when
    Cursor >= byte_size(P)
->
    {ok, Pending};
fragment_validate(Op, Compressed, Pending, P, _Data) ->
    validate_incremental(Op, Compressed, Pending, P).

%% Same idea for FIN: wire-level already validated, but FIN brings
%% the additional constraint that no incomplete sequence may trail
%% the message.
-spec fragment_validate_fin(text | binary, boolean(), binary(), binary(), #data{}) ->
    ok | invalid_utf8.
fragment_validate_fin(Op, Compressed, Pending, P, #data{frame_validated = Cursor}) when
    Cursor >= byte_size(P)
->
    case {Op, Compressed} of
        {text, false} when Pending =/= <<>> -> invalid_utf8;
        _ -> ok
    end;
fragment_validate_fin(Op, Compressed, Pending, P, _Data) ->
    validate_fin_fragment(Op, Compressed, Pending, P).

%% Compressed messages need their inflated payload validated; their
%% wire bytes are deflate, so per-fragment UTF-8 validation was
%% skipped. Uncompressed messages were validated incrementally and
%% don't need a redundant full-message check.
-spec post_finalize_validate(text | binary, boolean(), binary()) ->
    ok | invalid_utf8.
post_finalize_validate(text, true, Payload) ->
    validate_text_payload(text, Payload);
post_finalize_validate(_Op, _Compressed, _Payload) ->
    ok.

-spec reset_msg(#data{}) -> #data{}.
reset_msg(Data) ->
    Data#data{
        msg_acc = undefined,
        msg_opcode = undefined,
        msg_compressed = false,
        utf8_pending = <<>>,
        frame_validated = 0
    }.

%% RFC 6455 §8.1 strict UTF-8 validation: validate each text-fragment
%% payload as it arrives rather than waiting for FIN. Carries forward
%% any trailing **incomplete** multi-byte sequence (legitimate — its
%% continuation bytes will arrive in the next fragment) but rejects
%% any **invalid** sequence immediately.
%%
%% Skipped for binary messages (no encoding requirement) and for
%% compressed messages (the wire bytes are deflate-compressed, not
%% UTF-8; the inflated payload is validated at FIN time instead).
-spec validate_incremental(text | binary, boolean(), binary(), binary()) ->
    {ok, NewPending :: binary()} | invalid_utf8.
validate_incremental(binary, _Compressed, _Pending, _Bytes) ->
    {ok, <<>>};
validate_incremental(text, true, _Pending, _Bytes) ->
    {ok, <<>>};
validate_incremental(text, false, Pending, Bytes) ->
    Combined = <<Pending/binary, Bytes/binary>>,
    case unicode:characters_to_binary(Combined, utf8, utf8) of
        Bin when is_binary(Bin) ->
            %% Fully-valid (no trailing incomplete sequence).
            {ok, <<>>};
        {incomplete, _Valid, Incomplete} ->
            %% Valid up to a trailing incomplete sequence. Most are
            %% legitimately mid-codepoint, but some byte combos are
            %% already provably-invalid before all continuation bytes
            %% arrive — fail-fast on those per RFC 6455 §8.1.
            case incomplete_is_provably_invalid(Incomplete) of
                true -> invalid_utf8;
                false -> {ok, Incomplete}
            end;
        {error, _Valid, _Rest} ->
            invalid_utf8
    end.

%% Detect UTF-8 byte prefixes that can't extend to any valid codepoint
%% even with more continuation bytes. Catches Autobahn 6.4.x cases —
%% out-of-range codepoints (F4 9X+...), overlongs (E0 0..9F, F0 0..8F),
%% surrogates (ED A0..BF), and 5/6-byte legacy starts (F5..FF).
-spec incomplete_is_provably_invalid(binary()) -> boolean().
incomplete_is_provably_invalid(<<16#F4, B, _/binary>>) when B >= 16#90 -> true;
incomplete_is_provably_invalid(<<16#E0, B, _/binary>>) when B < 16#A0 -> true;
incomplete_is_provably_invalid(<<16#ED, B, _/binary>>) when B >= 16#A0 -> true;
incomplete_is_provably_invalid(<<16#F0, B, _/binary>>) when B < 16#90 -> true;
%% F5..FF as a leading byte is always invalid — no codepoint mapping.
incomplete_is_provably_invalid(<<F, _/binary>>) when F >= 16#F5 -> true;
incomplete_is_provably_invalid(_) -> false.

%% Returns either a plain assembled binary (when the message was
%% uncompressed) or the inflated bytes (when RSV1 was set on the
%% start frame).
-spec finalize_message(#data{}, iodata(), boolean()) ->
    {ok, binary(), #data{}} | {error, term()}.
finalize_message(Data, Iolist, false) ->
    {ok, iolist_to_binary(Iolist), Data};
finalize_message(#data{inflate_z = Z, pmd_params = Params} = Data, Iolist, true) ->
    Compressed = iolist_to_binary([Iolist, ?PMD_TAIL]),
    try
        Inflated = iolist_to_binary(zlib:inflate(Z, Compressed)),
        case maps:get(client_no_context_takeover, Params, false) of
            true -> ok = zlib:inflateReset(Z);
            false -> ok
        end,
        {ok, Inflated, Data}
    catch
        _:Reason -> {error, Reason}
    end.

%% RFC 6455 §8.1: text-message payloads MUST be valid UTF-8. Binary
%% payloads have no encoding constraint.
%% Only called for `text` opcodes via `post_finalize_validate`. The
%% `binary` case short-circuits earlier (no encoding constraint).
-spec validate_text_payload(text, binary()) -> ok | invalid_utf8.
validate_text_payload(text, Payload) ->
    case unicode:characters_to_binary(Payload, utf8, utf8) of
        Payload -> ok;
        _ -> invalid_utf8
    end.

%% RFC 6455 §7.4: 1002 = protocol error.
-spec close_protocol_error() -> binary().
close_protocol_error() ->
    <<1002:16>>.

%% RFC 6455 §7.4: 1007 = invalid frame payload data (e.g. bad UTF-8 in
%% a text frame).
-spec close_invalid_payload() -> binary().
close_invalid_payload() ->
    <<1007:16>>.

-spec close_with(binary(), #data{}) -> {stop, normal, #data{}}.
close_with(StatusBin, Data) ->
    ok = send_ws_frame(Data, close, StatusBin),
    {stop, normal, Data}.

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
