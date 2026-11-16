-module(roadrunner_grpc_status_proto_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_grpc_status_proto).

%% google.rpc.Status: the code (field 1, a varint), the message (field 2)
%% and each detail (field 3), an Any of its type URL (1) and value (2).
status_test() ->
    Bytes = iolist_to_binary(
        ?M:status(3, ~"bad", [{~"type.googleapis.com/x.Y", [<<1>>, ~"z"]}, {~"t/b", ~"v"}])
    ),
    ?assertEqual(
        <<8, 3, 18, 3, "bad", 26, 29, 10, 23, "type.googleapis.com/x.Y", 18, 2, 1, "z", 26, 8, 10,
            3, "t/b", 18, 1, "v">>,
        Bytes
    ).

%% Proto3 leaves out a zero code, an empty message and an empty value.
defaults_left_out_test() ->
    ?assertEqual(<<>>, iolist_to_binary(?M:status(0, <<>>, []))),
    ?assertEqual(<<26, 5, 10, 3, "t/a">>, iolist_to_binary(?M:status(0, <<>>, [{~"t/a", <<>>}]))).

%% A length past one varint byte.
long_message_test() ->
    Message = binary:copy(~"x", 200),
    ?assertEqual(
        <<8, 16, 18, 200, 1, Message/binary>>, iolist_to_binary(?M:status(16, Message, []))
    ).

%% A detail of any other shape raises.
bad_detail_test() ->
    ?assertError(function_clause, ?M:status(3, ~"bad", [{"t", <<>>}])).
