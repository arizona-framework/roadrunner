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

ascii_lowercase_only_uppercase_test() ->
    ?assertEqual(~"hello", roadrunner_bin:ascii_lowercase(~"HELLO")).

ascii_lowercase_punctuation_test() ->
    ?assertEqual(~"key=value", roadrunner_bin:ascii_lowercase(~"key=value")).
