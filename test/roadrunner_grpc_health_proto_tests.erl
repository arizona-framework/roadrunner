-module(roadrunner_grpc_health_proto_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_grpc_health_proto).

service_test() ->
    ?assertEqual({ok, <<>>}, ?M:service(<<>>)),
    ?assertEqual({ok, ~"a.B"}, ?M:service(<<10, 3, "a.B">>)),
    %% The last of a repeated field wins.
    ?assertEqual({ok, ~"two"}, ?M:service(<<10, 3, "one", 10, 3, "two">>)).

%% Unknown fields of every skippable wire type are skipped, a varint of
%% several bytes included.
service_skips_unknown_fields_test() ->
    Unknown = <<16, 16#96, 16#01, 25, 0:64, 34, 1, "x", 45, 0:32>>,
    ?assertEqual({ok, ~"s"}, ?M:service(<<Unknown/binary, 10, 1, "s">>)),
    ?assertEqual({ok, <<>>}, ?M:service(Unknown)).

service_malformed_test() ->
    ?assertEqual(malformed, ?M:service(<<10, 9, "ab">>)),
    ?assertEqual(malformed, ?M:service(<<16#80>>)),
    ?assertEqual(malformed, ?M:service(<<11>>)).

response_test() ->
    ?assertEqual(<<8, 1>>, ?M:response(1)),
    ?assertEqual(<<8, 3>>, ?M:response(3)).

%% A name of 128 bytes or more takes a two-byte length.
list_test() ->
    Long = binary:copy(~"n", 200),
    ?assertEqual(
        <<10, 7, 10, 1, "a", 18, 2, 8, 1>>,
        iolist_to_binary(?M:list([{~"a", 1}]))
    ),
    <<10, 16#CF, 16#01, 10, 16#C8, 16#01, Long:200/binary, 18, 2, 8, 2>> =
        iolist_to_binary(?M:list([{Long, 2}])).
