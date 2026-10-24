-module(roadrunner_quic_token_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_token).
-define(KEY, <<3:256>>).
-define(IP, {192, 0, 2, 7}).
-define(IP6, {16#2001, 16#db8, 0, 0, 0, 0, 0, 7}).
-define(NOW, 1700000000).
-define(NONCE, <<5:96>>).

%% RFC 9000 §8.1.3: a token opens for the address it was sealed for, while
%% still good, naming its issue time and nonce so it can be spent once.
open_round_trips_test() ->
    Token = ?M:seal(?KEY, ?IP, ?NOW, ?NONCE),
    ?assertEqual({ok, {?NOW, ?NONCE}}, ?M:open(?KEY, Token, ?IP, ?NOW)),
    Token6 = ?M:seal(?KEY, ?IP6, ?NOW, ?NONCE),
    ?assertEqual({ok, {?NOW, ?NONCE}}, ?M:open(?KEY, Token6, ?IP6, ?NOW + 10)).

%% RFC 9000 §8.1.3: neither the address nor the issue time reads from the
%% token, so it links nothing for an observer.
token_hides_its_contents_test() ->
    Token = ?M:seal(?KEY, ?IP, ?NOW, ?NONCE),
    ?assertEqual(nomatch, binary:match(Token, <<192, 0, 2, 7>>)),
    ?assertEqual(nomatch, binary:match(Token, <<?NOW:64>>)).

%% RFC 9000 §8.1.4: a token for another address, under another key, or
%% altered in any byte opens to nothing, and so does junk.
open_refuses_other_tokens_test() ->
    Token = ?M:seal(?KEY, ?IP, ?NOW, ?NONCE),
    ?assertEqual(error, ?M:open(?KEY, Token, {192, 0, 2, 8}, ?NOW)),
    ?assertEqual(error, ?M:open(?KEY, Token, ?IP6, ?NOW)),
    ?assertEqual(error, ?M:open(<<4:256>>, Token, ?IP, ?NOW)),
    lists:foreach(
        fun(At) ->
            <<Before:At/binary, Byte, After/binary>> = Token,
            Altered = <<Before/binary, (Byte bxor 1), After/binary>>,
            ?assertEqual(error, ?M:open(?KEY, Altered, ?IP, ?NOW))
        end,
        lists:seq(0, byte_size(Token) - 1)
    ),
    ?assertEqual(error, ?M:open(?KEY, <<>>, ?IP, ?NOW)),
    <<Short:29/binary, _/binary>> = Token,
    ?assertEqual(error, ?M:open(?KEY, Short, ?IP, ?NOW)),
    ?assertEqual(error, ?M:open(?KEY, crypto:strong_rand_bytes(64), ?IP, ?NOW)).

%% RFC 9000 §8.1.3 SHOULD: a token expires an hour after it was issued, and
%% one issued more than a minute ahead of the clock is refused.
open_refuses_stale_tokens_test() ->
    Token = ?M:seal(?KEY, ?IP, ?NOW, ?NONCE),
    ?assertMatch({ok, _}, ?M:open(?KEY, Token, ?IP, ?NOW + 3600)),
    ?assertEqual(error, ?M:open(?KEY, Token, ?IP, ?NOW + 3601)),
    ?assertMatch({ok, _}, ?M:open(?KEY, Token, ?IP, ?NOW - 60)),
    ?assertEqual(error, ?M:open(?KEY, Token, ?IP, ?NOW - 61)),
    ?assertEqual(?NOW - 3600, ?M:oldest(?NOW)).

%% RFC 9000 §8.1.3 MUST: every token is unique; a new one opens now.
new_tokens_are_unique_test() ->
    One = ?M:new(?KEY, ?IP),
    ?assertNotEqual(One, ?M:new(?KEY, ?IP)),
    ?assertMatch({ok, _}, ?M:open(?KEY, One, ?IP, erlang:system_time(second))).
