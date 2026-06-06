-module(roadrunner_quic_error).
-moduledoc false.

%% QUIC transport error codes (RFC 9000 §20.1).
%%
%% `code_int/1` maps an atom (or a `{crypto_error, Alert}` pair, or a raw
%% integer) to its wire value for a CONNECTION_CLOSE frame; `code_atom/1`
%% is the inverse for a received code. The CRYPTO_ERROR range
%% (0x0100-0x01ff) carries the TLS alert in its low byte (RFC 9000 §20.1,
%% RFC 9001 §4.8), surfaced as `{crypto_error, Alert}`. Any code outside
%% the registered set passes through as its integer (application error
%% codes and codes reserved for future use), mirroring
%% `roadrunner_http2_frame`'s `code_atom/1` / `code_int/1`.

-export([code_int/1, code_atom/1]).

-export_type([code/0]).

-type code() ::
    no_error
    | internal_error
    | connection_refused
    | flow_control_error
    | stream_limit_error
    | stream_state_error
    | final_size_error
    | frame_encoding_error
    | transport_parameter_error
    | connection_id_limit_error
    | protocol_violation
    | invalid_token
    | application_error
    | crypto_buffer_exceeded
    | key_update_error
    | aead_limit_reached
    | no_viable_path
    | {crypto_error, 0..255}
    | non_neg_integer().

-doc "Map an error atom (or `{crypto_error, Alert}`, or a raw code) to its wire value.".
-spec code_int(code()) -> non_neg_integer().
code_int(no_error) ->
    16#00;
code_int(internal_error) ->
    16#01;
code_int(connection_refused) ->
    16#02;
code_int(flow_control_error) ->
    16#03;
code_int(stream_limit_error) ->
    16#04;
code_int(stream_state_error) ->
    16#05;
code_int(final_size_error) ->
    16#06;
code_int(frame_encoding_error) ->
    16#07;
code_int(transport_parameter_error) ->
    16#08;
code_int(connection_id_limit_error) ->
    16#09;
code_int(protocol_violation) ->
    16#0A;
code_int(invalid_token) ->
    16#0B;
code_int(application_error) ->
    16#0C;
code_int(crypto_buffer_exceeded) ->
    16#0D;
code_int(key_update_error) ->
    16#0E;
code_int(aead_limit_reached) ->
    16#0F;
code_int(no_viable_path) ->
    16#10;
code_int({crypto_error, Alert}) when is_integer(Alert), Alert >= 0, Alert =< 255 ->
    16#0100 bor Alert;
code_int(Code) when is_integer(Code), Code >= 0 -> Code.

-doc "Map a received wire error code to its atom, `{crypto_error, Alert}`, or the raw integer.".
-spec code_atom(non_neg_integer()) -> code().
code_atom(16#00) -> no_error;
code_atom(16#01) -> internal_error;
code_atom(16#02) -> connection_refused;
code_atom(16#03) -> flow_control_error;
code_atom(16#04) -> stream_limit_error;
code_atom(16#05) -> stream_state_error;
code_atom(16#06) -> final_size_error;
code_atom(16#07) -> frame_encoding_error;
code_atom(16#08) -> transport_parameter_error;
code_atom(16#09) -> connection_id_limit_error;
code_atom(16#0A) -> protocol_violation;
code_atom(16#0B) -> invalid_token;
code_atom(16#0C) -> application_error;
code_atom(16#0D) -> crypto_buffer_exceeded;
code_atom(16#0E) -> key_update_error;
code_atom(16#0F) -> aead_limit_reached;
code_atom(16#10) -> no_viable_path;
code_atom(Code) when Code >= 16#0100, Code =< 16#01FF -> {crypto_error, Code - 16#0100};
code_atom(Code) when is_integer(Code), Code >= 0 -> Code.
