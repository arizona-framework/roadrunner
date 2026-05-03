-module(roadrunner_property_SUITE).
-moduledoc """
Common Test suite that drives PropEr (or any other property tester
on the path) via OTP's `ct_property_test` integration. Properties live
in `test/property_test/` — `init_per_suite/1` compiles them at runtime
with the right `-D…` macro so the same `?FORALL` expansions work
regardless of which tool was found.

Add a new property:

1. Drop `*_props.erl` into `test/property_test/`.
2. Add the test case here that calls
   `ct_property_test:quickcheck(<module>:<prop>(), Config)`.
""".

-include_lib("common_test/include/ct.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([
    percent_roundtrip/1,
    encode_output_is_unreserved_or_percent/1,
    qs_parse_encode_roundtrip/1,
    cookie_parse_never_crashes/1,
    cookie_parse_returns_well_formed_pairs/1,
    http1_parse_request_line_never_crashes/1,
    http1_parse_header_never_crashes/1,
    http1_parse_headers_never_crashes/1,
    http1_parse_request_never_crashes/1,
    http1_parse_chunk_never_crashes/1,
    http1_parse_request_line_incremental/1,
    http1_parse_request_incremental/1,
    http1_parse_chunk_incremental/1,
    statem_terminates_normal_on_random_inputs/1,
    statem_request_start_and_stop_share_request_id/1,
    statem_state_transitions_are_documented/1,
    loop_terminates_normal_on_random_inputs/1,
    router_param_bindings_round_trip/1
]).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        percent_roundtrip,
        encode_output_is_unreserved_or_percent,
        qs_parse_encode_roundtrip,
        cookie_parse_never_crashes,
        cookie_parse_returns_well_formed_pairs,
        http1_parse_request_line_never_crashes,
        http1_parse_header_never_crashes,
        http1_parse_headers_never_crashes,
        http1_parse_request_never_crashes,
        http1_parse_chunk_never_crashes,
        http1_parse_request_line_incremental,
        http1_parse_request_incremental,
        http1_parse_chunk_incremental,
        statem_terminates_normal_on_random_inputs,
        statem_request_start_and_stop_share_request_id,
        statem_state_transitions_are_documented,
        loop_terminates_normal_on_random_inputs,
        router_param_bindings_round_trip
    ].

init_per_suite(Config) ->
    ct_property_test:init_per_suite(Config).

end_per_suite(_Config) ->
    ok.

percent_roundtrip(Config) ->
    ct_property_test:quickcheck(
        roadrunner_uri_props:prop_percent_roundtrip(),
        Config
    ).

encode_output_is_unreserved_or_percent(Config) ->
    ct_property_test:quickcheck(
        roadrunner_uri_props:prop_encode_output_is_unreserved_or_percent(),
        Config
    ).

qs_parse_encode_roundtrip(Config) ->
    ct_property_test:quickcheck(
        roadrunner_qs_props:prop_parse_encode_roundtrip(),
        Config
    ).

cookie_parse_never_crashes(Config) ->
    ct_property_test:quickcheck(
        roadrunner_cookie_props:prop_parse_never_crashes(),
        Config
    ).

cookie_parse_returns_well_formed_pairs(Config) ->
    ct_property_test:quickcheck(
        roadrunner_cookie_props:prop_parse_returns_well_formed_pairs(),
        Config
    ).

http1_parse_request_line_never_crashes(Config) ->
    ct_property_test:quickcheck(
        roadrunner_http1_props:prop_parse_request_line_never_crashes(),
        Config
    ).

http1_parse_header_never_crashes(Config) ->
    ct_property_test:quickcheck(
        roadrunner_http1_props:prop_parse_header_never_crashes(),
        Config
    ).

http1_parse_headers_never_crashes(Config) ->
    ct_property_test:quickcheck(
        roadrunner_http1_props:prop_parse_headers_never_crashes(),
        Config
    ).

http1_parse_request_never_crashes(Config) ->
    ct_property_test:quickcheck(
        roadrunner_http1_props:prop_parse_request_never_crashes(),
        Config
    ).

http1_parse_chunk_never_crashes(Config) ->
    ct_property_test:quickcheck(
        roadrunner_http1_props:prop_parse_chunk_never_crashes(),
        Config
    ).

http1_parse_request_line_incremental(Config) ->
    ct_property_test:quickcheck(
        roadrunner_http1_props:prop_parse_request_line_incremental(),
        Config
    ).

http1_parse_request_incremental(Config) ->
    ct_property_test:quickcheck(
        roadrunner_http1_props:prop_parse_request_incremental(),
        Config
    ).

http1_parse_chunk_incremental(Config) ->
    ct_property_test:quickcheck(
        roadrunner_http1_props:prop_parse_chunk_incremental(),
        Config
    ).

statem_terminates_normal_on_random_inputs(Config) ->
    ct_property_test:quickcheck(
        roadrunner_statem_props:prop_conn_terminates_normal_on_random_inputs(),
        Config
    ).

statem_request_start_and_stop_share_request_id(Config) ->
    ct_property_test:quickcheck(
        roadrunner_statem_props:prop_request_start_and_stop_share_request_id(),
        Config
    ).

statem_state_transitions_are_documented(Config) ->
    ct_property_test:quickcheck(
        roadrunner_statem_props:prop_state_transitions_are_documented(),
        Config
    ).

loop_terminates_normal_on_random_inputs(Config) ->
    ct_property_test:quickcheck(
        roadrunner_statem_props:prop_loop_terminates_normal_on_random_inputs(),
        Config
    ).

router_param_bindings_round_trip(Config) ->
    ct_property_test:quickcheck(
        roadrunner_router_props:prop_param_bindings_round_trip(),
        Config
    ).
