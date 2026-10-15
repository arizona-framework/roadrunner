-module(roadrunner_qs).
-moduledoc """
`application/x-www-form-urlencoded` query string codec.

Pairs are separated by `&`; key and value within each pair are
separated by `=`. `+` decodes to space (legacy form-encoding rule),
followed by RFC 3986 percent-decoding via `roadrunner_uri`. Bare keys
with no `=` are flags — their value is the atom `true`.

Lenient on malformed input (cowboy parity): empty pair entries
(`&&`, leading or trailing `&`) are skipped, and percent sequences
that fail to decode pass through as raw bytes.
""".

-on_load(init_patterns/0).

-export([parse/1, encode/1]).

%% Pre-compiled at module load (see `init_patterns/0`).
-define(AMP_KEY, {?MODULE, amp_cp}).
-define(EQ_KEY, {?MODULE, eq_cp}).
-define(PLUS_KEY, {?MODULE, plus_cp}).
-define(PCT20_KEY, {?MODULE, pct20_cp}).

-include("roadrunner_swar.hrl").

-doc """
Parse a query string into an ordered list of `{Key, Value}` pairs.

`Value` is `true` for bare flags, otherwise a binary (possibly empty).
""".
-spec parse(binary()) -> [{binary(), binary() | true}].
parse(<<>>) ->
    [];
parse(Bin) when is_binary(Bin) ->
    EqCp = persistent_term:get(?EQ_KEY),
    Pairs = binary:split(Bin, persistent_term:get(?AMP_KEY), [global]),
    %% One scan of the whole string for `+`/`%`: when there is neither,
    %% the usual `?id=123&limit=50`, no key or value needs decoding, so
    %% the pairs skip `decode/2` and its per-key and per-value scans.
    case has_trigger(Bin) of
        false ->
            [split_pair(P, EqCp) || P <- Pairs, P =/= <<>>];
        true ->
            PlusCp = persistent_term:get(?PLUS_KEY),
            [parse_pair(P, EqCp, PlusCp) || P <- Pairs, P =/= <<>>]
    end.

-spec split_pair(binary(), binary:cp()) -> {binary(), binary() | true}.
split_pair(Pair, EqCp) ->
    case binary:split(Pair, EqCp) of
        [Key] -> {Key, true};
        [Key, Value] -> {Key, Value}
    end.

-spec parse_pair(binary(), binary:cp(), binary:cp()) ->
    {binary(), binary() | true}.
parse_pair(Pair, EqCp, PlusCp) ->
    case binary:split(Pair, EqCp) of
        [Key] -> {decode(Key, PlusCp), true};
        [Key, Value] -> {decode(Key, PlusCp), decode(Value, PlusCp)}
    end.

-spec decode(binary(), binary:cp()) -> binary().
decode(Bin, PlusCp) ->
    %% Fast path: when neither `+` nor `%` is present, the body
    %% bytes ARE the decoded bytes — return as-is. Skips both
    %% `binary:replace` and `roadrunner_uri:percent_decode/1`,
    %% which is the dominant cost on form fields with safe ASCII
    %% (numeric IDs, alpha-only keys, base64 etc.).
    case has_trigger(Bin) of
        false ->
            Bin;
        true ->
            Spaced = binary:replace(Bin, PlusCp, ~" ", [global]),
            case roadrunner_uri:percent_decode(Spaced) of
                {ok, Decoded} -> Decoded;
                {error, badarg} -> Spaced
            end
    end.

-doc """
Encode a list of `{Key, Value}` pairs as a query string.

`Value` may be `true` (bare flag, no `=`) or a binary. Spaces are
encoded as `+` (form-encoding convention); other non-unreserved bytes
become `%HH` triples — including a literal `+`, which becomes `%2B`
so it round-trips through `parse/1`.
""".
-spec encode([{binary(), binary() | true}]) -> binary().
encode(Pairs) when is_list(Pairs) ->
    Pct20Cp = persistent_term:get(?PCT20_KEY),
    iolist_to_binary(lists:join(~"&", [encode_pair(P, Pct20Cp) || P <- Pairs])).

-spec encode_pair({binary(), binary() | true}, binary:cp()) -> iodata().
encode_pair({Key, true}, Pct20Cp) ->
    encode_component(Key, Pct20Cp);
encode_pair({Key, Value}, Pct20Cp) when is_binary(Value) ->
    [encode_component(Key, Pct20Cp), $=, encode_component(Value, Pct20Cp)].

-spec encode_component(binary(), binary:cp()) -> binary().
encode_component(Bin, Pct20Cp) ->
    %% Use the URI-style percent encoder, then collapse %20 to '+' so the
    %% output is form-encoded. Other percent triples are unaffected because
    %% only literal 0x20 ever produces "%20".
    Encoded = roadrunner_uri:percent_encode(Bin),
    binary:replace(Encoded, Pct20Cp, ~"+", [global]).

%% `true` when `Bin` holds a `+` or `%`. SWAR, 7 bytes per step (see
%% `roadrunner_swar.hrl`). On short query strings this beats
%% `binary:match/2` with a compiled `+`/`%` pattern, whose fixed call cost
%% dominated.
%% Two words per step, then at most one more word, then the last 0 to 6
%% bytes as a single integer with the lane constants cut to its size, so
%% no byte is tested on its own.
-spec has_trigger(binary()) -> boolean().
has_trigger(<<X:56, Y:56, Rest/binary>>) ->
    case
        ?SWAR_HIGH(
            ?SWAR_ZERO(X bxor ?SWAR_BYTES($+)) bor ?SWAR_ZERO(X bxor ?SWAR_BYTES($%)) bor
                ?SWAR_ZERO(Y bxor ?SWAR_BYTES($+)) bor ?SWAR_ZERO(Y bxor ?SWAR_BYTES($%))
        )
    of
        0 -> has_trigger(Rest);
        _ -> true
    end;
has_trigger(<<X:56, Rest/binary>>) ->
    case ?SWAR_HIGH(?SWAR_ZERO(X bxor ?SWAR_BYTES($+)) bor ?SWAR_ZERO(X bxor ?SWAR_BYTES($%))) of
        0 -> has_trigger_tail(Rest);
        _ -> true
    end;
has_trigger(Tail) ->
    has_trigger_tail(Tail).

%% The last 0 to 6 bytes: `?SWAR_ZERO/1` of the `+` and `%` lanes over N
%% lanes, one clause per size so the constants stay literal.
-spec has_trigger_tail(binary()) -> boolean().
has_trigger_tail(<<X:48>>) ->
    trigger_lanes(
        X bxor 16#2B2B2B2B2B2B,
        X bxor 16#252525252525,
        16#10101010101,
        16#FFFFFFFFFFFF,
        16#808080808080
    );
has_trigger_tail(<<X:40>>) ->
    trigger_lanes(
        X bxor 16#2B2B2B2B2B, X bxor 16#2525252525, 16#101010101, 16#FFFFFFFFFF, 16#8080808080
    );
has_trigger_tail(<<X:32>>) ->
    trigger_lanes(X bxor 16#2B2B2B2B, X bxor 16#25252525, 16#1010101, 16#FFFFFFFF, 16#80808080);
has_trigger_tail(<<X:24>>) ->
    trigger_lanes(X bxor 16#2B2B2B, X bxor 16#252525, 16#10101, 16#FFFFFF, 16#808080);
has_trigger_tail(<<X:16>>) ->
    trigger_lanes(X bxor 16#2B2B, X bxor 16#2525, 16#101, 16#FFFF, 16#8080);
has_trigger_tail(<<X:8>>) ->
    trigger_lanes(X bxor 16#2B, X bxor 16#25, 16#1, 16#FF, 16#80);
has_trigger_tail(<<>>) ->
    false.

-spec trigger_lanes(integer(), integer(), pos_integer(), pos_integer(), pos_integer()) ->
    boolean().
trigger_lanes(Plus, Pct, Ones, All, High) ->
    ((Plus - Ones) band (Plus bxor All) bor (Pct - Ones) band (Pct bxor All)) band High =/= 0.

%% `-on_load` callback. Compiles the `&`, `=`, `+` and `%20` patterns
%% `parse/1` and `encode/1` split and replace on once at module load and
%% stashes them in `persistent_term`, instead of building one per call.
%% Conventional shape across the codebase (see `roadrunner_compress`,
%% `roadrunner_http1`, `roadrunner_ws`).
-spec init_patterns() -> ok.
init_patterns() ->
    persistent_term:put(?AMP_KEY, binary:compile_pattern(~"&")),
    persistent_term:put(?EQ_KEY, binary:compile_pattern(~"=")),
    persistent_term:put(?PLUS_KEY, binary:compile_pattern(~"+")),
    persistent_term:put(?PCT20_KEY, binary:compile_pattern(~"%20")),
    ok.
