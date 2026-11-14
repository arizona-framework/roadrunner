-module(roadrunner_grpc_reflection_proto_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_grpc_reflection_proto).
-define(F, roadrunner_grpc_reflection_test_files).

request(Fields) ->
    ?M:request(iolist_to_binary(Fields)).

request_test() ->
    ?assertEqual({ok, <<>>, none}, request([])),
    ?assertEqual({ok, ~"h", list_services}, request([?F:field(1, ~"h"), ?F:field(7, <<>>)])),
    ?assertEqual({ok, <<>>, {file_by_filename, ~"a.proto"}}, request([?F:field(3, ~"a.proto")])),
    ?assertEqual({ok, <<>>, {file_containing_symbol, ~"a.B"}}, request([?F:field(4, ~"a.B")])),
    ?assertEqual(
        {ok, <<>>, {all_extension_numbers_of_type, ~"a.B"}}, request([?F:field(6, ~"a.B")])
    ),
    ?assertEqual(
        {ok, <<>>, {file_containing_extension, ~"a.B", 7}},
        request([?F:field(5, [?F:field(1, ~"a.B"), ?F:varint_field(2, 7)])])
    ),
    %% An int32 sent negative is ten bytes on the wire; no number is zero.
    ?assertEqual(
        {ok, <<>>, {file_containing_extension, ~"a.B", -1}},
        request([?F:field(5, [?F:field(1, ~"a.B"), ?F:varint_field(2, 16#FFFFFFFFFFFFFFFF)])])
    ),
    ?assertEqual(
        {ok, <<>>, {file_containing_extension, <<>>, 0}}, request([?F:field(5, <<>>)])
    ).

%% The oneof's last request wins, and fields reflection does not know
%% (field 2, a varint, fixed-width ones) are skipped; the last host wins.
request_skips_and_last_wins_test() ->
    ?assertEqual(
        {ok, ~"second", {file_containing_symbol, ~"a.B"}},
        request([
            ?F:field(1, ~"first"),
            ?F:field(3, ~"a.proto"),
            ?F:field(2, ~"x"),
            ?F:varint_field(9, 1),
            <<(9 bsl 3 bor 1), 0:64>>,
            <<(9 bsl 3 bor 5), 0:32>>,
            ?F:field(4, ~"a.B"),
            ?F:field(1, ~"second")
        ])
    ).

request_malformed_test() ->
    %% Cut short, a request field that is no string, field number zero, a
    %% wire type protobuf has not, a varint too long, a host that is a varint.
    ?assertEqual(malformed, ?M:request(<<10, 9, "ab">>)),
    ?assertEqual(malformed, request([?F:varint_field(4, 1)])),
    ?assertEqual(malformed, request([?F:varint_field(7, 1)])),
    ?assertEqual(malformed, request([?F:field(0, ~"x")])),
    ?assertEqual(malformed, ?M:request(<<(9 bsl 3 bor 7)>>)),
    ?assertEqual(malformed, ?M:request(<<8, (binary:copy(<<255>>, 11))/binary, 1>>)),
    ?assertEqual(malformed, request([?F:varint_field(1, 1)])),
    ?assertEqual(malformed, request([?F:field(5, <<255>>)])).

response(Host, Request, Answer) ->
    ?F:fields(iolist_to_binary(?M:response(Host, Request, Answer))).

response_test() ->
    ?assertEqual(
        [{1, ~"h"}, {2, ~"req"}, {6, iolist_to_binary([?F:field(1, ?F:field(1, ~"a.S"))])}],
        response(~"h", ~"req", {services, [~"a.S"]})
    ),
    ?assertEqual(
        [{2, <<>>}, {4, iolist_to_binary([?F:field(1, ~"f1"), ?F:field(1, ~"f2")])}],
        response(<<>>, <<>>, {files, [~"f1", ~"f2"]})
    ),
    ?assertEqual(
        [{2, <<>>}, {5, iolist_to_binary([?F:field(1, ~"a.B"), ?F:field(2, <<1, 200, 1>>)])}],
        response(<<>>, <<>>, {extension_numbers, ~"a.B", [1, 200]})
    ),
    ?assertEqual(
        [{2, <<>>}, {5, iolist_to_binary(?F:field(1, ~"a.B"))}],
        response(<<>>, <<>>, {extension_numbers, ~"a.B", []})
    ),
    ?assertEqual(
        [{2, <<>>}, {7, iolist_to_binary([?F:varint_field(1, 5), ?F:field(2, ~"nope")])}],
        response(<<>>, <<>>, {error, 5, ~"nope"})
    ).

file_test() ->
    ?assertEqual(
        #{
            name => ~"base.proto",
            dependencies => [~"dep.proto", ~"missing.proto"],
            symbols => [
                ~"test.Msg",
                ~"test.Msg.id",
                ~"test.Msg.Inner",
                ~"test.Msg.Kind",
                ~"test.Msg.KIND_A",
                ~"test.Msg.inner_ext",
                ~"test.Msg.choice",
                ~"test.Echo",
                ~"test.Echo.Unary",
                ~"test.ext"
            ],
            messages => [~"test.Msg", ~"test.Msg.Inner"],
            extensions => [{~"test.Msg", 101}, {~"test.Msg", 100}]
        },
        ?M:file(?F:base())
    ),
    %% No package: the names are the file's own.
    ?assertMatch(
        #{
            name := ~"ext.proto",
            dependencies := [~"base.proto"],
            symbols := [~"Top", ~"more"],
            messages := [~"Top"],
            extensions := [{~"test.Msg", 200}]
        },
        ?M:file(?F:ext())
    ).

file_malformed_test() ->
    %% No name, a name that is a varint, bytes cut short.
    ?assertError(_, ?M:file(iolist_to_binary(?F:field(2, ~"pkg")))),
    ?assertError(_, ?M:file(iolist_to_binary(?F:varint_field(1, 1)))),
    ?assertError(_, ?M:file(<<10, 9, "ab">>)).
