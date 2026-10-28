-module(roadrunner_http_tests).
-include_lib("eunit/include/eunit.hrl").

http_date_now_format_matches_imf_fixdate_test() ->
    %% RFC 9110 §5.6.7: `Sun, 06 Nov 1994 08:49:37 GMT`. Validate the
    %% shape of the produced string — three-letter day, two-digit
    %% date, three-letter month, four-digit year, HH:MM:SS, GMT.
    Date = roadrunner_http:http_date_now(),
    %% Length is fixed: 29 bytes.
    ?assertEqual(29, byte_size(Date)),
    %% Last 3 chars are "GMT".
    ?assertEqual(~"GMT", binary:part(Date, 26, 3)),
    %% Day name is one of the seven.
    DayName = binary:part(Date, 0, 3),
    ?assert(
        lists:member(DayName, [~"Mon", ~"Tue", ~"Wed", ~"Thu", ~"Fri", ~"Sat", ~"Sun"])
    ),
    %% Month abbreviation is at offset 8..11.
    MonthName = binary:part(Date, 8, 3),
    ?assert(
        lists:member(MonthName, [
            ~"Jan",
            ~"Feb",
            ~"Mar",
            ~"Apr",
            ~"May",
            ~"Jun",
            ~"Jul",
            ~"Aug",
            ~"Sep",
            ~"Oct",
            ~"Nov",
            ~"Dec"
        ])
    ).

with_date_keeps_handler_date_test() ->
    %% A handler-set Date wins: `with_date/1` leaves the list untouched.
    Headers = [{~"date", ~"Sun, 06 Nov 1994 08:49:37 GMT"}],
    ?assertEqual(Headers, roadrunner_http:with_date(Headers)).

format_http_date_pads_single_digits_test() ->
    %% Pick a timestamp whose calendar fields all need two-digit padding
    %% (1970-01-01 00:00:00 UTC = Posix 0) so the `pad2/1` single-digit
    %% clause is exercised regardless of wall-clock at test run time.
    Date = roadrunner_http:format_http_date(0),
    ?assertEqual(~"Thu, 01 Jan 1970 00:00:00 GMT", Date).

format_http_date_matches_calendar_test() ->
    %% Leap days, century rules, the Jan/Feb end of the March-based year,
    %% and timestamps before the epoch.
    Posixes = [
        -1,
        -86401,
        -2208988800,
        951782400,
        951868800,
        1709164800,
        1735689599,
        4102444800,
        8078572799,
        8078572800,
        253402300799
    ],
    [?assertEqual(calendar_http_date(P), roadrunner_http:format_http_date(P)) || P <- Posixes].

format_http_date_covers_every_table_entry_test() ->
    %% Every day the tables cover (each weekday, day+month, and year
    %% entry) and every second of one day (each hour:minute and second
    %% entry), checked against `calendar`.
    Days = [Day * 86400 || Day <- lists:seq(0, (8078572800 div 86400) - 1)],
    Seconds = [86400 * 20000 + S || S <- lists:seq(0, 86399)],
    [
        ?assertEqual(calendar_http_date(P), roadrunner_http:format_http_date(P))
     || P <- Days ++ Seconds
    ].

calendar_http_date(Posix) ->
    {{Y, M, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Posix, second),
    Day = element(calendar:day_of_the_week(Y, M, D), {
        "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"
    }),
    Month = element(M, {
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    }),
    iolist_to_binary(
        io_lib:format("~s, ~2..0B ~s ~B ~2..0B:~2..0B:~2..0B GMT", [Day, D, Month, Y, H, Mi, S])
    ).

header_list_size_sums_fields_with_overhead_test() ->
    %% RFC 7541 §4.1: each field contributes name + value + 32 bytes.
    ?assertEqual(0, roadrunner_http:header_list_size([])),
    %% "a"(1) + "bb"(2) + 32 = 35; plus "ccc"(3) + ""(0) + 32 = 35 → 70.
    ?assertEqual(
        70,
        roadrunner_http:header_list_size([{~"a", ~"bb"}, {~"ccc", ~""}])
    ).

fits_header_list_size_test() ->
    %% RFC 9113 §6.5.2 / RFC 9114 §4.2.2: a field section fits the peer's
    %% limit while its size (name + value + 32 per field) is at most it.
    %% 7 + 3 + 32 = 42 bytes.
    Fields = [{~":status", ~"200"}],
    ?assert(roadrunner_http:fits_header_list_size(Fields, 42)),
    ?assertNot(roadrunner_http:fits_header_list_size(Fields, 41)),
    ?assert(roadrunner_http:fits_header_list_size([], 0)).

%% --- with_defaults/2 ---

with_defaults_empty_defaults_returns_headers_unchanged_test() ->
    Headers = [{~"a", ~"1"}],
    ?assertEqual(Headers, roadrunner_http:with_defaults(Headers, [])).

with_defaults_prepends_absent_defaults_in_order_test() ->
    %% Absent defaults are prepended, keeping their order, ahead of the
    %% existing headers.
    ?assertEqual(
        [{~"x", ~"1"}, {~"y", ~"2"}, {~"a", ~"0"}],
        roadrunner_http:with_defaults([{~"a", ~"0"}], [{~"x", ~"1"}, {~"y", ~"2"}])
    ).

with_defaults_existing_header_wins_test() ->
    %% A default whose name the headers already carry is skipped (the
    %% existing value wins); the others are still added.
    ?assertEqual(
        [{~"y", ~"2"}, {~"a", ~"keep"}],
        roadrunner_http:with_defaults([{~"a", ~"keep"}], [{~"a", ~"drop"}, {~"y", ~"2"}])
    ).

%% --- drop_unset/1 ---

drop_unset_keeps_only_set_values_in_order_test() ->
    ?assertEqual(
        [{~"a", ~"1"}, {~"c", ~""}],
        roadrunner_http:drop_unset([{~"a", ~"1"}, {~"b", false}, {~"c", ~""}])
    ).

drop_unset_all_false_returns_empty_test() ->
    ?assertEqual([], roadrunner_http:drop_unset([{~"a", false}, {~"b", false}])).

drop_unset_empty_returns_empty_test() ->
    ?assertEqual([], roadrunner_http:drop_unset([])).

check_header_safe_every_byte_at_every_position_test() ->
    %% Every byte value at every position of values that end in each way
    %% the scan can: a word pair then a tail (17), a pair then one word
    %% (21), two pairs then a tail (30), one word alone (7), a tail alone of
    %% each size (1 to 6), and a word or a pair then a 6-byte tail (13, 20).
    %% Covers each lane of a pair, a lone word and every tail size. Only
    %% CR, LF and NUL fail; tab and the other low control bytes pass.
    [
        begin
            Fill = binary:copy(~"a", Len),
            <<Pre:Pos/binary, _, Post/binary>> = Fill,
            Value = <<Pre/binary, B, Post/binary>>,
            case B of
                Unsafe when Unsafe =:= 0; Unsafe =:= $\n; Unsafe =:= $\r ->
                    ?assertError(
                        {header_injection, value, Value},
                        roadrunner_http:check_header_safe(Value, value)
                    );
                _ ->
                    ?assertEqual(ok, roadrunner_http:check_header_safe(Value, value))
            end
        end
     || Len <- [17, 21, 30, 7, 1, 2, 3, 4, 5, 6, 13, 20],
        Pos <- lists:seq(0, Len - 1),
        B <- lists:seq(0, 255)
    ].

check_header_safe_low_byte_then_cr_in_same_word_test() ->
    %% A tab sends the word to the exact check, which must still find the
    %% CR later in the same word.
    ?assertError(
        {header_injection, value, _}, roadrunner_http:check_header_safe(~"a\tbc\rdefghij", value)
    ).

check_header_safe_low_byte_then_cr_in_the_next_word_test() ->
    %% A tab in the first word of a pair sends both words to the exact
    %% check, which must find the CR in the second one.
    ?assertError(
        {header_injection, value, _},
        roadrunner_http:check_header_safe(~"a\tbcdefghi\rjklmn", value)
    ).

check_header_safe_low_byte_then_cr_in_the_tail_test() ->
    %% A tab flags the short tail, whose exact check must find the CR.
    ?assertError({header_injection, value, _}, roadrunner_http:check_header_safe(~"a\t\rb", value)).

%% --- request_pseudo_headers/1: :path and CONNECT ---

pseudo_path_follows_the_target_rules_test() ->
    %% RFC 9113 §8.3.1 / RFC 9114 §4.3.1: `:path` is an origin-form
    %% (`/`, then US-ASCII without CTL, SP or DEL), or `*` for OPTIONS.
    Pseudo = fun(Method, Path) ->
        roadrunner_http:request_pseudo_headers([
            {~":method", Method}, {~":scheme", ~"https"}, {~":path", Path}
        ])
    end,
    ?assertMatch({ok, ~"GET", ~"/a?b=1&c", _, []}, Pseudo(~"GET", ~"/a?b=1&c")),
    ?assertMatch({ok, ~"OPTIONS", ~"*", _, []}, Pseudo(~"OPTIONS", ~"*")),
    [
        ?assertEqual({error, bad_path}, Pseudo(Method, Path), {Method, Path})
     || {Method, Path} <- [
            {~"GET", ~"*"},
            {~"OPTIONS", ~"*x"},
            {~"GET", ~"abc"},
            {~"GET", ~"http://example.com/x"},
            {~"GET", <<"/caf", 16#C3, 16#A9>>},
            {~"GET", ~"/a b"},
            {~"GET", <<"/a", 1, "b">>},
            {~"GET", <<"/a", 16#7F>>},
            {~"GET", ~"/a#b"},
            {~"GET", ~"/a\\b"}
        ]
    ].

pseudo_connect_test() ->
    %% RFC 9113 §8.5 / RFC 9114 §4.4: a CONNECT carries `:method` and
    %% `:authority` only. Roadrunner opens no tunnels, so a well-formed one
    %% is not implemented; one with `:scheme` or `:path`, or without
    %% `:authority`, is malformed.
    Pseudo = fun(Fields) ->
        roadrunner_http:request_pseudo_headers([{~":method", ~"CONNECT"} | Fields])
    end,
    ?assertEqual({error, not_implemented}, Pseudo([{~":authority", ~"example.com:443"}])),
    [
        ?assertEqual({error, bad_connect}, Pseudo(Fields), Fields)
     || Fields <- [
            [],
            [{~":authority", ~"example.com:443"}, {~":path", ~"/"}],
            [{~":scheme", ~"https"}, {~":authority", ~"example.com:443"}],
            [{~":scheme", ~"https"}, {~":path", ~"/"}]
        ]
    ].

%% --- check_fields/1 ---

check_fields_name_every_byte_test() ->
    %% RFC 9110 §5.1 and RFC 9113 §8.2.1: a field name is a token
    %% without uppercase letters. Every byte value at the start, middle
    %% and end of a name.
    Allowed = fun(B) ->
        (B >= $a andalso B =< $z) orelse (B >= $0 andalso B =< $9) orelse
            lists:member(B, "!#$%&'*+-.^_`|~")
    end,
    [
        ?assertEqual(
            case Allowed(B) of
                true -> ok;
                false -> {error, bad_field_name}
            end,
            roadrunner_http:check_fields([{Name, ~"v"}]),
            Name
        )
     || B <- lists:seq(0, 255),
        %% A leading `:` marks a pseudo-header, whose name
        %% `request_pseudo_headers/1` judges, so it is left out here.
        Name <- [<<B, "ab">> || B =/= $:] ++ [<<"a", B, "b">>, <<"ab", B>>]
    ],
    ?assertEqual({error, bad_field_name}, roadrunner_http:check_fields([{~"", ~"v"}])).

check_fields_value_every_byte_test() ->
    %% A field value holds no NUL, CR or LF anywhere, and neither starts
    %% nor ends with SP or HTAB; every other byte, obs-text included, is
    %% left to the field's own grammar. Every byte value at the start, the
    %% middle and the end, in a value long enough to fill 7-byte words.
    [
        ?assertEqual(
            case {B, Pos} of
                {_, _} when B =:= 0; B =:= $\r; B =:= $\n -> {error, bad_field_value};
                {_, middle} -> ok;
                {_, _} when B =:= $\s; B =:= $\t -> {error, bad_field_value};
                _ -> ok
            end,
            roadrunner_http:check_fields([{~"x-a", Value}]),
            {B, Pos}
        )
     || B <- lists:seq(0, 255),
        {Pos, Value} <- [
            {first, <<B, "abcdefghijklmnop">>},
            {middle, <<"abcdefgh", B, "ijklmnop">>},
            {last, <<"abcdefghijklmnop", B>>}
        ]
    ],
    ?assertEqual(ok, roadrunner_http:check_fields([{~"x-a", ~""}])).

check_fields_pseudo_values_test() ->
    %% Pseudo-headers keep their leading colon, but their values follow
    %% the same value rule.
    ?assertEqual(ok, roadrunner_http:check_fields([{~":method", ~"GET"}, {~"a", ~"b"}])),
    ?assertEqual(
        {error, bad_field_value}, roadrunner_http:check_fields([{~":method", ~"GE\r\nT"}])
    ),
    ?assertEqual({error, bad_field_value}, roadrunner_http:check_fields([{~":path", ~"/ "}])).

%% --- check_request_authority/3 ---

authority_compare_normalizes_test() ->
    %% RFC 9113 §8.3.1 / RFC 3986 §6.2: `:authority` and `host` match when
    %% they name the same entity, whatever their case or default port.
    Check = fun(Authority, Host, Scheme) ->
        roadrunner_http:check_request_authority(Authority, [{~"host", Host}], Scheme)
    end,
    ?assertEqual(ok, Check(~"EXAMPLE.com", ~"example.com", https)),
    ?assertEqual(ok, Check(~"example.com:80", ~"Example.com", http)),
    ?assertEqual(ok, Check(~"example.com:", ~"example.com:443", https)),
    ?assertEqual(ok, Check(~"[::1]:443", ~"[::1]", https)),
    %% Another scheme's default port is a different entity,
    ?assertEqual({error, authority_mismatch}, Check(~"example.com:443", ~"example.com", http)),
    ?assertEqual({error, authority_mismatch}, Check(~"example.com:80", ~"example.com", https)),
    %% and so is a different host, including one shorter than the port.
    ?assertEqual({error, authority_mismatch}, Check(~"a", ~"b", https)),
    ?assertEqual({error, authority_mismatch}, Check(~"a.example", ~"b.example:443", https)).

authority_rejects_malformed_values_test() ->
    %% RFC 9113 §8.3.1 / RFC 9114 §4.3.1: the authority is a
    %% `uri-host [":" port]` with no userinfo, whether it arrives as
    %% `:authority`, as `host`, or as both.
    Check = fun(Authority, Regular) ->
        roadrunner_http:check_request_authority(Authority, Regular, https)
    end,
    [
        begin
            ?assertEqual({error, bad_authority}, Check(Bad, []), Bad),
            ?assertEqual({error, bad_authority}, Check(undefined, [{~"host", Bad}]), Bad),
            ?assertEqual({error, bad_authority}, Check(~"example.com", [{~"host", Bad}]), Bad),
            ?assertEqual({error, bad_authority}, Check(Bad, [{~"host", ~"example.com"}]), Bad)
        end
     || Bad <- [~"user@example.com", ~"example.com/path", ~"example.com:443, other.example"]
    ],
    ?assertEqual(ok, Check(~"example.com:443", [])),
    ?assertEqual(ok, Check(undefined, [{~"host", ~"[::1]:8443"}])).

%% --- valid_host/1 ---

expectation_test_() ->
    %% RFC 9110 §10.1.1: `100-continue` is the only expectation; members
    %% are comma-separated, case-insensitive, OWS-padded, and may be empty.
    [
        ?_assertEqual(Want, roadrunner_http:expectation(Value))
     || {Value, Want} <- [
            {~"100-continue", continue},
            {~"100-Continue", continue},
            {~" 100-continue\t", continue},
            {~"100-continue,", continue},
            {~", 100-continue , ", continue},
            {~"100-continue, 100-continue", continue},
            {~"", none},
            {~" , ,", none},
            {~"200-ok", unsupported},
            {~"100-continue, foo", unsupported},
            {~"foo, 100-continue", unsupported},
            {~"100-continue;x=1", unsupported},
            {~"100-continuee", unsupported}
        ]
    ].

valid_host_accepts_uri_host_and_port_test() ->
    %% RFC 9110 §7.2: `Host = uri-host [ ":" port ]`, with uri-host a
    %% reg-name (IPv4 included), an IPv6 or IPvFuture literal, and port
    %% `*DIGIT` (RFC 3986 §3.2.2, §3.2.3).
    [
        ?assert(roadrunner_http:valid_host(Host), Host)
     || Host <- [
            ~"example.com",
            ~"EXAMPLE.com:8080",
            ~"localhost:",
            ~"127.0.0.1:80",
            ~"a-b_c~d.e",
            ~"!$&'()*+,;=",
            ~"caf%C3%A9.example",
            ~"[::1]",
            ~"[2001:db8::7]:443",
            ~"[::ffff:192.0.2.1]",
            ~"[v1.fe80::a+en1]:80"
        ]
    ].

valid_host_every_byte_at_every_position_test() ->
    %% Every byte value at every position of reg-names that span two 7-byte
    %% words and a tail, with and without a port, against a regex of the
    %% RFC 3986 reg-name grammar. Covers each lane of the word scan,
    %% including the bytes its 0x20 case fold could disguise (controls that
    %% fold to `-`, `.` or a digit, and `@`, `[`, `` ` `` that fold to
    %% letters' neighbours).
    {ok, Re} = re:compile(
        ~"^(?:[A-Za-z0-9\\-._~!$&'()*+,;=]|%[0-9A-Fa-f]{2})+(?::[0-9]*)?$",
        %% Without it, `$` would also match before a final LF.
        [dollar_endonly]
    ),
    Oracle = fun(V) -> re:run(V, Re, [{capture, none}]) =:= match end,
    [
        begin
            <<Pre:Pos/binary, _, Post/binary>> = Base,
            V = <<Pre/binary, B, Post/binary, Port/binary>>,
            ?assertEqual(Oracle(V), roadrunner_http:valid_host(V), V)
        end
     || Base <- [~"Abc-def.GHI-jk9.z0", ~"0123456789.-ab-CD"],
        Port <- [~"", ~":8080"],
        Pos <- lists:seq(0, byte_size(Base) - 1),
        B <- lists:seq(0, 255)
    ].

valid_host_rejects_values_outside_the_grammar_test() ->
    %% Empty hosts (RFC 9110 §4.2.1: an http URI with an empty host is
    %% invalid), userinfo, paths, whitespace, a second host after a comma,
    %% non-digit ports, broken percent-escapes, unclosed or empty IP
    %% literals, and anything after the literal but a port.
    [
        ?assertNot(roadrunner_http:valid_host(Host), Host)
     || Host <- [
            ~"",
            ~":8080",
            ~"user@localhost:8080",
            ~"localhost:8080/path",
            ~"localhost:8080, other.example.com",
            ~"local host",
            ~"localhost:80a",
            ~"localhost:8080:80",
            ~"bad%2",
            ~"bad%zz",
            ~"[]",
            ~"[::1",
            ~"[::1]x",
            ~"[::1]:x",
            ~"[::1/64]",
            <<"caf", 16#C3, 16#A9>>,
            <<"a", 0>>
        ]
    ].
