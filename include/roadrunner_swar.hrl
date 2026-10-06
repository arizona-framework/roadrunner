%% SWAR ("SIMD within a register") byte scans: test 7 bytes of a binary
%% at once by reading them as one integer (`<<X:56, Rest/binary>>`) and
%% checking every byte lane with a few integer operations. 7 rather than
%% 8 bytes because 56 bits stays a small integer on a 64-bit BEAM, where
%% a 64-bit word would be a heap bignum.
%%
%% Each predicate below sets the high bit (0x80) of a lane whose byte
%% matches; `?SWAR_HIGH/1` keeps only those bits, so a scan tests
%% `?SWAR_HIGH(...) =:= 0` for "no byte in this word matches". A borrow
%% can also flag a lane above a real match, so a flagged word only means
%% "some byte here matches": callers check that word byte by byte. Bytes
%% >= 0x80 never flag, since the `bnot X` term (`X bxor ?SWAR_BYTES(255)`)
%% clears their lanes.

%% `B` repeated in each byte of a 7-byte word.
-define(SWAR_BYTES(B), (16#01010101010101 * (B))).

%% Lanes holding a byte below `N` (`N` =< 0x80).
-define(SWAR_BELOW(X, N), (((X) - ?SWAR_BYTES(N)) band ((X) bxor ?SWAR_BYTES(255)))).

%% Lanes holding a zero byte. To find a byte equal to `B`, bind
%% `Y = X bxor ?SWAR_BYTES(B)` once and pass `Y`.
-define(SWAR_ZERO(Y), (((Y) - ?SWAR_BYTES(1)) band ((Y) bxor ?SWAR_BYTES(255)))).

%% Keep only the lanes' high bits: zero when no lane matched.
-define(SWAR_HIGH(M), ((M) band ?SWAR_BYTES(128))).
