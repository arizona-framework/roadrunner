-module(roadrunner_quic_h3_frame).
-moduledoc false.

%% HTTP/3 frame codec (RFC 9114 §7). Frame type and length are QUIC
%% varints (`roadrunner_quic_varint`); the payload follows.
%%
%% Pure wire syntax only: this module parses bytes into typed frame
%% terms and encodes typed terms back to bytes. It does NOT enforce the
%% frame-sequence rules (SETTINGS first, DATA-after-HEADERS, control vs
%% request streams) — `roadrunner_conn_loop_http3` owns those.
%%
%% The result shapes match what that loop already consumes so the codec
%% can be swapped in with no caller change: `decode/1` yields
%% `{ok, frame(), Rest} | {more, Need} | {error, Reason}`, where a
%% `{settings, map()}` frame carries a map, an unknown/grease type is
%% surfaced as `{unknown, Type, Payload}` (RFC 9114 §9), and the two
%% load-bearing error reasons are `{frame_error, settings, _}` (mapped
%% to H3_SETTINGS_ERROR upstream) and `{h2_reserved_frame, Type}` (the
%% HTTP/2-only types reserved by RFC 9114 §7.2.8).
%%
%% Encoders return `iodata()` so a large DATA/HEADERS payload is framed
%% by prepending a header, never copied.

-export([
    encode_data/1,
    encode_headers/1,
    encode_settings/1,
    encode_goaway/1,
    encode_stream_type/1,
    decode/1,
    decode_stream_type/1
]).

-export_type([frame/0]).

%% RFC 9114 §7.2 frame types.
-define(FRAME_DATA, 16#00).
-define(FRAME_HEADERS, 16#01).
-define(FRAME_CANCEL_PUSH, 16#03).
-define(FRAME_SETTINGS, 16#04).
-define(FRAME_PUSH_PROMISE, 16#05).
-define(FRAME_GOAWAY, 16#07).
-define(FRAME_MAX_PUSH_ID, 16#0D).

%% RFC 9114 §6.2 unidirectional stream types.
-define(STREAM_CONTROL, 16#00).
-define(STREAM_PUSH, 16#01).
-define(STREAM_QPACK_ENCODER, 16#02).
-define(STREAM_QPACK_DECODER, 16#03).

%% RFC 9114 §7.2.4.1 settings identifiers we map to atoms; any other id
%% (extension / grease) is surfaced under its integer key.
-define(SETTINGS_QPACK_MAX_TABLE_CAPACITY, 16#01).
-define(SETTINGS_MAX_FIELD_SECTION_SIZE, 16#06).
-define(SETTINGS_QPACK_BLOCKED_STREAMS, 16#07).
-define(SETTINGS_ENABLE_CONNECT_PROTOCOL, 16#08).

%% RFC 9114 §7.1: bound a frame payload before allocating, so a peer
%% cannot force unbounded buffering with a pathological Length varint.
-define(MAX_FRAME_SIZE, 16#100000).

-type frame() ::
    {data, binary()}
    | {headers, binary()}
    | {cancel_push, non_neg_integer()}
    | {settings, map()}
    | {push_promise, non_neg_integer(), binary()}
    | {goaway, non_neg_integer()}
    | {max_push_id, non_neg_integer()}
    | {unknown, non_neg_integer(), binary()}.

-type stream_type() ::
    control | qpack_encoder | qpack_decoder | push | {unknown, non_neg_integer()}.

-type decode_result() ::
    {ok, frame(), Rest :: binary()}
    | {more, Need :: pos_integer()}
    | {error, term()}.

%% =============================================================================
%% Frame encoding
%% =============================================================================

-doc "Encode a DATA frame (RFC 9114 §7.2.1) as an iolist.".
-spec encode_data(iodata()) -> iolist().
encode_data(Payload) ->
    frame_io(?FRAME_DATA, Payload).

-doc "Encode a HEADERS frame (RFC 9114 §7.2.2) wrapping a QPACK field section.".
-spec encode_headers(iodata()) -> iolist().
encode_headers(HeaderBlock) ->
    frame_io(?FRAME_HEADERS, HeaderBlock).

-doc """
Encode a SETTINGS frame (RFC 9114 §7.2.4) from a settings map. Every
entry in the map is emitted as an id+value varint pair, in
`maps:to_list/1` order.
""".
-spec encode_settings(map()) -> iolist().
encode_settings(Settings) ->
    frame_io(?FRAME_SETTINGS, encode_settings_pairs(maps:to_list(Settings))).

-doc "Encode a GOAWAY frame (RFC 9114 §7.2.6) naming the last stream id.".
-spec encode_goaway(non_neg_integer()) -> iolist().
encode_goaway(StreamId) ->
    frame_io(?FRAME_GOAWAY, roadrunner_quic_varint:encode(StreamId)).

-doc "Encode the leading stream-type varint for a server unidirectional stream.".
-spec encode_stream_type(control | qpack_encoder | qpack_decoder | push | non_neg_integer()) ->
    binary().
encode_stream_type(control) -> roadrunner_quic_varint:encode(?STREAM_CONTROL);
encode_stream_type(qpack_encoder) -> roadrunner_quic_varint:encode(?STREAM_QPACK_ENCODER);
encode_stream_type(qpack_decoder) -> roadrunner_quic_varint:encode(?STREAM_QPACK_DECODER);
encode_stream_type(push) -> roadrunner_quic_varint:encode(?STREAM_PUSH);
encode_stream_type(Type) when is_integer(Type) -> roadrunner_quic_varint:encode(Type).

%% A frame is its type varint, its length varint, then the payload. Kept
%% as an iolist so the (possibly large) payload is never recopied.
-spec frame_io(non_neg_integer(), iodata()) -> iolist().
frame_io(Type, Payload) ->
    [
        roadrunner_quic_varint:encode(Type),
        roadrunner_quic_varint:encode(iolist_size(Payload)),
        Payload
    ].

%% Encode each {id, value} setting as a varint pair, building the payload
%% by consing on the way out (no reverse, no quadratic binary append).
-spec encode_settings_pairs([{atom() | non_neg_integer(), non_neg_integer()}]) -> iolist().
encode_settings_pairs([]) ->
    [];
encode_settings_pairs([{Key, Value} | Rest]) ->
    [
        roadrunner_quic_varint:encode(setting_to_id(Key)),
        roadrunner_quic_varint:encode(Value)
        | encode_settings_pairs(Rest)
    ].

%% =============================================================================
%% Frame decoding
%% =============================================================================

-doc """
Decode the leading HTTP/3 frame from `Bin`.

- `{ok, Frame, Rest}` — a complete frame; `Rest` is the buffer after it.
- `{more, Need}` — the type/length varints or the payload are not all
  buffered yet; at least `Need` more bytes are required.
- `{error, Reason}` — an oversized frame, a malformed payload, or an
  HTTP/2-reserved frame type (RFC 9114 §7.1 / §7.2.8). `Reason` is a
  term the caller maps to an HTTP/3 connection error code.
""".
-spec decode(binary()) -> decode_result().
decode(Bin) ->
    %% A failed `?=` (an incomplete type/length varint) returns its own
    %% `{more, Need}` straight out of the block, so no `else` is needed.
    maybe
        {ok, Type, AfterType} ?= roadrunner_quic_varint:decode(Bin),
        {ok, Length, AfterLength} ?= roadrunner_quic_varint:decode(AfterType),
        decode_with_payload(Type, Length, AfterLength)
    end.

-spec decode_with_payload(non_neg_integer(), non_neg_integer(), binary()) -> decode_result().
decode_with_payload(_Type, Length, _Bin) when Length > ?MAX_FRAME_SIZE ->
    %% RFC 9114 §7.1: reject before allocating the payload buffer.
    {error, {frame_error, oversized, Length}};
decode_with_payload(Type, Length, Bin) when byte_size(Bin) >= Length ->
    <<Payload:Length/binary, Rest/binary>> = Bin,
    case decode_frame_payload(Type, Payload) of
        {error, _} = Error -> Error;
        Frame -> {ok, Frame, Rest}
    end;
decode_with_payload(_Type, Length, Bin) ->
    {more, Length - byte_size(Bin)}.

-spec decode_frame_payload(non_neg_integer(), binary()) -> frame() | {error, term()}.
decode_frame_payload(?FRAME_DATA, Payload) ->
    {data, Payload};
decode_frame_payload(?FRAME_HEADERS, Payload) ->
    {headers, Payload};
decode_frame_payload(?FRAME_SETTINGS, Payload) ->
    case decode_settings_pairs(Payload, #{}) of
        {ok, Settings} -> {settings, Settings};
        {error, Reason} -> {error, {frame_error, settings, Reason}}
    end;
decode_frame_payload(?FRAME_GOAWAY, Payload) ->
    decode_single_id(goaway, Payload, fun(Id) -> {goaway, Id} end);
decode_frame_payload(?FRAME_MAX_PUSH_ID, Payload) ->
    decode_single_id(max_push_id, Payload, fun(Id) -> {max_push_id, Id} end);
decode_frame_payload(?FRAME_CANCEL_PUSH, Payload) ->
    decode_single_id(cancel_push, Payload, fun(Id) -> {cancel_push, Id} end);
decode_frame_payload(?FRAME_PUSH_PROMISE, Payload) ->
    case roadrunner_quic_varint:decode(Payload) of
        {ok, PushId, HeaderBlock} -> {push_promise, PushId, HeaderBlock};
        {more, _} -> {error, {frame_error, push_promise, malformed_varint}}
    end;
%% RFC 9114 §7.2.8: the frame types HTTP/2 uses are reserved in HTTP/3 and
%% receiving one is a connection error of type H3_FRAME_UNEXPECTED.
decode_frame_payload(16#02, _Payload) ->
    {error, {h2_reserved_frame, 16#02}};
decode_frame_payload(16#06, _Payload) ->
    {error, {h2_reserved_frame, 16#06}};
decode_frame_payload(16#08, _Payload) ->
    {error, {h2_reserved_frame, 16#08}};
decode_frame_payload(16#09, _Payload) ->
    {error, {h2_reserved_frame, 16#09}};
decode_frame_payload(Type, Payload) ->
    %% Unknown / grease type (0x1f*N + 0x21) — surfaced so the caller can
    %% ignore it per RFC 9114 §9.
    {unknown, Type, Payload}.

%% A frame whose payload is exactly one varint id (GOAWAY / MAX_PUSH_ID /
%% CANCEL_PUSH); trailing bytes after it are malformed.
-spec decode_single_id(atom(), binary(), fun((non_neg_integer()) -> frame())) ->
    frame() | {error, term()}.
decode_single_id(Name, Payload, Build) ->
    case roadrunner_quic_varint:decode(Payload) of
        {ok, Id, <<>>} -> Build(Id);
        {ok, _Id, _Extra} -> {error, {frame_error, Name, extra_data}};
        {more, _} -> {error, {frame_error, Name, malformed_varint}}
    end.

-doc """
Decode the leading stream-type varint of a peer unidirectional stream
(RFC 9114 §6.2): `{ok, Type, Rest} | {more, Need}`, where `Type` is
`control | qpack_encoder | qpack_decoder | push | {unknown, Id}`.
""".
-spec decode_stream_type(binary()) -> {ok, stream_type(), binary()} | {more, pos_integer()}.
decode_stream_type(Bin) ->
    case roadrunner_quic_varint:decode(Bin) of
        {ok, ?STREAM_CONTROL, Rest} -> {ok, control, Rest};
        {ok, ?STREAM_PUSH, Rest} -> {ok, push, Rest};
        {ok, ?STREAM_QPACK_ENCODER, Rest} -> {ok, qpack_encoder, Rest};
        {ok, ?STREAM_QPACK_DECODER, Rest} -> {ok, qpack_decoder, Rest};
        {ok, Type, Rest} -> {ok, {unknown, Type}, Rest};
        {more, Need} -> {more, Need}
    end.

%% =============================================================================
%% SETTINGS payload (RFC 9114 §7.2.4)
%% =============================================================================

%% Decode id+value varint pairs into a map. A forbidden HTTP/2 setting or
%% a duplicate identifier is an error (H3_SETTINGS_ERROR upstream);
%% unknown ids are kept under their integer key (RFC 9114 §7.2.4.1).
-spec decode_settings_pairs(binary(), map()) -> {ok, map()} | {error, term()}.
decode_settings_pairs(<<>>, Acc) ->
    {ok, Acc};
decode_settings_pairs(Data, Acc) ->
    maybe
        {ok, Id, AfterId} ?= roadrunner_quic_varint:decode(Data),
        {ok, Value, Rest} ?= roadrunner_quic_varint:decode(AfterId),
        add_setting(Id, Value, Rest, Acc)
    else
        {more, _} -> {error, malformed_varint}
    end.

-spec add_setting(non_neg_integer(), non_neg_integer(), binary(), map()) ->
    {ok, map()} | {error, term()}.
add_setting(Id, Value, Rest, Acc) ->
    case is_forbidden_setting(Id) of
        true ->
            {error, {forbidden_setting, Id}};
        false ->
            Key = id_to_setting(Id),
            case Acc of
                #{Key := _} -> {error, {duplicate_setting, Key}};
                _ -> decode_settings_pairs(Rest, Acc#{Key => Value})
            end
    end.

%% RFC 9114 §7.2.4.1: the HTTP/2 settings ENABLE_PUSH / MAX_CONCURRENT_STREAMS
%% / INITIAL_WINDOW_SIZE / MAX_FRAME_SIZE have no meaning in HTTP/3 and their
%% receipt is a connection error.
-spec is_forbidden_setting(non_neg_integer()) -> boolean().
is_forbidden_setting(16#02) -> true;
is_forbidden_setting(16#03) -> true;
is_forbidden_setting(16#04) -> true;
is_forbidden_setting(16#05) -> true;
is_forbidden_setting(_) -> false.

-spec setting_to_id(atom() | non_neg_integer()) -> non_neg_integer().
setting_to_id(qpack_max_table_capacity) -> ?SETTINGS_QPACK_MAX_TABLE_CAPACITY;
setting_to_id(max_field_section_size) -> ?SETTINGS_MAX_FIELD_SECTION_SIZE;
setting_to_id(qpack_blocked_streams) -> ?SETTINGS_QPACK_BLOCKED_STREAMS;
setting_to_id(enable_connect_protocol) -> ?SETTINGS_ENABLE_CONNECT_PROTOCOL;
setting_to_id(Id) when is_integer(Id) -> Id.

-spec id_to_setting(non_neg_integer()) -> atom() | non_neg_integer().
id_to_setting(?SETTINGS_QPACK_MAX_TABLE_CAPACITY) -> qpack_max_table_capacity;
id_to_setting(?SETTINGS_MAX_FIELD_SECTION_SIZE) -> max_field_section_size;
id_to_setting(?SETTINGS_QPACK_BLOCKED_STREAMS) -> qpack_blocked_streams;
id_to_setting(?SETTINGS_ENABLE_CONNECT_PROTOCOL) -> enable_connect_protocol;
id_to_setting(Id) -> Id.
