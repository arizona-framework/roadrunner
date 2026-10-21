-module(roadrunner_bin_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% ascii_lowercase/1 — exhaustive byte-mapping tests.
%%
%% The implementation has 26 explicit head clauses for `$A`..`$Z` plus
%% a catch-all for everything else (the BEAM compiler turns this into
%% a `select_val` jump table). Cover each clause so coverage reflects
%% the actual code shape, not just "tests touched the module".
%% =============================================================================

ascii_lowercase_empty_test() ->
    ?assertEqual(<<>>, roadrunner_bin:ascii_lowercase(<<>>)).

ascii_lowercase_already_lowercase_test() ->
    ?assertEqual(
        ~"abcdefghijklmnopqrstuvwxyz", roadrunner_bin:ascii_lowercase(~"abcdefghijklmnopqrstuvwxyz")
    ).

ascii_lowercase_each_uppercase_letter_test_() ->
    %% Generate one assertion per uppercase letter so every
    %% select_val arm gets at least one hit.
    [
        ?_assertEqual(
            <<(L + 32)>>,
            roadrunner_bin:ascii_lowercase(<<L>>)
        )
     || L <- lists:seq($A, $Z)
    ].

ascii_lowercase_full_alphabet_test() ->
    ?assertEqual(
        ~"abcdefghijklmnopqrstuvwxyz",
        roadrunner_bin:ascii_lowercase(~"ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    ).

ascii_lowercase_mixed_case_test() ->
    ?assertEqual(
        ~"content-length",
        roadrunner_bin:ascii_lowercase(~"Content-Length")
    ).

ascii_lowercase_passes_digits_through_test() ->
    ?assertEqual(~"abc-123", roadrunner_bin:ascii_lowercase(~"abc-123")).

ascii_lowercase_leaves_high_bytes_unchanged_test() ->
    %% UTF-8 `É` (0xC3 0x89). Only ASCII A-Z is touched; high-bit
    %% bytes pass through unchanged (this is the documented contract).
    ?assertEqual(<<"caf", 195, 137>>, roadrunner_bin:ascii_lowercase(<<"CAF", 195, 137>>)).

ascii_lowercase_every_byte_at_every_position_test() ->
    %% Every byte value at every position of lengths 1 to 30, so each lane
    %% of a word pair, a lone word and every tail size of the SWAR scan,
    %% the `@`/`[` range edges, and bytes >= 128 are all exercised.
    [
        begin
            <<Pre:Pos/binary, _, Post/binary>> = binary:copy(~"a", Len),
            In = <<Pre/binary, B, Post/binary>>,
            Want =
                case B >= $A andalso B =< $Z of
                    true -> <<Pre/binary, (B + 32), Post/binary>>;
                    false -> In
                end,
            ?assertEqual(Want, roadrunner_bin:ascii_lowercase(In))
        end
     || Len <- lists:seq(1, 30), Pos <- lists:seq(0, Len - 1), B <- lists:seq(0, 255)
    ].

ascii_lowercase_mixed_words_test() ->
    %% Several uppercase and edge bytes in the same 7-byte word, against a
    %% byte-at-a-time reference.
    rand:seed(exsss, {7, 7, 7}),
    Chars = <<"@AMZ[`amz{09-", 127, 128, 192, 218, 255>>,
    Lower = fun
        (C) when C >= $A, C =< $Z -> C + 32;
        (C) -> C
    end,
    [
        begin
            In = <<
                <<(binary:at(Chars, rand:uniform(byte_size(Chars)) - 1))>>
             || _ <- lists:seq(1, Len)
            >>,
            ?assertEqual(<<<<(Lower(C))>> || <<C>> <= In>>, roadrunner_bin:ascii_lowercase(In))
        end
     || Len <- lists:seq(1, 40), _ <- lists:seq(1, 50)
    ].

ascii_lowercase_only_uppercase_test() ->
    ?assertEqual(~"hello", roadrunner_bin:ascii_lowercase(~"HELLO")).

ascii_lowercase_punctuation_test() ->
    ?assertEqual(~"key=value", roadrunner_bin:ascii_lowercase(~"key=value")).

digits_to_integer_test() ->
    [
        ?assertEqual(Expected, roadrunner_bin:digits_to_integer(In))
     || {In, Expected} <- [
            {~"0", {ok, 0}},
            {~"007", {ok, 7}},
            {~"1048576", {ok, 1048576}},
            %% 2^63 - 1 is the largest length a peer may declare.
            {~"9223372036854775807", {ok, 9223372036854775807}},
            {~"0009223372036854775807", {ok, 9223372036854775807}},
            {~"9223372036854775808", error},
            {~"99999999999999999999", error},
            {~"123456789012345678901234", error},
            {~"", error},
            {~"+5", error},
            {~"-0", error},
            {~" 5", error},
            {~"5 ", error},
            {~"5x", error},
            {~"abc", error}
        ]
    ].

append_to_empty_buffer_returns_bytes_test() ->
    Bytes = ~"GET / HTTP/1.1\r\n",
    ?assert(erts_debug:same(Bytes, roadrunner_bin:append(<<>>, Bytes))).

append_to_partial_buffer_concatenates_test() ->
    ?assertEqual(~"GET / HTTP/1.1\r\n", roadrunner_bin:append(~"GET / ", ~"HTTP/1.1\r\n")).
