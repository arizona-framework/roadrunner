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

%% Trigger bytes that mean `decode/1` actually has to do work.
%% Pre-compiled at module load (see `init_patterns/0`).
-define(QS_TRIGGERS_KEY, {?MODULE, qs_triggers_cp}).
-define(AMP_KEY, {?MODULE, amp_cp}).
-define(EQ_KEY, {?MODULE, eq_cp}).
-define(PLUS_KEY, {?MODULE, plus_cp}).
-define(PCT20_KEY, {?MODULE, pct20_cp}).

-doc """
Parse a query string into an ordered list of `{Key, Value}` pairs.

`Value` is `true` for bare flags, otherwise a binary (possibly empty).
""".
-spec parse(binary()) -> [{binary(), binary() | true}].
parse(<<>>) ->
    [];
parse(Bin) when is_binary(Bin) ->
    EqCp = persistent_term:get(?EQ_KEY),
    TriggersCp = persistent_term:get(?QS_TRIGGERS_KEY),
    PlusCp = persistent_term:get(?PLUS_KEY),
    [
        parse_pair(P, EqCp, TriggersCp, PlusCp)
     || P <- binary:split(Bin, persistent_term:get(?AMP_KEY), [global]), P =/= <<>>
    ].

-spec parse_pair(binary(), binary:cp(), binary:cp(), binary:cp()) ->
    {binary(), binary() | true}.
parse_pair(Pair, EqCp, TriggersCp, PlusCp) ->
    case binary:split(Pair, EqCp) of
        [Key] -> {decode(Key, TriggersCp, PlusCp), true};
        [Key, Value] -> {decode(Key, TriggersCp, PlusCp), decode(Value, TriggersCp, PlusCp)}
    end.

-spec decode(binary(), binary:cp(), binary:cp()) -> binary().
decode(Bin, TriggersCp, PlusCp) ->
    %% Fast path: when neither `+` nor `%` is present, the body
    %% bytes ARE the decoded bytes — return as-is. Skips both
    %% `binary:replace` and `roadrunner_uri:percent_decode/1`,
    %% which is the dominant cost on form fields with safe ASCII
    %% (numeric IDs, alpha-only keys, base64 etc.). Single-pass
    %% match against a precompiled pattern.
    case binary:match(Bin, TriggersCp) of
        nomatch ->
            Bin;
        _ ->
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

%% `-on_load` callback. Compiles the `+`/`%` trigger pattern once
%% at module load and stashes it in `persistent_term`. The
%% `decode/1` fast-path scans with a precompiled binary pattern
%% instead of building one per call. Conventional shape across the
%% codebase (see `roadrunner_compress`, `roadrunner_http1`,
%% `roadrunner_ws`).
-spec init_patterns() -> ok.
init_patterns() ->
    persistent_term:put(?QS_TRIGGERS_KEY, binary:compile_pattern([~"+", ~"%"])),
    persistent_term:put(?AMP_KEY, binary:compile_pattern(~"&")),
    persistent_term:put(?EQ_KEY, binary:compile_pattern(~"=")),
    persistent_term:put(?PLUS_KEY, binary:compile_pattern(~"+")),
    persistent_term:put(?PCT20_KEY, binary:compile_pattern(~"%20")),
    ok.
