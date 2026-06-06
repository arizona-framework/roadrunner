-module(roadrunner_quic_transport_params).
-moduledoc false.

%% QUIC transport parameters codec (RFC 9000 §18 + §18.2). Each parameter
%% is a triple `varint(Id), varint(Length), Value[Length]`; the whole set
%% is the concatenation of triples, carried as the TLS
%% `quic_transport_parameters` extension body (this module produces and
%% parses that body, with no outer length of its own).
%%
%% Parameters are a map keyed by their RFC name (an atom, see
%% `param_key/0`), mirroring `roadrunner_quic_h3_frame`'s `{settings,
%% map()}` and the dep's own representation. Values are typed by
%% parameter: an integer for the varint parameters, a `binary()` for the
%% connection-id parameters, and `true` for the zero-length
%% `disable_active_migration` flag.
%%
%% `encode/1` emits every parameter in the map as an iolist (in
%% map-iteration order; RFC 9000 §18 permits any order); choosing which
%% parameters to send, and omitting ones left at their default, is the
%% caller's concern. `decode/1` parses the peer's set with the §18.2
%% validation a server applies to a client: range checks, duplicate
%% rejection, rejection of the server-only parameters a client must not
%% send, and silently ignoring unknown/reserved ids.

-export([encode/1, decode/1]).

-export_type([param_key/0, params/0]).

-type param_key() ::
    original_destination_connection_id
    | max_idle_timeout
    | max_udp_payload_size
    | initial_max_data
    | initial_max_stream_data_bidi_local
    | initial_max_stream_data_bidi_remote
    | initial_max_stream_data_uni
    | initial_max_streams_bidi
    | initial_max_streams_uni
    | ack_delay_exponent
    | max_ack_delay
    | disable_active_migration
    | active_connection_id_limit
    | initial_source_connection_id.

-type params() :: #{
    original_destination_connection_id => binary(),
    max_idle_timeout => non_neg_integer(),
    max_udp_payload_size => non_neg_integer(),
    initial_max_data => non_neg_integer(),
    initial_max_stream_data_bidi_local => non_neg_integer(),
    initial_max_stream_data_bidi_remote => non_neg_integer(),
    initial_max_stream_data_uni => non_neg_integer(),
    initial_max_streams_bidi => non_neg_integer(),
    initial_max_streams_uni => non_neg_integer(),
    ack_delay_exponent => non_neg_integer(),
    max_ack_delay => non_neg_integer(),
    disable_active_migration => true,
    active_connection_id_limit => non_neg_integer(),
    initial_source_connection_id => binary()
}.

%% Ids already seen while decoding a set, for the RFC 9000 §7.4 duplicate
%% check (a set: only the keys matter).
-type seen() :: #{non_neg_integer() => []}.

%% One parameter's decode verdict: keep it, ignore it (unknown/reserved),
%% or reject the whole set.
-type decoded() ::
    {param, param_key(), non_neg_integer() | binary() | true}
    | ignore
    | {error, atom()}.

%% RFC 9000 §18.2 transport parameter ids.
-define(TP_ORIGINAL_DESTINATION_CONNECTION_ID, 16#00).
-define(TP_MAX_IDLE_TIMEOUT, 16#01).
-define(TP_STATELESS_RESET_TOKEN, 16#02).
-define(TP_MAX_UDP_PAYLOAD_SIZE, 16#03).
-define(TP_INITIAL_MAX_DATA, 16#04).
-define(TP_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL, 16#05).
-define(TP_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE, 16#06).
-define(TP_INITIAL_MAX_STREAM_DATA_UNI, 16#07).
-define(TP_INITIAL_MAX_STREAMS_BIDI, 16#08).
-define(TP_INITIAL_MAX_STREAMS_UNI, 16#09).
-define(TP_ACK_DELAY_EXPONENT, 16#0A).
-define(TP_MAX_ACK_DELAY, 16#0B).
-define(TP_DISABLE_ACTIVE_MIGRATION, 16#0C).
-define(TP_PREFERRED_ADDRESS, 16#0D).
-define(TP_ACTIVE_CONNECTION_ID_LIMIT, 16#0E).
-define(TP_INITIAL_SOURCE_CONNECTION_ID, 16#0F).
-define(TP_RETRY_SOURCE_CONNECTION_ID, 16#10).

%% RFC 9000 §18.2 value bounds.
%% max_ack_delay must be < 2^14; ack_delay_exponent <= 20;
%% max_udp_payload_size >= 1200; active_connection_id_limit >= 2;
%% initial_max_streams_* <= 2^60.
-define(MAX_ACK_DELAY_LIMIT, 16384).
-define(ACK_DELAY_EXPONENT_LIMIT, 20).
-define(MIN_MAX_UDP_PAYLOAD_SIZE, 1200).
-define(MIN_ACTIVE_CONNECTION_ID_LIMIT, 2).
-define(MAX_STREAMS_LIMIT, 1152921504606846976).

%% =============================================================================
%% encode/1
%% =============================================================================

-doc """
Encode a transport-parameters map to its wire form (RFC 9000 §18), as an
iolist, one `varint(Id), varint(Length), Value` triple per entry (in
map-iteration order; §18 permits any order). The map holds only the
parameters to send (the connection ids the server must include, plus
whichever limits it advertises); a parameter left at its default is
simply absent from the map.
""".
-spec encode(params()) -> iolist().
encode(Params) ->
    [encode_param(Key, Value) || Key := Value <- Params].

%% =============================================================================
%% decode/1
%% =============================================================================

-doc """
Decode a peer's transport-parameters wire body to a map. Applies the
RFC 9000 §18.2 validation a server runs on a client's set:

- range checks (`ack_delay_exponent` =< 20, `max_ack_delay` < 2^14,
  `max_udp_payload_size` >= 1200, `active_connection_id_limit` >= 2,
  `initial_max_streams_*` =< 2^60);
- a duplicated parameter is rejected;
- the server-only parameters a client must not send
  (`original_destination_connection_id`, `stateless_reset_token`,
  `preferred_address`, `retry_source_connection_id`) are rejected;
- unknown and reserved ids are ignored (RFC 9000 §18.1).

Returns `{ok, Params}` or `{error, Reason}` (a flat atom).
""".
-spec decode(binary()) -> {ok, params()} | {error, atom()}.
decode(Data) ->
    decode_params(Data, #{}, #{}).

%% =============================================================================
%% Internal — encode
%% =============================================================================

%% One parameter as a `varint(Id), varint(Length), Value` iolist. The
%% connection-id parameters carry raw bytes, the flag carries an empty
%% value, the rest carry a varint value. A parameter this server does not
%% send (e.g. stateless_reset_token) has no clause and raises, rather than
%% emitting an out-of-scope parameter.
-spec encode_param(param_key(), non_neg_integer() | binary() | true) -> iolist().
encode_param(original_destination_connection_id, Cid) ->
    tlv(?TP_ORIGINAL_DESTINATION_CONNECTION_ID, Cid);
encode_param(initial_source_connection_id, Cid) ->
    tlv(?TP_INITIAL_SOURCE_CONNECTION_ID, Cid);
encode_param(disable_active_migration, true) ->
    tlv(?TP_DISABLE_ACTIVE_MIGRATION, <<>>);
encode_param(max_idle_timeout, V) ->
    tlv_varint(?TP_MAX_IDLE_TIMEOUT, V);
encode_param(max_udp_payload_size, V) ->
    tlv_varint(?TP_MAX_UDP_PAYLOAD_SIZE, V);
encode_param(initial_max_data, V) ->
    tlv_varint(?TP_INITIAL_MAX_DATA, V);
encode_param(initial_max_stream_data_bidi_local, V) ->
    tlv_varint(?TP_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL, V);
encode_param(initial_max_stream_data_bidi_remote, V) ->
    tlv_varint(?TP_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE, V);
encode_param(initial_max_stream_data_uni, V) ->
    tlv_varint(?TP_INITIAL_MAX_STREAM_DATA_UNI, V);
encode_param(initial_max_streams_bidi, V) ->
    tlv_varint(?TP_INITIAL_MAX_STREAMS_BIDI, V);
encode_param(initial_max_streams_uni, V) ->
    tlv_varint(?TP_INITIAL_MAX_STREAMS_UNI, V);
encode_param(ack_delay_exponent, V) ->
    tlv_varint(?TP_ACK_DELAY_EXPONENT, V);
encode_param(max_ack_delay, V) ->
    tlv_varint(?TP_MAX_ACK_DELAY, V);
encode_param(active_connection_id_limit, V) ->
    tlv_varint(?TP_ACTIVE_CONNECTION_ID_LIMIT, V).

%% Frame a varint-valued parameter: its value is the encoded varint, and
%% the Length is that varint's byte size.
-spec tlv_varint(non_neg_integer(), non_neg_integer()) -> iolist().
tlv_varint(Id, Value) ->
    tlv(Id, roadrunner_quic_varint:encode(Value)).

-spec tlv(non_neg_integer(), binary()) -> iolist().
tlv(Id, Value) ->
    [
        roadrunner_quic_varint:encode(Id),
        roadrunner_quic_varint:encode(byte_size(Value)),
        Value
    ].

%% =============================================================================
%% Internal — decode
%% =============================================================================

%% Peel one parameter triple off the front, reject a duplicate id (RFC
%% 9000 §7.4, across known, unknown, and reserved ids alike), accumulate
%% it, and recurse until the body is consumed. `Acc` holds the known
%% parameters kept; `Seen` records every id encountered. A short or
%% malformed buffer is a flat error, not a crash.
-spec decode_params(binary(), params(), seen()) -> {ok, params()} | {error, atom()}.
decode_params(<<>>, Acc, _Seen) ->
    {ok, Acc};
decode_params(Data, Acc, Seen) ->
    maybe
        {ok, Id, AfterId} ?= take_varint(Data),
        {ok, Len, AfterLen} ?= take_varint(AfterId),
        {ok, Value, Rest} ?= take_bytes(Len, AfterLen),
        unseen ?= dup_check(Id, Seen),
        accumulate(decode_param(Id, Value), Id, Rest, Acc, Seen)
    end.

%% Reject an id already seen in this set (RFC 9000 §7.4), known or not.
-spec dup_check(non_neg_integer(), seen()) -> unseen | {error, atom()}.
dup_check(Id, Seen) ->
    case Seen of
        #{Id := _} -> {error, duplicate_transport_parameter};
        #{} -> unseen
    end.

%% Fold one parameter's verdict into the accumulator and recurse, marking
%% its id seen. A kept parameter joins `Acc`; an ignored (unknown/reserved)
%% one is dropped but still recorded, so a later duplicate of it is caught.
-spec accumulate(decoded(), non_neg_integer(), binary(), params(), seen()) ->
    {ok, params()} | {error, atom()}.
accumulate({param, Key, Value}, Id, Rest, Acc, Seen) ->
    decode_params(Rest, Acc#{Key => Value}, Seen#{Id => []});
accumulate(ignore, Id, Rest, Acc, Seen) ->
    decode_params(Rest, Acc, Seen#{Id => []});
accumulate({error, _} = Error, _Id, _Rest, _Acc, _Seen) ->
    Error.

%% Decode a parameter by id to its verdict. Server-only parameters are
%% rejected (a client must not send them); known client/both parameters
%% are typed and range-checked; unknown and reserved (RFC 9000 §18.1) ids
%% are ignored.
-spec decode_param(non_neg_integer(), binary()) -> decoded().
decode_param(?TP_ORIGINAL_DESTINATION_CONNECTION_ID, _) ->
    {error, server_only_transport_parameter};
decode_param(?TP_STATELESS_RESET_TOKEN, _) ->
    {error, server_only_transport_parameter};
decode_param(?TP_PREFERRED_ADDRESS, _) ->
    {error, server_only_transport_parameter};
decode_param(?TP_RETRY_SOURCE_CONNECTION_ID, _) ->
    {error, server_only_transport_parameter};
decode_param(?TP_MAX_IDLE_TIMEOUT, Value) ->
    varint_param(max_idle_timeout, Value);
decode_param(?TP_MAX_UDP_PAYLOAD_SIZE, Value) ->
    checked_varint_param(max_udp_payload_size, Value, fun check_max_udp_payload_size/1);
decode_param(?TP_INITIAL_MAX_DATA, Value) ->
    varint_param(initial_max_data, Value);
decode_param(?TP_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL, Value) ->
    varint_param(initial_max_stream_data_bidi_local, Value);
decode_param(?TP_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE, Value) ->
    varint_param(initial_max_stream_data_bidi_remote, Value);
decode_param(?TP_INITIAL_MAX_STREAM_DATA_UNI, Value) ->
    varint_param(initial_max_stream_data_uni, Value);
decode_param(?TP_INITIAL_MAX_STREAMS_BIDI, Value) ->
    checked_varint_param(initial_max_streams_bidi, Value, fun check_max_streams/1);
decode_param(?TP_INITIAL_MAX_STREAMS_UNI, Value) ->
    checked_varint_param(initial_max_streams_uni, Value, fun check_max_streams/1);
decode_param(?TP_ACK_DELAY_EXPONENT, Value) ->
    checked_varint_param(ack_delay_exponent, Value, fun check_ack_delay_exponent/1);
decode_param(?TP_MAX_ACK_DELAY, Value) ->
    checked_varint_param(max_ack_delay, Value, fun check_max_ack_delay/1);
decode_param(?TP_ACTIVE_CONNECTION_ID_LIMIT, Value) ->
    checked_varint_param(active_connection_id_limit, Value, fun check_active_connection_id_limit/1);
decode_param(?TP_INITIAL_SOURCE_CONNECTION_ID, Value) ->
    {param, initial_source_connection_id, Value};
decode_param(?TP_DISABLE_ACTIVE_MIGRATION, <<>>) ->
    {param, disable_active_migration, true};
decode_param(?TP_DISABLE_ACTIVE_MIGRATION, _) ->
    {error, malformed_transport_parameter};
decode_param(_Id, _Value) ->
    ignore.

%% Decode a varint parameter that has no §18.2 range check.
-spec varint_param(param_key(), binary()) ->
    {param, param_key(), non_neg_integer()} | {error, atom()}.
varint_param(Key, Value) ->
    maybe
        {ok, N} ?= take_varint_value(Value),
        {param, Key, N}
    end.

%% As varint_param/2, but range-check the decoded value first.
-spec checked_varint_param(
    param_key(), binary(), fun((non_neg_integer()) -> ok | {error, atom()})
) ->
    {param, param_key(), non_neg_integer()} | {error, atom()}.
checked_varint_param(Key, Value, Check) ->
    maybe
        {ok, N} ?= take_varint_value(Value),
        ok ?= Check(N),
        {param, Key, N}
    end.

%% The single varint filling a parameter's value field; any trailing
%% bytes after it make the parameter malformed.
-spec take_varint_value(binary()) -> {ok, non_neg_integer()} | {error, atom()}.
take_varint_value(Value) ->
    case take_varint(Value) of
        {ok, N, <<>>} -> {ok, N};
        {ok, _, _} -> {error, malformed_transport_parameter};
        {error, _} = Error -> Error
    end.

%% =============================================================================
%% Internal — §18.2 range checks
%% =============================================================================

-spec check_max_udp_payload_size(non_neg_integer()) -> ok | {error, atom()}.
check_max_udp_payload_size(N) when N >= ?MIN_MAX_UDP_PAYLOAD_SIZE -> ok;
check_max_udp_payload_size(_) -> {error, max_udp_payload_size_too_small}.

-spec check_ack_delay_exponent(non_neg_integer()) -> ok | {error, atom()}.
check_ack_delay_exponent(N) when N =< ?ACK_DELAY_EXPONENT_LIMIT -> ok;
check_ack_delay_exponent(_) -> {error, ack_delay_exponent_too_large}.

-spec check_max_ack_delay(non_neg_integer()) -> ok | {error, atom()}.
check_max_ack_delay(N) when N < ?MAX_ACK_DELAY_LIMIT -> ok;
check_max_ack_delay(_) -> {error, max_ack_delay_too_large}.

-spec check_active_connection_id_limit(non_neg_integer()) -> ok | {error, atom()}.
check_active_connection_id_limit(N) when N >= ?MIN_ACTIVE_CONNECTION_ID_LIMIT -> ok;
check_active_connection_id_limit(_) -> {error, active_connection_id_limit_too_small}.

-spec check_max_streams(non_neg_integer()) -> ok | {error, atom()}.
check_max_streams(N) when N =< ?MAX_STREAMS_LIMIT -> ok;
check_max_streams(_) -> {error, initial_max_streams_too_large}.

%% =============================================================================
%% Internal — wire helpers
%% =============================================================================

%% A leading varint, with a short buffer normalised to a flat error
%% (transport parameters arrive whole, not streamed).
-spec take_varint(binary()) -> {ok, non_neg_integer(), binary()} | {error, truncated}.
take_varint(Bin) ->
    case roadrunner_quic_varint:decode(Bin) of
        {ok, _, _} = Ok -> Ok;
        {more, _} -> {error, truncated}
    end.

-spec take_bytes(non_neg_integer(), binary()) -> {ok, binary(), binary()} | {error, truncated}.
take_bytes(Len, Bin) ->
    case Bin of
        <<Value:Len/binary, Rest/binary>> -> {ok, Value, Rest};
        _ -> {error, truncated}
    end.
