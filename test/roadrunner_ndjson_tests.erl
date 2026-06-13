-module(roadrunner_ndjson_tests).

-include_lib("eunit/include/eunit.hrl").

%% --- basic shapes ---

item_object_test() ->
    ?assertEqual(
        ~"{\"a\":1}\n",
        iolist_to_binary(roadrunner_ndjson:item(#{a => 1}))
    ).

item_string_test() ->
    ?assertEqual(
        ~"\"hello\"\n",
        iolist_to_binary(roadrunner_ndjson:item(~"hello"))
    ).

item_list_test() ->
    ?assertEqual(
        ~"[1,2,3]\n",
        iolist_to_binary(roadrunner_ndjson:item([1, 2, 3]))
    ).

item_empty_container_test() ->
    ?assertEqual(~"{}\n", iolist_to_binary(roadrunner_ndjson:item(#{}))),
    ?assertEqual(~"[]\n", iolist_to_binary(roadrunner_ndjson:item([]))).

%% Output is stable across runs: the encoder sorts object keys, so a
%% multi-key map frames deterministically (matters for line-by-line
%% clients and golden tests).
item_sorts_map_keys_test() ->
    ?assertEqual(
        ~"{\"a\":2,\"b\":1}\n",
        iolist_to_binary(roadrunner_ndjson:item(#{b => 1, a => 2}))
    ).

%% --- framing safety: the line delimiter is the ONLY raw newline ---

%% The whole point of NDJSON is that each item is exactly one line. A
%% string value carrying LF / CR / TAB / NUL must stay on its line: the
%% encoder escapes every control byte, so the only raw `\n` in the output
%% is the trailing delimiter. Decoding the line back yields the original
%% value (lossless), proving the escaping didn't corrupt the payload.
item_escapes_control_chars_single_delimiter_test() ->
    Hostile = <<"a\nb\rc\td", 0, "e">>,
    Out = iolist_to_binary(roadrunner_ndjson:item(#{msg => Hostile})),
    [Line, <<>>] = binary:split(Out, ~"\n", [global]),
    ?assertEqual(#{~"msg" => Hostile}, json:decode(Line)).

%% U+2028 (LINE SEPARATOR) and U+2029 are line terminators in JavaScript
%% but NOT in NDJSON, whose framing is LF-only. The encoder passes them
%% through as raw UTF-8 (it does not escape them); since neither contains
%% a `0x0A` byte, the item still holds exactly one delimiter.
item_unicode_line_separator_not_a_delimiter_test() ->
    Sep = <<16#E2, 16#80, 16#A8, 16#E2, 16#80, 16#A9>>,
    Out = iolist_to_binary(roadrunner_ndjson:item(Sep)),
    ?assertEqual(2, length(binary:split(Out, ~"\n", [global]))),
    [Line, <<>>] = binary:split(Out, ~"\n", [global]),
    ?assertEqual(Sep, json:decode(Line)).

%% A term the JSON encoder cannot represent (tuple, pid, ref, fun) is a
%% handler bug: `item/1` lets it crash rather than emit garbage, so the
%% streaming response fails loudly instead of putting an unparseable line
%% on the wire.
item_non_encodable_term_crashes_test() ->
    ?assertError({unsupported_type, _}, roadrunner_ndjson:item({1, 2})).

content_type_test() ->
    ?assertEqual(~"application/x-ndjson", roadrunner_ndjson:content_type()).
