-module(roadrunner_grpc_frame_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_grpc_frame).

encode_prefixes_flag_and_length_test() ->
    ?assertEqual(<<0, 0, 0, 0, 3, "abc">>, iolist_to_binary(?M:encode(false, [~"a", ~"bc"]))),
    ?assertEqual(<<1, 0, 0, 0, 0>>, iolist_to_binary(?M:encode(true, <<>>))).

decode_takes_one_message_test() ->
    Two = iolist_to_binary([?M:encode(false, ~"one"), ?M:encode(true, ~"two")]),
    {ok, false, ~"one", Rest} = ?M:decode(Two, 16),
    ?assertEqual({ok, true, ~"two", <<>>}, ?M:decode(Rest, 16)).

%% DATA frames split messages anywhere: a partial prefix or body waits.
decode_waits_for_the_rest_test() ->
    ?assertEqual(more, ?M:decode(<<>>, 16)),
    ?assertEqual(more, ?M:decode(<<0, 0, 0>>, 16)),
    ?assertEqual(more, ?M:decode(<<0, 0, 0, 0, 3, "ab">>, 16)).

%% A message announced over the limit is refused before its bytes come.
decode_refuses_a_message_too_large_test() ->
    ?assertEqual({error, message_too_large}, ?M:decode(<<0, 0, 0, 0, 17>>, 16)),
    ?assertMatch({ok, false, _, <<>>}, ?M:decode(<<0, 0, 0, 0, 16, 0:128>>, 16)).

%% The Compressed-Flag is 0 or 1 (gRPC PROTOCOL-HTTP2).
decode_refuses_a_bad_flag_test() ->
    ?assertEqual({error, bad_compressed_flag}, ?M:decode(<<2>>, 16)),
    ?assertEqual({error, bad_compressed_flag}, ?M:decode(<<255, 0, 0, 0, 0>>, 16)).
