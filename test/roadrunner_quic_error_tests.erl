-module(roadrunner_quic_error_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_error).

%% RFC 9000 §20.1 registered transport error codes.
named_codes() ->
    [
        {no_error, 16#00},
        {internal_error, 16#01},
        {connection_refused, 16#02},
        {flow_control_error, 16#03},
        {stream_limit_error, 16#04},
        {stream_state_error, 16#05},
        {final_size_error, 16#06},
        {frame_encoding_error, 16#07},
        {transport_parameter_error, 16#08},
        {connection_id_limit_error, 16#09},
        {protocol_violation, 16#0A},
        {invalid_token, 16#0B},
        {application_error, 16#0C},
        {crypto_buffer_exceeded, 16#0D},
        {key_update_error, 16#0E},
        {aead_limit_reached, 16#0F},
        {no_viable_path, 16#10}
    ].

named_codes_round_trip_test() ->
    [
        begin
            ?assertEqual(Int, ?M:code_int(Atom)),
            ?assertEqual(Atom, ?M:code_atom(Int))
        end
     || {Atom, Int} <- named_codes()
    ].

crypto_error_test() ->
    %% RFC 9000 §20.1: CRYPTO_ERROR is 0x0100-0x01ff, the TLS alert in the
    %% low byte (RFC 9001 §4.8).
    ?assertEqual(16#0100, ?M:code_int({crypto_error, 0})),
    ?assertEqual(16#0128, ?M:code_int({crypto_error, 16#28})),
    ?assertEqual(16#01FF, ?M:code_int({crypto_error, 255})),
    ?assertEqual({crypto_error, 0}, ?M:code_atom(16#0100)),
    ?assertEqual({crypto_error, 16#28}, ?M:code_atom(16#0128)),
    ?assertEqual({crypto_error, 255}, ?M:code_atom(16#01FF)).

passthrough_test() ->
    %% Unregistered codes (application error codes, codes reserved for
    %% future use) pass through as their integer in both directions.
    ?assertEqual(16#3FFF, ?M:code_int(16#3FFF)),
    ?assertEqual(16#3FFF, ?M:code_atom(16#3FFF)),
    %% Just past the CRYPTO_ERROR range.
    ?assertEqual(16#0200, ?M:code_atom(16#0200)).
