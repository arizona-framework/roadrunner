-module(roadrunner_http2_frame).
-moduledoc """
HTTP/2 (RFC 9113 §4 + §6) frame codec — pure binary parsers and
encoders for all 10 frame types.

This module is purely about wire-format syntax: it parses bytes into
typed terms and encodes typed terms back to bytes. It does **not**
enforce stream-state validity (RFC 9113 §5.1), connection-level
validity (e.g. SETTINGS arriving before the preface), or flow-control
arithmetic (§5.2). Those constraints are enforced by callers in
later phases.

## Frame types

| Type | Hex | Module spec |
|------|-----|-------------|
| DATA          | 0x0 | RFC 9113 §6.1 |
| HEADERS       | 0x1 | RFC 9113 §6.2 |
| PRIORITY      | 0x2 | RFC 9113 §6.3 (deprecated, MUST accept) |
| RST_STREAM    | 0x3 | RFC 9113 §6.4 |
| SETTINGS      | 0x4 | RFC 9113 §6.5 |
| PUSH_PROMISE  | 0x5 | RFC 9113 §6.6 |
| PING          | 0x6 | RFC 9113 §6.7 |
| GOAWAY        | 0x7 | RFC 9113 §6.8 |
| WINDOW_UPDATE | 0x8 | RFC 9113 §6.9 |
| CONTINUATION  | 0x9 | RFC 9113 §6.10 |

## API

`parse(Bin, MaxFrameSize)` is incremental: it returns
`{ok, frame(), Rest}` when a complete frame has been decoded,
`{more, Need}` when more bytes are required, or `{error, Reason}`
on syntactic failure. `encode(frame())` returns iodata.

Frame flags are kept as the raw 8-bit byte in the parsed shape —
higher layers interpret them per-type. Reserved bits in flag bytes
MUST be ignored on receive (§4.1) and MUST be sent as 0; the
encoder zeros any unknown bits.

## Padding

DATA, HEADERS, and PUSH_PROMISE frames support optional padding
(PADDED flag, 0x8 — RFC 9113 §6.1 / §6.2 / §6.6). When present the
first byte of the payload is the pad length, followed by the
fragment, followed by `pad-length` bytes of padding. Pad length
larger than the available frame payload is `PROTOCOL_ERROR`.

## Stream id 0 / non-zero rules

Per RFC 9113 §6, certain frame types MUST be on stream 0
(SETTINGS, PING, GOAWAY) and others MUST be on a non-zero stream
(DATA, HEADERS, PRIORITY, RST_STREAM, PUSH_PROMISE,
WINDOW_UPDATE-on-stream, CONTINUATION). The parser enforces this
at parse time with a `stream_id_violation` error so callers don't
have to re-validate.

## MAX_FRAME_SIZE

Per RFC 9113 §6.5.2 SETTINGS_MAX_FRAME_SIZE governs the largest
frame payload the receiver will accept. The codec takes the limit
as an explicit argument so it can grow as the client advertises a
higher value. Frames whose `length` exceeds the limit fail with
`frame_size_error`.
""".

-export([parse/2, encode/1]).

-export_type([
    frame/0,
    frame_type/0,
    error_code/0,
    parse_result/0,
    parse_error/0,
    priority/0,
    settings_param/0
]).

%% RFC 9113 §7 error codes — used by RST_STREAM and GOAWAY payloads.
%% Listed by name; the encoded form is `code(Atom)`.
-type error_code() ::
    no_error
    | protocol_error
    | internal_error
    | flow_control_error
    | settings_timeout
    | stream_closed
    | frame_size_error
    | refused_stream
    | cancel
    | compression_error
    | connect_error
    | enhance_your_calm
    | inadequate_security
    | http_1_1_required
    | non_neg_integer().

-type frame_type() ::
    data
    | headers
    | priority
    | rst_stream
    | settings
    | push_promise
    | ping
    | goaway
    | window_update
    | continuation.

-type stream_id() :: non_neg_integer().
-type flags() :: 0..255.

-type priority() :: #{
    exclusive := boolean(),
    stream_dependency := stream_id(),
    weight := 0..255
}.

-type settings_param() :: {ParamId :: non_neg_integer(), Value :: non_neg_integer()}.

-type frame() ::
    {data, stream_id(), flags(), Payload :: binary()}
    | {headers, stream_id(), flags(), Priority :: priority() | undefined, HeaderBlock :: binary()}
    | {priority, stream_id(), priority()}
    | {rst_stream, stream_id(), error_code()}
    | {settings, flags(), [settings_param()]}
    | {push_promise, stream_id(), flags(), PromisedStreamId :: stream_id(), HeaderBlock :: binary()}
    | {ping, flags(), OpaqueData :: <<_:64>>}
    | {goaway, LastStreamId :: stream_id(), error_code(), DebugData :: binary()}
    | {window_update, stream_id(), Increment :: 1..16#7FFFFFFF}
    | {continuation, stream_id(), flags(), HeaderBlock :: binary()}
    %% Unknown frame types — RFC 9113 §4.1: receivers MUST ignore.
    %% Surfaced (rather than dropped at parse time) so the conn can
    %% enforce the §6.10 "no non-CONTINUATION between HEADERS and
    %% CONTINUATION" rule even for unknown frame types.
    | {unknown, Type :: non_neg_integer(), stream_id()}.

-type parse_error() ::
    frame_size_error
    | protocol_error
    | stream_id_violation
    | bad_padding
    | bad_priority_payload
    | bad_rst_stream_payload
    | bad_settings_payload
    | bad_push_promise_payload
    | bad_ping_payload
    | bad_goaway_payload
    | bad_window_update_payload
    | window_update_zero_increment.

-type parse_result() ::
    {ok, frame(), Rest :: binary()}
    | {more, Need :: pos_integer()}
    | {error, parse_error()}.

%% RFC 9113 §11.2 IANA-registered frame types.
-define(TYPE_DATA, 0).
-define(TYPE_HEADERS, 1).
-define(TYPE_PRIORITY, 2).
-define(TYPE_RST_STREAM, 3).
-define(TYPE_SETTINGS, 4).
-define(TYPE_PUSH_PROMISE, 5).
-define(TYPE_PING, 6).
-define(TYPE_GOAWAY, 7).
-define(TYPE_WINDOW_UPDATE, 8).
-define(TYPE_CONTINUATION, 9).

%% Common flag bits used across multiple frame types.
-define(FLAG_END_STREAM, 16#01).
-define(FLAG_ACK, 16#01).
-define(FLAG_END_HEADERS, 16#04).
-define(FLAG_PADDED, 16#08).
-define(FLAG_PRIORITY, 16#20).

%% =============================================================================
%% parse/2
%% =============================================================================

-doc """
Decode the next frame from `Bin`, rejecting any frame whose payload
length exceeds `MaxFrameSize`.

Returns:
- `{ok, Frame, Rest}` — `Frame` is fully decoded, `Rest` is the
  remaining buffer that follows it.
- `{more, NumBytes}` — at least `NumBytes` more bytes are needed
  before a frame can be decoded. Caller should `recv` more.
- `{error, Reason}` — frame is malformed in a way that maps to an
  RFC 9113 connection or stream error code. Caller decides whether
  to RST_STREAM or GOAWAY.
""".
-spec parse(binary(), pos_integer()) -> parse_result().
parse(<<Length:24, _/binary>>, MaxFrameSize) when Length > MaxFrameSize ->
    {error, frame_size_error};
parse(<<Length:24, _Type:8, _Flags:8, _R:1, _StreamId:31, Rest/binary>>, _MaxFrameSize) when
    byte_size(Rest) < Length
->
    {more, Length - byte_size(Rest)};
parse(<<Length:24, Type:8, Flags:8, _R:1, StreamId:31, Body/binary>>, _MaxFrameSize) ->
    <<Payload:Length/binary, Rest/binary>> = Body,
    case decode(Type, Flags, StreamId, Payload) of
        {ok, Frame} -> {ok, Frame, Rest};
        ignore -> {ok, {unknown, Type, StreamId}, Rest};
        {error, _} = E -> E
    end;
parse(Bin, _MaxFrameSize) when byte_size(Bin) < 9 ->
    {more, 9 - byte_size(Bin)}.

%% =============================================================================
%% Per-type decode
%% =============================================================================

-spec decode(non_neg_integer(), flags(), stream_id(), binary()) ->
    {ok, frame()} | ignore | {error, parse_error()}.
decode(?TYPE_DATA, _Flags, 0, _Payload) ->
    %% RFC 9113 §6.1: DATA on stream 0 is a connection error.
    {error, stream_id_violation};
decode(?TYPE_DATA, Flags, StreamId, Payload) ->
    case strip_padding(Flags, Payload) of
        {ok, Body} -> {ok, {data, StreamId, Flags, Body}};
        {error, _} = E -> E
    end;
decode(?TYPE_HEADERS, _Flags, 0, _Payload) ->
    %% RFC 9113 §6.2: HEADERS on stream 0 is a connection error.
    {error, stream_id_violation};
decode(?TYPE_HEADERS, Flags, StreamId, Payload) ->
    case strip_padding(Flags, Payload) of
        {ok, Unpadded} ->
            case has_flag(Flags, ?FLAG_PRIORITY) of
                false ->
                    {ok, {headers, StreamId, Flags, undefined, Unpadded}};
                true ->
                    decode_headers_with_priority(StreamId, Flags, Unpadded)
            end;
        {error, _} = E ->
            E
    end;
decode(?TYPE_PRIORITY, _Flags, 0, _Payload) ->
    %% §6.3: PRIORITY on stream 0 is a connection error.
    {error, stream_id_violation};
decode(?TYPE_PRIORITY, _Flags, StreamId, <<E:1, Dep:31, Weight:8>>) ->
    {ok,
        {priority, StreamId, #{
            exclusive => E =:= 1,
            stream_dependency => Dep,
            weight => Weight
        }}};
decode(?TYPE_PRIORITY, _Flags, _StreamId, _Payload) ->
    {error, bad_priority_payload};
decode(?TYPE_RST_STREAM, _Flags, 0, _Payload) ->
    %% §6.4: RST_STREAM on stream 0 is a connection error.
    {error, stream_id_violation};
decode(?TYPE_RST_STREAM, _Flags, StreamId, <<Code:32>>) ->
    {ok, {rst_stream, StreamId, code_atom(Code)}};
decode(?TYPE_RST_STREAM, _Flags, _StreamId, _Payload) ->
    {error, bad_rst_stream_payload};
decode(?TYPE_SETTINGS, _Flags, NonZero, _Payload) when NonZero =/= 0 ->
    %% §6.5: SETTINGS MUST be on stream 0.
    {error, stream_id_violation};
decode(?TYPE_SETTINGS, Flags, 0, Payload) ->
    %% §4.1: undefined flags MUST be ignored — mask Flags down to
    %% the only defined SETTINGS flag (ACK) so handle_frame/2's
    %% literal `0` / `1` patterns match cleanly even when the peer
    %% sets stray bits.
    case has_flag(Flags, ?FLAG_ACK) of
        true when byte_size(Payload) =/= 0 ->
            %% ACK SETTINGS MUST be empty (§6.5).
            {error, bad_settings_payload};
        true ->
            {ok, {settings, ?FLAG_ACK, []}};
        false ->
            case decode_settings_params(Payload) of
                {ok, Params} -> {ok, {settings, 0, Params}};
                {error, _} = E -> E
            end
    end;
decode(?TYPE_PUSH_PROMISE, _Flags, 0, _Payload) ->
    %% §6.6: PUSH_PROMISE MUST be on a non-zero stream.
    {error, stream_id_violation};
decode(?TYPE_PUSH_PROMISE, Flags, StreamId, Payload) ->
    case strip_padding(Flags, Payload) of
        {ok, <<_R:1, PromisedId:31, HeaderBlock/binary>>} ->
            {ok, {push_promise, StreamId, Flags, PromisedId, HeaderBlock}};
        {ok, _} ->
            {error, bad_push_promise_payload};
        {error, _} = E ->
            E
    end;
decode(?TYPE_PING, _Flags, NonZero, _Payload) when NonZero =/= 0 ->
    %% §6.7: PING MUST be on stream 0.
    {error, stream_id_violation};
decode(?TYPE_PING, Flags, 0, <<OpaqueData:8/binary>>) ->
    %% Mask Flags to the only defined PING flag (ACK) so undefined
    %% bits don't bypass `handle_frame/2`'s literal `0` / `1`
    %% patterns (RFC 9113 §4.1).
    {ok, {ping, Flags band ?FLAG_ACK, OpaqueData}};
decode(?TYPE_PING, _Flags, 0, _Payload) ->
    {error, bad_ping_payload};
decode(?TYPE_GOAWAY, _Flags, NonZero, _Payload) when NonZero =/= 0 ->
    %% §6.8: GOAWAY MUST be on stream 0.
    {error, stream_id_violation};
decode(?TYPE_GOAWAY, _Flags, 0, <<_R:1, LastStreamId:31, ErrorCode:32, Debug/binary>>) ->
    {ok, {goaway, LastStreamId, code_atom(ErrorCode), Debug}};
decode(?TYPE_GOAWAY, _Flags, 0, _Payload) ->
    {error, bad_goaway_payload};
decode(?TYPE_WINDOW_UPDATE, _Flags, _StreamId, <<_R:1, 0:31>>) ->
    %% §6.9.1: a flow-control window increment of 0 is a
    %% PROTOCOL_ERROR; the value of `_StreamId` decides whether the
    %% caller treats it as a stream or connection error.
    {error, window_update_zero_increment};
decode(?TYPE_WINDOW_UPDATE, _Flags, StreamId, <<_R:1, Increment:31>>) ->
    {ok, {window_update, StreamId, Increment}};
decode(?TYPE_WINDOW_UPDATE, _Flags, _StreamId, _Payload) ->
    {error, bad_window_update_payload};
decode(?TYPE_CONTINUATION, _Flags, 0, _Payload) ->
    %% §6.10: CONTINUATION MUST be on a non-zero stream.
    {error, stream_id_violation};
decode(?TYPE_CONTINUATION, Flags, StreamId, Payload) ->
    {ok, {continuation, StreamId, Flags, Payload}};
decode(_UnknownType, _Flags, _StreamId, _Payload) ->
    %% RFC 9113 §4.1 last paragraph + §5.5: unknown frame types
    %% MUST be ignored. `parse/2` recurses on `ignore` to advance
    %% past the silently-discarded frame.
    ignore.

%% Strip the optional pad-length byte + trailing pad bytes per
%% §6.1 / §6.2 / §6.6. When PADDED is not set, the payload is
%% returned unchanged.
-spec strip_padding(flags(), binary()) -> {ok, binary()} | {error, bad_padding}.
strip_padding(Flags, Payload) ->
    case has_flag(Flags, ?FLAG_PADDED) of
        false ->
            {ok, Payload};
        true ->
            case Payload of
                <<PadLen:8, Rest/binary>> when PadLen =< byte_size(Rest) ->
                    Take = byte_size(Rest) - PadLen,
                    <<Inner:Take/binary, _Pad:PadLen/binary>> = Rest,
                    {ok, Inner};
                _ ->
                    {error, bad_padding}
            end
    end.

%% HEADERS with the PRIORITY flag prepends a 5-byte priority block
%% (RFC 9113 §6.2).
-spec decode_headers_with_priority(stream_id(), flags(), binary()) ->
    {ok, frame()} | {error, parse_error()}.
decode_headers_with_priority(
    StreamId, Flags, <<E:1, Dep:31, Weight:8, HeaderBlock/binary>>
) ->
    Priority = #{
        exclusive => E =:= 1,
        stream_dependency => Dep,
        weight => Weight
    },
    {ok, {headers, StreamId, Flags, Priority, HeaderBlock}};
decode_headers_with_priority(_StreamId, _Flags, _Payload) ->
    {error, protocol_error}.

%% Walk a SETTINGS payload (sequence of 6-byte parameter records).
%% RFC 9113 §6.5: payload length MUST be a multiple of 6; the
%% caller already ensured Length matched the framed body.
%% Body recursion — cons each parameter onto the result on the way
%% back out so we never call `lists:reverse/1`.
-spec decode_settings_params(binary()) ->
    {ok, [settings_param()]} | {error, bad_settings_payload}.
decode_settings_params(<<>>) ->
    {ok, []};
decode_settings_params(<<Id:16, Value:32, Rest/binary>>) ->
    case decode_settings_params(Rest) of
        {ok, Tail} -> {ok, [{Id, Value} | Tail]};
        {error, _} = E -> E
    end;
decode_settings_params(_Bin) ->
    {error, bad_settings_payload}.

-spec has_flag(flags(), flags()) -> boolean().
has_flag(Flags, Mask) ->
    (Flags band Mask) =/= 0.

%% =============================================================================
%% encode/1
%% =============================================================================

-doc """
Encode a `frame()` term back to its 9-byte header + payload wire form.
Returns `iodata()` so callers can chain through `gen_tcp:send/2`
without an intermediate flatten.
""".
-spec encode(frame()) -> iodata().
encode({data, StreamId, Flags, Payload}) ->
    %% Padding is opt-in on encode: callers can include it themselves
    %% by passing the pad-length-prefixed body and the PADDED flag.
    %% This module does not auto-pad.
    frame_io(?TYPE_DATA, Flags, StreamId, Payload);
encode({headers, StreamId, Flags, undefined, HeaderBlock}) ->
    frame_io(?TYPE_HEADERS, Flags band (bnot ?FLAG_PRIORITY), StreamId, HeaderBlock);
encode({headers, StreamId, Flags, #{} = Priority, HeaderBlock}) ->
    Block = [encode_priority(Priority), HeaderBlock],
    frame_io(?TYPE_HEADERS, Flags bor ?FLAG_PRIORITY, StreamId, Block);
encode({priority, StreamId, #{} = Priority}) ->
    frame_io(?TYPE_PRIORITY, 0, StreamId, encode_priority(Priority));
encode({rst_stream, StreamId, ErrorCode}) ->
    frame_io(?TYPE_RST_STREAM, 0, StreamId, <<(code_int(ErrorCode)):32>>);
encode({settings, Flags, Params}) ->
    Body = [<<Id:16, Value:32>> || {Id, Value} <- Params],
    frame_io(?TYPE_SETTINGS, Flags, 0, Body);
encode({push_promise, StreamId, Flags, PromisedId, HeaderBlock}) ->
    Body = [<<0:1, PromisedId:31>>, HeaderBlock],
    frame_io(?TYPE_PUSH_PROMISE, Flags, StreamId, Body);
encode({ping, Flags, <<OpaqueData:8/binary>>}) ->
    frame_io(?TYPE_PING, Flags, 0, OpaqueData);
encode({goaway, LastStreamId, ErrorCode, DebugData}) ->
    Body = [<<0:1, LastStreamId:31, (code_int(ErrorCode)):32>>, DebugData],
    frame_io(?TYPE_GOAWAY, 0, 0, Body);
encode({window_update, StreamId, Increment}) ->
    frame_io(?TYPE_WINDOW_UPDATE, 0, StreamId, <<0:1, Increment:31>>);
encode({continuation, StreamId, Flags, HeaderBlock}) ->
    frame_io(?TYPE_CONTINUATION, Flags, StreamId, HeaderBlock).

-spec encode_priority(priority()) -> binary().
encode_priority(#{exclusive := Excl, stream_dependency := Dep, weight := Weight}) ->
    E =
        case Excl of
            true -> 1;
            false -> 0
        end,
    <<E:1, Dep:31, Weight:8>>.

%% Build the 9-byte header + payload as iodata. `Body` is iodata so
%% callers can chain pre-built fragments without copying.
-spec frame_io(non_neg_integer(), flags(), stream_id(), iodata()) -> iodata().
frame_io(Type, Flags, StreamId, Body) ->
    Length = iolist_size(Body),
    [<<Length:24, Type, Flags, 0:1, StreamId:31>>, Body].

%% =============================================================================
%% Error code mapping (RFC 9113 §7)
%% =============================================================================

-spec code_atom(non_neg_integer()) -> error_code().
code_atom(16#0) -> no_error;
code_atom(16#1) -> protocol_error;
code_atom(16#2) -> internal_error;
code_atom(16#3) -> flow_control_error;
code_atom(16#4) -> settings_timeout;
code_atom(16#5) -> stream_closed;
code_atom(16#6) -> frame_size_error;
code_atom(16#7) -> refused_stream;
code_atom(16#8) -> cancel;
code_atom(16#9) -> compression_error;
code_atom(16#A) -> connect_error;
code_atom(16#B) -> enhance_your_calm;
code_atom(16#C) -> inadequate_security;
code_atom(16#D) -> http_1_1_required;
code_atom(N) -> N.

-spec code_int(error_code()) -> non_neg_integer().
code_int(no_error) -> 16#0;
code_int(protocol_error) -> 16#1;
code_int(internal_error) -> 16#2;
code_int(flow_control_error) -> 16#3;
code_int(settings_timeout) -> 16#4;
code_int(stream_closed) -> 16#5;
code_int(frame_size_error) -> 16#6;
code_int(refused_stream) -> 16#7;
code_int(cancel) -> 16#8;
code_int(compression_error) -> 16#9;
code_int(connect_error) -> 16#A;
code_int(enhance_your_calm) -> 16#B;
code_int(inadequate_security) -> 16#C;
code_int(http_1_1_required) -> 16#D;
code_int(N) when is_integer(N) -> N.
