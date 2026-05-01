-module(cactus_property_SUITE).
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
-export([percent_roundtrip/1, encode_output_is_unreserved_or_percent/1]).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        percent_roundtrip,
        encode_output_is_unreserved_or_percent
    ].

init_per_suite(Config) ->
    ct_property_test:init_per_suite(Config).

end_per_suite(_Config) ->
    ok.

percent_roundtrip(Config) ->
    ct_property_test:quickcheck(
        cactus_uri_props:prop_percent_roundtrip(),
        Config
    ).

encode_output_is_unreserved_or_percent(Config) ->
    ct_property_test:quickcheck(
        cactus_uri_props:prop_encode_output_is_unreserved_or_percent(),
        Config
    ).
