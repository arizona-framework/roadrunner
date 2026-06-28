-module(roadrunner_ws_session).
-moduledoc false.

%% Per-connection WebSocket session — runs the frame loop in its own
%% hand-rolled `proc_lib` process (never a gen_statem, mirroring
%% `roadrunner_conn_loop_http2` / `roadrunner_quic_connection`) after
%% `roadrunner_conn:upgrade_to_websocket/4` hands the socket off.
%%
%% The session owns the socket for its lifetime: the parent `roadrunner_conn`
%% launcher (`run/4`) starts the session, transfers controlling-process,
%% sends the `socket_ready` startup signal (mirroring the conn's `shoot`
%% pattern), and waits via a monitor for the session to terminate.
%% When the session exits — peer close frame, recv error, frame parse
%% error, or handler-driven `{close, _}` — the launcher returns and the
%% parent's `[roadrunner, listener, conn_close]` telemetry fires after.
%%
%% Phases (plain functions, not gen_statem states):
%% - `awaiting_socket/1` — a selective `receive socket_ready` that gates
%%   the frame loop until controlling-process has transferred and the
%%   launcher has sent `socket_ready`. A drain (or stray) arriving first
%%   stays queued and is handled by `recv_loop` afterwards.
%% - `recv_loop/1` — parse/dispatch frames as they arrive; the socket is
%%   in active-once mode so bytes arrive as messages and the process is
%%   back in its `receive` between frames.
%%
%% ## Active-mode reads
%%
%% The loop uses active-once reads (`roadrunner_transport:setopts(_,
%% [{active, once}])`): `arm_and_recv/2` arms then receives, so between
%% frames the process is idle in `receive` and an `erlang:hibernate/3`
%% continuation can take effect. Without active mode we'd be blocked
%% inside `roadrunner_transport:recv/3` and hibernation would be a no-op.
%%
%% ## Handler hibernation opt-in
%%
%% The `roadrunner_ws_handler` callback supports an optional 4-tuple
%% return shape: `{reply, OutFrames, NewState, Opts}` and
%% `{ok, NewState, Opts}`, where `Opts` is a list that may contain
%% `hibernate`. When present, the process hibernates after this
%% event is fully processed — process heap drops to ~1KB until the
%% next inbound frame wakes it up. For an idle WebSocket session
%% this is the difference between holding ~5–8KB of process memory
%% indefinitely vs. ~1KB.
%%
%% 3-tuple returns (`{reply, OutFrames, NewState}`, `{ok, NewState}`,
%% `{close, NewState}`) stay valid — the 4-tuple is purely additive.
%%
%% ## Optional handler callbacks
%%
%% `init/1` runs once on the awaiting_socket → frame_loop transition,
%% **before** the first inbound frame; the handler can push priming
%% frames or refuse the session by returning `{close, _}`. `handle_info/2`
%% receives any non-transport info message (a pubsub broadcast a handler
%% subscribed to in `init/1`, an exit signal from a linked worker, etc.)
%% and returns the same shape as `handle_frame/2`. Both are
%% `-optional_callbacks` — handlers that don't export them get the
%% old behavior (no init action, stray info dropped silently). Whether
%% each is exported is cached in `#data` at session start so the BIF
%% check doesn't run on every event.
%%
%% Telemetry: `[roadrunner, ws, upgrade]` fires from `run/6` once the
%% launcher has decided to enter the session; `[roadrunner, ws, frame_in]`
%% and `[roadrunner, ws, frame_out]` fire from the session process for
%% every frame.

-export([run/6]).
-export([init_session/2]).
-export([recv_loop/1]).
-export([unmask_slice/3]).

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
    has_handle_drain :: boolean(),
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
    %% Inbound size caps (from listener `proto_opts`, set once in
    %% `init/1`). `max_frame_size` bounds a single frame's declared
    %% payload — enforced in `process_buffer/2` against the peeked
    %% header before the body is buffered. `max_message_size` bounds a
    %% reassembled message via `msg_size`, the running charged size of
    %% the fragments (each charged at least `?WS_FRAGMENT_OVERHEAD` so
    %% empty/tiny fragments can't grow `msg_acc` unbounded); under
    %% permessage-deflate it also caps the decompressed size
    %% (`finalize_message/3`). Over either cap closes with 1009.
    max_frame_size :: non_neg_integer(),
    max_message_size :: non_neg_integer(),
    msg_size = 0 :: non_neg_integer(),
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
    frame_validated = 0 :: non_neg_integer(),
    %% The cumulative UNMASKED bytes of the in-progress frame —
    %% accumulated by `early_validate_text/3` as a side-effect of the
    %% byte-level UTF-8 check it runs. When this buffer's size reaches
    %% the frame's total payload length we hand it directly to
    %% `roadrunner_ws:parse_frame/2` (via the `pre_unmasked` opt)
    %% instead of letting it re-unmask the masked bytes — which on
    %% 1 KB+ text frames was 40% of own time per fprof. Reset
    %% alongside `frame_validated`.
    unmasked_buf = <<>> :: binary()
}).

%% Per-message DEFLATE trailer (RFC 7692 §7.2.1). Sender strips it
%% from the deflate output; receiver appends it before inflating to
%% terminate the deflate block.
-define(PMD_TAIL, <<0, 0, 16#FF, 16#FF>>).

%% Per-fragment charge (bytes) added to the running message size on top
%% of the payload. Each accumulated fragment costs ~32 bytes of cons
%% cells in `msg_acc` regardless of its payload, so without a floor a
%% flood of empty/tiny continuation frames would grow the heap while
%% the payload-byte total stayed under `max_message_size`. Charging at
%% least this much per fragment keeps real reassembly memory bounded by
%% the cap (this is ~2x the actual cons-cell cost, a safe over-estimate).
-define(WS_FRAGMENT_OVERHEAD, 64).

-doc """
Run the WebSocket session synchronously: spawn the session process,
write the 101 upgrade response, transfer socket ownership, and
await termination. The process is started **before** the 101
hits the wire so a start failure can fall back to 500 without
leaving the upgrade response sent with no process owning the
socket. Returns `ok` once the session has ended (or the
handshake check fails — in which case 400 has been sent and
the session is never started).

`Buffered` is any bytes the conn already read past the upgrade request
(a client that pipelines its first frame in the handshake segment).
They seed the session buffer so the first frame isn't lost.
""".
-spec run(
    roadrunner_transport:socket(),
    roadrunner_req:request(),
    module(),
    term(),
    binary(),
    roadrunner_conn:proto_opts()
) -> ok.
run(Socket, Req, Mod, State, Buffered, ProtoOpts) ->
    case roadrunner_ws:handshake_response(roadrunner_req:headers(Req)) of
        {ok, Status, RespHeaders, _, Negotiated} ->
            UpgradeResp = roadrunner_http1:response(Status, RespHeaders, ~""),
            run_session(Socket, Req, Mod, State, UpgradeResp, Negotiated, Buffered, ProtoOpts);
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
    roadrunner_req:request(),
    module(),
    term(),
    iodata(),
    roadrunner_ws:negotiated(),
    binary(),
    roadrunner_conn:proto_opts()
) -> ok.
run_session(
    Socket,
    Req,
    Mod,
    State,
    UpgradeResp,
    Negotiated,
    Buffered,
    #{handler_spawn_opts := SpawnOpts, handler_start_timeout := StartTimeout} = ProtoOpts
) ->
    Ctx = ws_context(Req, Mod),
    %% Start the session **before** writing the 101 to the wire so a
    %% start failure never leaves the upgrade response sent with no
    %% process owning the socket. `proc_lib:start` (not `start_link`) —
    %% the conn is intentionally unlinked from its children so a session
    %% crash never propagates to the conn process; we synchronise via a
    %% monitor instead. `init_session/2` validates the handler and
    %% `init_ack`s `{ok, _}` | `{error, {bad_handler, _}}` before the 101,
    %% so a bad handler still yields a 500 with no 101 on the wire.
    case
        proc_lib:start(
            ?MODULE,
            init_session,
            [self(), {Socket, Mod, State, Ctx, Negotiated, Buffered, ProtoOpts}],
            StartTimeout,
            SpawnOpts
        )
    of
        {ok, Pid} ->
            ok = roadrunner_telemetry:ws_upgrade(Ctx),
            _ = roadrunner_telemetry:response_send(
                roadrunner_transport:send(Socket, UpgradeResp), websocket_upgrade_response
            ),
            Ref = monitor(process, Pid),
            ok = roadrunner_transport:controlling_process(Socket, Pid),
            Pid ! socket_ready,
            wait_for_session(Ref, Pid);
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

%% The conn process is already a member of the listener's drain `pg`
%% group via `roadrunner_conn:join_drain_group/2` (joined at conn
%% start). While the conn waits here for the session to terminate,
%% forward any `{roadrunner_drain, _}` broadcast to the session pid so
%% the session's `frame_loop` can dispatch `handle_drain/2`. This
%% avoids a per-session `pg:join` on the WS upgrade hot path: that
%% per-session join doubled the rate of joins through the single `pg`
%% scope process and serialized the upgrade hot path under load.
-spec wait_for_session(reference(), pid()) -> ok.
wait_for_session(Ref, Pid) ->
    receive
        {'DOWN', Ref, process, Pid, _Reason} ->
            ok;
        {roadrunner_drain, _Deadline} = Msg ->
            Pid ! Msg,
            wait_for_session(Ref, Pid)
    end.

%% proc_lib entry (started via `proc_lib:start/5` from `run_session/8`).
%% Validates the handler and `init_ack`s the outcome to the launcher
%% BEFORE the 101 is written: `{ok, self()}` lets the launcher send the
%% 101, `{error, {bad_handler, _}}` makes `proc_lib:start` return an
%% error so the launcher's 500 fallback runs with no 101 on the wire.
-spec init_session(pid(), {
    roadrunner_transport:socket(),
    module(),
    term(),
    map(),
    roadrunner_ws:negotiated(),
    binary(),
    roadrunner_conn:proto_opts()
}) -> ok | no_return().
init_session(Parent, {Socket, Mod, State, Ctx, Negotiated, Buffered, ProtoOpts}) ->
    proc_lib:set_label({?MODULE, maps:get(listener_name, Ctx, undefined)}),
    case
        code:ensure_loaded(Mod) =:= {module, Mod} andalso
            erlang:function_exported(Mod, handle_frame, 2)
    of
        true ->
            {PmdParams, InflateZ, DeflateZ} = init_pmd(Negotiated),
            #{
                ws_max_frame_size := MaxFrame,
                ws_max_message_size := MaxMsg
            } = ProtoOpts,
            Data = #data{
                socket = Socket,
                buffer = Buffered,
                mod = Mod,
                mod_state = State,
                ctx = Ctx,
                has_init = erlang:function_exported(Mod, init, 1),
                has_handle_info = erlang:function_exported(Mod, handle_info, 2),
                has_handle_drain = erlang:function_exported(Mod, handle_drain, 2),
                pmd_params = PmdParams,
                inflate_z = InflateZ,
                deflate_z = DeflateZ,
                max_frame_size = MaxFrame,
                max_message_size = MaxMsg,
                msg_acc = undefined,
                msg_opcode = undefined,
                msg_compressed = false,
                msg_size = 0,
                utf8_pending = <<>>,
                frame_validated = 0,
                unmasked_buf = <<>>
            },
            proc_lib:init_ack(Parent, {ok, self()}),
            awaiting_socket(Data);
        false ->
            proc_lib:init_ack(Parent, {error, {bad_handler, Mod}})
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

%% Gate the loop until the launcher hands the socket over. A selective
%% receive on `socket_ready` only: a `{roadrunner_drain, _}` (or any
%% stray) that arrives first stays queued and is handled by `recv_loop`
%% after the optional handler `init/1` runs — the proc_lib equivalent of
%% the old gen_statem `[postpone]`, and it keeps `init/1` firing once,
%% before any frame.
-spec awaiting_socket(#data{}) -> no_return().
awaiting_socket(#data{has_init = true, mod = Mod, mod_state = State} = Data) ->
    receive
        socket_ready ->
            apply_handler_result(Mod:init(State), Data, false, fun enter_frame_loop/2)
    end;
awaiting_socket(Data) ->
    receive
        socket_ready -> enter_frame_loop(Data, false)
    end.

%% Enter the frame loop. A client that pipelined its first frame in the
%% same segment as the upgrade handshake had those bytes seeded into the
%% buffer at init — process them before arming; otherwise arm and wait.
%% `Hibernate` carries a handler `init/1` hibernate opt to the first park.
-spec enter_frame_loop(#data{}, boolean()) -> no_return().
enter_frame_loop(#data{buffer = <<>>} = Data, Hibernate) ->
    arm_and_recv(Data, Hibernate);
enter_frame_loop(Data, Hibernate) ->
    process_buffer(Data, Hibernate).

%% Inbound frame loop. `arm_and_recv/2` arms the socket active-once before
%% each receive, so between frames the process is idle here and a
%% hibernate continuation can take effect. `{system,_,_}` / `'$gen_call'`
%% / `'$gen_cast'` are handled via `roadrunner_loop_sys` (preserving the
%% OTP sys protocol) BEFORE the `Other -> handle_info_msg` catch-all, so a
%% system message never leaks to the handler's `handle_info/2`. Only a
%% data message consumes the active-once; sys / cast / info do not, so
%% those clauses loop without re-arming. `_Sock` is discarded — one socket
%% per session, captured in `#data.socket` at init.
-spec recv_loop(#data{}) -> no_return().
recv_loop(#data{socket = Socket} = Data) ->
    {DataTag, ClosedTag, ErrorTag} = roadrunner_transport:messages(Socket),
    receive
        {system, From, Req} ->
            roadrunner_loop_sys:handle_system(Req, From, Data, fun recv_loop/1);
        {'$gen_call', From, _Request} ->
            ok = roadrunner_loop_sys:gen_call_unsupported(From),
            recv_loop(Data);
        {'$gen_cast', _Request} ->
            recv_loop(Data);
        {DataTag, _Sock, Bytes} ->
            process_buffer(append_buffer(Data, Bytes), false);
        {ClosedTag, _Sock} ->
            exit_clean(Data);
        {ErrorTag, _Sock, _Reason} ->
            exit_clean(Data);
        {roadrunner_drain, Deadline} ->
            %% Drain broadcast — dispatch to optional handle_drain/2 and
            %% drop. Drain messages never reach handle_info/2 so handlers
            %% don't have to pattern-match on a framework-internal shape.
            handle_drain_msg(Deadline, Data, false);
        Other ->
            %% Forward to handler's optional handle_info/2 if exported,
            %% otherwise drop. Mirrors handle_frame's reply / hibernate /
            %% close return shapes.
            handle_info_msg(Other, Data, false)
    end.

%% Release the permessage-deflate zlib contexts (was `terminate/3`) and
%% exit normally. All normal termination paths funnel through here; the
%% runtime would reclaim the zlib NIF resources on process exit anyway,
%% but explicit release reclaims their working buffers immediately rather
%% than waiting on GC. A crash skips this and relies on that GC. The
%% launcher's monitor sees `{'DOWN', _, _, _, normal}` and returns.
-spec exit_clean(#data{}) -> no_return().
exit_clean(#data{inflate_z = InflateZ, deflate_z = DeflateZ}) ->
    close_zlib(InflateZ),
    close_zlib(DeflateZ),
    exit(normal).

-spec close_zlib(zlib:zstream() | undefined) -> ok.
close_zlib(undefined) -> ok;
close_zlib(Z) -> zlib:close(Z).

%% --- frame dispatch ---

%% Drain every complete frame out of the buffer in a single pass,
%% accumulating any handler-requested `hibernate` opt. When the buffer
%% doesn't hold a full frame, re-arm the socket (hibernating first if a
%% handler asked) and wait for more bytes.
-spec process_buffer(#data{}, boolean()) -> no_return().
process_buffer(#data{buffer = Buf, pmd_params = Pmd} = Data, HibernateAcc) ->
    Opts =
        case Pmd of
            undefined -> #{};
            _ -> #{allow_rsv1 => true}
        end,
    case early_validate_text(Data, Buf, Opts) of
        {frame, #{total_payload_len := TotalLen} = Header, Data1} ->
            case frame_within_cap(TotalLen, Data1) of
                false ->
                    %% Declared frame payload exceeds `max_frame_size`.
                    %% The header is in hand but the body isn't buffered
                    %% yet — close now (RFC 6455 §7.4 code 1009) instead
                    %% of letting the `{more, _}` re-arm keep reading.
                    close_oversize(max_frame_size, TotalLen, Data1);
                true ->
                    process_parsed_frame(Data1, Buf, Header, HibernateAcc)
            end;
        {more, Data1} ->
            arm_and_recv(Data1, HibernateAcc);
        {error, _} ->
            %% RFC 6455 §5.5.1 / §7.4.1: a header-level framing violation
            %% (bad opcode, RSV, unmasked client frame, fragmented or
            %% oversize control, or a 64-bit length with the high bit set)
            %% the header peek already rejected — send a 1002 Close rather
            %% than dropping the TCP connection silently.
            close_with(close_protocol_error(), Data);
        invalid_utf8 ->
            close_with(close_invalid_payload(), reset_msg(Data))
    end.

-spec process_parsed_frame(#data{}, binary(), map(), boolean()) -> no_return().
process_parsed_frame(Data1, Buf, Header, HibernateAcc) ->
    %% `Header` was decoded by the peek in `early_validate_text/3`;
    %% `parse_frame_known` reuses it (no second decode) and only needs to
    %% confirm the body is fully buffered. Header-level protocol errors
    %% were already surfaced upstream, so there's no `{error, _}` here.
    case roadrunner_ws:parse_frame_known(Buf, Header, pre_unmasked(Data1, Header)) of
        {ok, #{opcode := Opcode} = Frame, NewBuffer} ->
            ok = roadrunner_telemetry:ws_frame_in(
                (Data1#data.ctx)#{opcode => Opcode},
                payload_size(Frame)
            ),
            %% Frame parsed. Carry `frame_validated` into handle_frame
            %% so accumulate_fragment can skip redundant per-fragment
            %% UTF-8 validation. The reset happens AFTER fragment-level
            %% dispatch (in `reset_msg/1`), so the next frame's
            %% wire-level cursor starts from zero.
            handle_frame(
                Frame,
                Data1#data{buffer = NewBuffer},
                HibernateAcc
            );
        {more, _} ->
            arm_and_recv(Data1, HibernateAcc)
    end.

%% Hand the cached unmasked payload to `parse_frame_known` when (and only
%% when) `early_validate_text/3` has unmasked the entire payload as a
%% side-effect of UTF-8 validation. Keeps the parse from redundantly
%% unmasking the same bytes a second time — saved ~40% of own time on the
%% WS text hot path.
-spec pre_unmasked(#data{}, map()) -> binary() | undefined.
pre_unmasked(#data{unmasked_buf = Buf}, #{total_payload_len := TotalLen}) when
    byte_size(Buf) =:= TotalLen, TotalLen > 0
->
    Buf;
pre_unmasked(_Data, _Header) ->
    undefined.

%% Per-frame size cap. The peeked header reveals the frame's declared
%% payload length before the body is buffered, so an oversized frame is
%% rejected on the header alone (≤14 bytes seen) rather than after the
%% `{more, _}` re-arm reads the whole payload. Only reached once the peek
%% has a full header, so the length is always known here.
-spec frame_within_cap(non_neg_integer(), #data{}) -> boolean().
frame_within_cap(TotalLen, #data{max_frame_size = Max}) ->
    TotalLen =< Max.

%% Sneak-peek a partially-buffered frame and validate any NEW
%% text-payload bytes that have arrived since the last process_buffer
%% pass. This is the fail-fast path for Autobahn 6.4.3/6.4.4 cases —
%% invalid UTF-8 spread across multiple TCP chunks of a SINGLE frame
%% gets caught before the frame even completes.
%%
%% Skipped when the in-progress frame isn't a fresh text data frame
%% (binary, control, continuation, or compressed all bypass — they
%% have their own validation paths or no encoding constraint).
%% Returns the decoded peek header so the caller hands it straight to
%% `roadrunner_ws:parse_frame_known/3` (no second header decode):
%% - `{frame, Header, Data}` — full header peeked (text payload bytes
%%   so far validated + unmasked into `Data`'s `unmasked_buf`);
%% - `{more, Data}` — header not fully buffered yet, re-arm for the rest;
%% - `{error, Reason}` — a header-level protocol violation the peek
%%   already rejects (bad opcode/RSV/length, unmasked, oversized or
%%   fragmented control), surfaced here so we don't re-decode to find it;
%% - `invalid_utf8` — a text payload byte broke UTF-8 (close 1007).
-spec early_validate_text(#data{}, binary(), roadrunner_ws:parse_opts()) ->
    {frame, map(), #data{}} | {more, #data{}} | {error, term()} | invalid_utf8.
early_validate_text(Data, Buf, Opts) ->
    case roadrunner_ws:peek_frame_header(Buf, Opts) of
        {ok,
            #{
                opcode := text,
                rsv1 := false,
                mask_key := MaskKey,
                payload_offset := Off,
                total_payload_len := TotalLen
            } = Header,
            Available} ->
            #data{
                frame_validated = AlreadyValidated,
                utf8_pending = Pending,
                unmasked_buf = UnmaskedBuf
            } = Data,
            ToValidate = min(Available, TotalLen) - AlreadyValidated,
            case ToValidate > 0 of
                false ->
                    {frame, Header, Data};
                true ->
                    Slice = binary:part(Buf, Off + AlreadyValidated, ToValidate),
                    Unmasked = unmask_slice(Slice, MaskKey, AlreadyValidated),
                    case validate_incremental(text, false, Pending, Unmasked) of
                        {ok, NewPending} ->
                            {frame, Header, Data#data{
                                utf8_pending = NewPending,
                                frame_validated = AlreadyValidated + ToValidate,
                                unmasked_buf = append_bin(UnmaskedBuf, Unmasked)
                            }};
                        invalid_utf8 ->
                            invalid_utf8
                    end
            end;
        {ok, Header, _Available} ->
            %% Header is peekable but the in-progress frame isn't a
            %% fresh uncompressed text frame (binary / control /
            %% continuation / compressed). No incremental UTF-8
            %% validation applies; hand the decoded header straight on so
            %% the parse reuses it and the size cap still sees the length.
            {frame, Header, Data};
        {more, undefined} ->
            %% Header isn't fully buffered yet — re-arm for the rest.
            {more, Data};
        {error, _} = Err ->
            Err
    end.

%% Unmask `Slice` where its first byte sits at `Offset` into the
%% logical payload (so the mask-key cycle is right). RFC 6455 §5.3
%% mask: payload[i] = masked[i] XOR maskKey[i mod 4].
-doc false.
-spec unmask_slice(binary(), binary(), non_neg_integer()) -> binary().
unmask_slice(Slice, <<MaskKey:32>>, Offset) ->
    %% Rotate the 32-bit mask so its byte at the slice's logical
    %% start lines up with bit position 0 — same trick as cowlib's
    %% `cow_ws:unmask/3`. After rotation we XOR 4 bytes at a time,
    %% 64 per recursion (16 × 32-bit words), which beats both the
    %% byte-at-a-time iolist version and a narrower 4-word pass.
    Left = (Offset rem 4) * 8,
    Right = 32 - Left,
    Rotated = (MaskKey bsl Left) + (MaskKey bsr Right),
    %% After bsl by Left bits the value can exceed 32 bits — mask
    %% back to 32 bits so the bxor in the loop preserves the byte
    %% alignment invariant.
    Rotated32 = Rotated band 16#FFFFFFFF,
    unmask_slice_chunks(Slice, Rotated32, <<>>).

-spec unmask_slice_chunks(binary(), non_neg_integer(), binary()) -> binary().
unmask_slice_chunks(
    <<O1:32, O2:32, O3:32, O4:32, O5:32, O6:32, O7:32, O8:32, O9:32, O10:32, O11:32, O12:32, O13:32,
        O14:32, O15:32, O16:32, Rest/binary>>,
    MK,
    Acc
) ->
    unmask_slice_chunks(
        Rest,
        MK,
        <<Acc/binary, (O1 bxor MK):32, (O2 bxor MK):32, (O3 bxor MK):32, (O4 bxor MK):32,
            (O5 bxor MK):32, (O6 bxor MK):32, (O7 bxor MK):32, (O8 bxor MK):32, (O9 bxor MK):32,
            (O10 bxor MK):32, (O11 bxor MK):32, (O12 bxor MK):32, (O13 bxor MK):32,
            (O14 bxor MK):32, (O15 bxor MK):32, (O16 bxor MK):32>>
    );
unmask_slice_chunks(<<O:32, Rest/binary>>, MK, Acc) ->
    T = O bxor MK,
    unmask_slice_chunks(Rest, MK, <<Acc/binary, T:32>>);
unmask_slice_chunks(<<O:24>>, MK, Acc) ->
    %% Tail of 1-3 bytes: XOR against the high bytes of the 32-bit mask
    %% (the bytes the cycle lands on next). Shifting the mask down beats
    %% repacking it into a binary and re-matching the leading bytes.
    T = O bxor (MK bsr 8),
    <<Acc/binary, T:24>>;
unmask_slice_chunks(<<O:16>>, MK, Acc) ->
    T = O bxor (MK bsr 16),
    <<Acc/binary, T:16>>;
unmask_slice_chunks(<<O:8>>, MK, Acc) ->
    T = O bxor (MK bsr 24),
    <<Acc/binary, T:8>>;
unmask_slice_chunks(<<>>, _MK, Acc) ->
    Acc.

-spec append_buffer(#data{}, binary()) -> #data{}.
append_buffer(#data{buffer = Buf} = Data, Bytes) ->
    Data#data{buffer = append_bin(Buf, Bytes)}.

%% Append `New` onto `Acc`, returning `New` untouched when `Acc` is empty.
%% The single-chunk hot path (a whole frame in one TCP read, the buffer
%% and unmasked accumulator drained, no partial UTF-8 carried over) hits
%% the empty case every time, skipping a full payload-sized copy per
%% inbound frame. Returning the bare binary also lets the UTF-8 BIF take
%% its fast binary path, which is measured well ahead of both a pre-concat
%% copy and an iodata list (the BIF walks a list far slower).
-spec append_bin(binary(), binary()) -> binary().
append_bin(<<>>, New) -> New;
append_bin(Acc, New) -> <<Acc/binary, New/binary>>.

%% Re-arm the active-once socket and receive the next message, hibernating
%% first when a handler opted in (`Hibernate`). The hibernate continuation
%% re-enters `recv_loop/1` on the next message; the socket is armed before
%% parking so that message wakes it. Exits cleanly if the socket is dead
%% (a peer-closed socket mid-frame is a normal end-of-session event, not a
%% crash). Mirrors the conn-loop `arm_and_recv` + `recv_more_hib` pattern.
-spec arm_and_recv(#data{}, boolean()) -> no_return().
arm_and_recv(#data{socket = Socket} = Data, Hibernate) ->
    case roadrunner_transport:setopts(Socket, [{active, once}]) of
        ok when Hibernate -> erlang:hibernate(?MODULE, recv_loop, [Data]);
        ok -> recv_loop(Data);
        {error, _} -> exit_clean(Data)
    end.

-spec handle_frame(roadrunner_ws:frame(), #data{}, boolean()) -> no_return().
handle_frame(#{opcode := close, payload := P}, Data, _Hibernate) ->
    %% RFC 6455 §5.5.1: when echoing a close, the typical behavior is
    %% to send back the same status code the peer sent. But the peer
    %% may also send a malformed close (invalid status code, bad
    %% UTF-8 reason, 1-byte payload). Per §7.4.1 the server then
    %% MUST close with 1002 (protocol error) instead of echoing.
    Reply = close_reply(P),
    ok = send_ws_frame(Data, close, Reply),
    exit_clean(Data);
handle_frame(#{opcode := ping, payload := P}, Data, Hibernate) ->
    ok = send_ws_frame(Data, pong, P),
    process_buffer(Data, Hibernate);
handle_frame(#{opcode := pong}, Data, Hibernate) ->
    %% Server is not pinging clients yet — pong from client is dropped.
    process_buffer(Data, Hibernate);
handle_frame(
    #{fin := true, rsv1 := false, opcode := Op, payload := P} = Frame,
    #data{msg_acc = undefined, utf8_pending = Pending, max_message_size = MaxMsg} = Data,
    Hibernate
) when
    (Op =:= text orelse Op =:= binary), byte_size(P) =< MaxMsg
->
    %% Fast path for the dominant case: a complete, unfragmented,
    %% uncompressed data message delivered in one frame, with no message
    %% already in progress. The parsed `Frame` is already byte-identical
    %% to what the reassembly path would synthesize, so dispatch it
    %% directly and skip the fragment machinery (classify, the `[P]`
    %% cons, `finalize_message`, and the synthesized map). Wire-level
    %% UTF-8 ran incrementally; FIN only adds "no trailing incomplete
    %% sequence". Oversized (> `max_message_size`), compressed (RSV1) and
    %% mid-fragmentation frames fall through to the reassembly path below.
    case fragment_validate_fin(Op, false, Pending, P, Data) of
        ok ->
            dispatch_data_frame(Frame, reset_msg(Data), Hibernate);
        invalid_utf8 ->
            close_with(close_invalid_payload(), reset_msg(Data))
    end;
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

-spec accumulate_fragment(roadrunner_ws:frame(), #data{}, boolean()) -> no_return().
accumulate_fragment(
    #{fin := false, payload := P} = _Frame,
    #data{
        msg_acc = Acc,
        msg_opcode = Op,
        msg_compressed = Compressed,
        msg_size = Size,
        max_message_size = MaxMsg
    } = Data,
    Hibernate
) ->
    NewSize = Size + max(byte_size(P), ?WS_FRAGMENT_OVERHEAD),
    case NewSize > MaxMsg of
        true ->
            %% Charged message size exceeds `max_message_size`. Close
            %% with 1009 instead of buffering more — this stops a
            %% continuation flood that never sets fin=1, including one
            %% built from empty/tiny frames (each charged the per-
            %% fragment overhead so the cap bounds real memory).
            close_oversize(max_message_size, NewSize, Data);
        false ->
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
                            msg_size = NewSize,
                            utf8_pending = NewPending,
                            %% Reset wire-level cursor + unmasked-buffer so
                            %% the NEXT frame's bytes are validated and
                            %% accumulated from scratch when they arrive.
                            frame_validated = 0,
                            unmasked_buf = <<>>
                        },
                        Hibernate
                    );
                invalid_utf8 ->
                    %% RFC 6455 §8.1: close 1007 on the first invalid
                    %% UTF-8 byte sequence — don't wait for FIN.
                    close_with(close_invalid_payload(), reset_msg(Data))
            end
    end;
accumulate_fragment(
    #{fin := true, payload := P} = _Frame,
    #data{msg_size = Size, max_message_size = MaxMsg} = Data,
    _Hibernate
) when Size + max(byte_size(P), ?WS_FRAGMENT_OVERHEAD) > MaxMsg ->
    %% The final fragment pushes the charged message size over
    %% `max_message_size` — close with 1009. (For compressed messages
    %% this bounds the wire-level accumulated payload.)
    close_oversize(max_message_size, Size + max(byte_size(P), ?WS_FRAGMENT_OVERHEAD), Data);
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
                {error, {message_too_big, Size}} ->
                    %% Inflated payload would exceed `max_message_size`.
                    close_oversize(max_message_size, Size, Reset);
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
    case unicode:characters_to_binary(append_bin(Pending, Bytes), utf8, utf8) of
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
        msg_size = 0,
        utf8_pending = <<>>,
        frame_validated = 0,
        unmasked_buf = <<>>
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
    %% Empty `Pending` (the common case) hands the validator the payload
    %% binary as-is — the BIF's fast binary path beats a pre-concat copy
    %% and an iodata list alike.
    case unicode:characters_to_binary(append_bin(Pending, Bytes), utf8, utf8) of
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
finalize_message(
    #data{inflate_z = Z, pmd_params = Params, max_message_size = MaxMsg} = Data, Iolist, true
) ->
    Compressed = iolist_to_binary([Iolist, ?PMD_TAIL]),
    try bounded_inflate(Z, Compressed, MaxMsg) of
        {ok, Inflated} ->
            case Params of
                #{client_no_context_takeover := true} -> ok = zlib:inflateReset(Z);
                #{} -> ok
            end,
            {ok, Inflated, Data};
        {error, _} = Err ->
            %% Over the decompressed cap — the connection is about to be
            %% closed (1009), so the inflate stream isn't reset for reuse.
            Err
    catch
        _:Reason -> {error, Reason}
    end.

%% Inflate `Compressed` in bounded chunks, enforcing `Max` on the
%% running decompressed total. permessage-deflate (RFC 7692) lets a
%% small high-ratio frame expand to GiB; `zlib:inflate/2` materializes
%% all of it at once. `zlib:safeInflate/2` yields one bounded chunk per
%% call, so we stop and reject the moment the output would cross the cap
%% rather than allocating the whole bomb.
-spec bounded_inflate(zlib:zstream(), binary(), non_neg_integer()) ->
    {ok, binary()} | {error, {message_too_big, non_neg_integer()}}.
bounded_inflate(Z, Compressed, Max) ->
    bounded_inflate(zlib:safeInflate(Z, Compressed), Z, Max, 0, []).

-spec bounded_inflate(
    {continue | finished, iolist()}, zlib:zstream(), non_neg_integer(), non_neg_integer(), iolist()
) -> {ok, binary()} | {error, {message_too_big, non_neg_integer()}}.
bounded_inflate({continue, Output}, Z, Max, Total, Acc) ->
    NewTotal = Total + iolist_size(Output),
    case NewTotal > Max of
        true -> {error, {message_too_big, NewTotal}};
        false -> bounded_inflate(zlib:safeInflate(Z, []), Z, Max, NewTotal, [Acc, Output])
    end;
bounded_inflate({finished, Output}, _Z, Max, Total, Acc) ->
    Final = Total + iolist_size(Output),
    case Final > Max of
        true -> {error, {message_too_big, Final}};
        false -> {ok, iolist_to_binary([Acc, Output])}
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

%% RFC 6455 §7.4: 1009 = message too big — a single frame's declared
%% payload, a reassembled message, or an inflated payload exceeded the
%% configured cap.
-spec close_message_too_big() -> binary().
close_message_too_big() ->
    <<1009:16>>.

-spec close_with(binary(), #data{}) -> no_return().
close_with(StatusBin, Data) ->
    ok = send_ws_frame(Data, close, StatusBin),
    exit_clean(Data).

%% Close with 1009 because an inbound size cap was exceeded, emitting
%% `[roadrunner, ws, frame_rejected]` first so operators can see the
%% rejection (and its reason + offending size) — a plain close frame
%% doesn't distinguish a cap rejection from a normal close.
-spec close_oversize(max_frame_size | max_message_size, non_neg_integer(), #data{}) ->
    no_return().
close_oversize(Reason, Size, #data{ctx = Ctx} = Data) ->
    ok = roadrunner_telemetry:ws_frame_rejected(Ctx#{reason => Reason}, Size),
    close_with(close_message_too_big(), reset_msg(Data)).

%% Build the payload for the close-handshake reply. RFC 6455 §5.5.1
%% says servers typically echo the received status code back, BUT
%% only if the peer's close was well-formed. §7.4.1 + §5.5.1
%% reject malformed closes with 1002 (protocol error). Cases:
%%
%% - Empty payload                       → echo empty.
%% - Two-byte status code that's valid   → echo just the code
%%                                          (drop the peer's reason).
%% - Two-byte valid code + invalid UTF-8 → reply 1002.
%% - Invalid status code (reserved, etc.) → reply 1002.
%% - One-byte (malformed)                → reply 1002.
-spec close_reply(binary()) -> binary().
close_reply(<<>>) ->
    <<>>;
close_reply(<<Code:16, Reason/binary>>) ->
    case is_valid_close_code(Code) andalso is_valid_utf8(Reason) of
        true -> <<Code:16>>;
        false -> close_protocol_error()
    end;
close_reply(_) ->
    close_protocol_error().

%% Per RFC 6455 §7.4.1 / §7.4.2:
%%   - 1000-1011 + 1014: assigned, may appear on the wire (1004/1005/1006
%%     are reserved, MUST NOT appear).
%%   - 3000-4999: registered (3xxx) or application-private (4xxx) ranges.
%% Anything else is invalid.
-spec is_valid_close_code(non_neg_integer()) -> boolean().
is_valid_close_code(Code) when Code >= 3000, Code =< 4999 -> true;
is_valid_close_code(1000) -> true;
is_valid_close_code(1001) -> true;
is_valid_close_code(1002) -> true;
is_valid_close_code(1003) -> true;
is_valid_close_code(1007) -> true;
is_valid_close_code(1008) -> true;
is_valid_close_code(1009) -> true;
is_valid_close_code(1010) -> true;
is_valid_close_code(1011) -> true;
is_valid_close_code(1014) -> true;
is_valid_close_code(_) -> false.

-spec is_valid_utf8(binary()) -> boolean().
is_valid_utf8(<<>>) ->
    true;
is_valid_utf8(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Out when is_binary(Out) -> true;
        _ -> false
    end.

-spec dispatch_data_frame(roadrunner_ws:frame(), #data{}, boolean()) -> no_return().
dispatch_data_frame(Frame, #data{mod = Mod, mod_state = State} = Data, Hibernate) ->
    apply_handler_result(Mod:handle_frame(Frame, State), Data, Hibernate, fun process_buffer/2).

-spec handle_info_msg(term(), #data{}, boolean()) -> no_return().
handle_info_msg(Msg, #data{has_handle_info = true, mod = Mod, mod_state = State} = Data, Hibernate) ->
    apply_handler_result(Mod:handle_info(Msg, State), Data, Hibernate, fun arm_and_recv/2);
handle_info_msg(_Msg, #data{has_handle_info = false} = Data, _Hibernate) ->
    arm_and_recv(Data, false).

-spec handle_drain_msg(integer(), #data{}, boolean()) -> no_return().
handle_drain_msg(
    Deadline,
    #data{has_handle_drain = true, mod = Mod, mod_state = State} = Data,
    Hibernate
) ->
    apply_handler_result(Mod:handle_drain(Deadline, State), Data, Hibernate, fun arm_and_recv/2);
handle_drain_msg(_Deadline, #data{has_handle_drain = false} = Data, _Hibernate) ->
    arm_and_recv(Data, false).

%% Apply a handler callback's return. `Continue` is the next step on a
%% non-close return: `fun process_buffer/2` after handle_frame (drain any
%% more buffered frames), `fun arm_and_recv/2` after handle_info/drain
%% (re-arm and wait), `fun enter_frame_loop/2` after the optional init/1.
-spec apply_handler_result(
    roadrunner_ws_handler:result(),
    #data{},
    boolean(),
    fun((#data{}, boolean()) -> no_return())
) -> no_return().
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
            exit_clean(Data);
        {close, Code, Reason, _NewState} ->
            ok = send_ws_frame(Data, close, close_payload(Code, Reason)),
            exit_clean(Data)
    end.

%% Build the wire payload for a handler-driven close. RFC 6455 §5.5.1
%% lays out the format: 2-byte big-endian status code followed by the
%% UTF-8 reason. Validate both — emitting a malformed close would
%% violate §7.4 / §8.1 and the peer would (correctly) close us with
%% 1002. A handler that supplies bad inputs has a bug; let it crash
%% with a tagged error rather than silently send garbage.
-spec close_payload(roadrunner_ws:close_code(), iodata()) -> binary().
close_payload(Code, Reason) ->
    ReasonBin = iolist_to_binary(Reason),
    case is_valid_close_code(Code) andalso is_valid_utf8(ReasonBin) of
        true -> <<Code:16, ReasonBin/binary>>;
        false -> error({invalid_close_payload, Code, ReasonBin})
    end.

%% --- helpers ---

-spec ws_context(roadrunner_req:request(), module()) -> map().
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
%% emit telemetry per frame (so subscribers can count by opcode) and
%% encode them in one walk, then write the whole batch in a single
%% TCP send to avoid partial-write fragmentation.
-spec send_ws_frames(#data{}, [{roadrunner_ws:opcode(), iodata()}]) ->
    ok | {error, term()}.
send_ws_frames(#data{socket = Socket, ctx = Ctx} = Data, OutFrames) ->
    Iodata = encode_frames(Data, Ctx, OutFrames),
    roadrunner_transport:send(Socket, Iodata).

-spec encode_frames(#data{}, map(), [{roadrunner_ws:opcode(), iodata()}]) -> iodata().
encode_frames(_Data, _Ctx, []) ->
    [];
encode_frames(Data, Ctx, [{Op, Payload} | Rest]) ->
    ok = roadrunner_telemetry:ws_frame_out(Ctx#{opcode => Op}, iolist_size(Payload)),
    [encode_outbound(Data, Op, Payload) | encode_frames(Data, Ctx, Rest)].

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
    case Params of
        #{server_no_context_takeover := true} -> ok = zlib:deflateReset(Z);
        #{} -> ok
    end,
    Bin = iolist_to_binary(Iolist),
    %% Strip the per-message tail (last 4 bytes of `0x00 0x00 0xff 0xff`).
    %% `sync` flush always emits these, so it's safe to chop.
    Size = byte_size(Bin),
    binary:part(Bin, 0, Size - 4).
