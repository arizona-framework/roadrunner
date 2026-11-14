-module(roadrunner_grpc_status_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_grpc_status).

%% Every code 0..16 has a name, and back (gRPC statuscodes.md).
codes_round_trip_test() ->
    ?assertEqual(lists:seq(0, 16), [?M:code(?M:name(Code)) || Code <- lists:seq(0, 16)]),
    ?assertEqual(0, ?M:code(ok)),
    ?assertEqual(4, ?M:code(deadline_exceeded)),
    ?assertEqual(12, ?M:code(unimplemented)),
    ?assertEqual(unauthenticated, ?M:name(16)).

%% A message of printable ASCII without `%` goes out as it is.
plain_message_is_kept_test() ->
    Message = ~"no such user: alice ~42",
    ?assert(Message =:= ?M:encode_message(Message)).

%% Bytes outside space..`~`, and `%`, are escaped with uppercase hex.
escapes_test() ->
    ?assertEqual(~"50%25 done", ?M:encode_message(~"50% done")),
    ?assertEqual(~"a%0Ab%7F", ?M:encode_message(<<"a\nb", 16#7F>>)),
    ?assertEqual(~"caf%C3%A9", ?M:encode_message(~"café")).

decode_test() ->
    ?assertEqual(~"café 50%", ?M:decode_message(~"caf%C3%a9 50%25")),
    ?assertEqual(~"plain", ?M:decode_message(~"plain")).

%% A broken escape is kept as it is, never an error (gRPC PROTOCOL-HTTP2).
broken_escapes_are_kept_test() ->
    ?assertEqual(~"100%", ?M:decode_message(~"100%")),
    ?assertEqual(~"%4", ?M:decode_message(~"%4")),
    ?assertEqual(~"%zz!", ?M:decode_message(~"%zz%21")).
