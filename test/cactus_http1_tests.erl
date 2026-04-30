-module(cactus_http1_tests).

-include_lib("eunit/include/eunit.hrl").

%% --- happy path ---

parses_minimal_get_test() ->
    ?assertEqual(
        {ok, ~"GET", ~"/", {1, 1}, ~""},
        cactus_http1:parse_request_line(~"GET / HTTP/1.1\r\n")
    ).

parses_post_with_target_and_leftover_test() ->
    ?assertEqual(
        {ok, ~"POST", ~"/api/users", {1, 0}, ~"leftover"},
        cactus_http1:parse_request_line(~"POST /api/users HTTP/1.0\r\nleftover")
    ).

stops_at_first_crlf_test() ->
    %% Property the next parser (parse_header/1) relies on: anything after
    %% the first CRLF must come back unchanged in Rest.
    ?assertEqual(
        {ok, ~"GET", ~"/", {1, 1}, ~"Host: x\r\nAccept: */*\r\n\r\n"},
        cactus_http1:parse_request_line(~"GET / HTTP/1.1\r\nHost: x\r\nAccept: */*\r\n\r\n")
    ).

at_size_limit_accepted_test() ->
    %% Boundary: 8192-byte request line (target padded to fill it) must pass.
    Pad = binary:copy(~"a", 8192 - byte_size(~"GET / HTTP/1.1")),
    Bin = <<"GET /", Pad/binary, " HTTP/1.1\r\n">>,
    ?assertMatch({ok, ~"GET", _, {1, 1}, ~""}, cactus_http1:parse_request_line(Bin)).

parses_common_methods_test_() ->
    Methods = [~"GET", ~"POST", ~"PUT", ~"DELETE", ~"PATCH", ~"HEAD", ~"OPTIONS"],
    [
        ?_assertEqual(
            {ok, M, ~"/", {1, 1}, ~""},
            cactus_http1:parse_request_line(<<M/binary, " / HTTP/1.1\r\n">>)
        )
     || M <- Methods
    ].

parses_custom_uppercase_method_test() ->
    %% Non-fast-path method (any uppercase ASCII letters) must still parse.
    ?assertEqual(
        {ok, ~"BREW", ~"/coffee", {1, 1}, ~""},
        cactus_http1:parse_request_line(~"BREW /coffee HTTP/1.1\r\n")
    ).

%% --- incremental / partial ---

empty_input_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_request_line(~"")).

partial_method_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_request_line(~"GET")).

partial_version_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_request_line(~"GET / HTT")).

no_crlf_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_request_line(~"GET / HTTP/1.1")).

half_crlf_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_request_line(~"GET / HTTP/1.1\r")).

%% --- bad version ---

http_2_rejected_test() ->
    ?assertEqual(
        {error, bad_version},
        cactus_http1:parse_request_line(~"GET / HTTP/2.0\r\n")
    ).

http_0_9_rejected_test() ->
    ?assertEqual(
        {error, bad_version},
        cactus_http1:parse_request_line(~"GET / HTTP/0.9\r\n")
    ).

ftp_rejected_test() ->
    ?assertEqual(
        {error, bad_version},
        cactus_http1:parse_request_line(~"GET / FTP/1.1\r\n")
    ).

http_11_no_dot_rejected_test() ->
    ?assertEqual(
        {error, bad_version},
        cactus_http1:parse_request_line(~"GET / HTTP/11\r\n")
    ).

%% --- bad request line ---

empty_method_rejected_test() ->
    ?assertEqual(
        {error, bad_request_line},
        cactus_http1:parse_request_line(~" / HTTP/1.1\r\n")
    ).

lowercase_method_rejected_test() ->
    ?assertEqual(
        {error, bad_request_line},
        cactus_http1:parse_request_line(~"get / HTTP/1.1\r\n")
    ).

missing_target_rejected_test() ->
    ?assertEqual(
        {error, bad_request_line},
        cactus_http1:parse_request_line(~"GET HTTP/1.1\r\n")
    ).

empty_target_rejected_test() ->
    ?assertEqual(
        {error, bad_request_line},
        cactus_http1:parse_request_line(~"GET  HTTP/1.1\r\n")
    ).

double_space_rejected_test() ->
    ?assertEqual(
        {error, bad_request_line},
        cactus_http1:parse_request_line(~"GET  / HTTP/1.1\r\n")
    ).

bare_lf_at_start_rejected_test() ->
    ?assertEqual(
        {error, bad_request_line},
        cactus_http1:parse_request_line(~"\n")
    ).

bare_lf_at_end_rejected_test() ->
    ?assertEqual(
        {error, bad_request_line},
        cactus_http1:parse_request_line(~"GET / HTTP/1.1\n")
    ).

control_char_in_target_rejected_test() ->
    ?assertEqual(
        {error, bad_request_line},
        cactus_http1:parse_request_line(~"GET /\x{00} HTTP/1.1\r\n")
    ).

%% --- limits ---

oversized_no_crlf_rejected_test() ->
    Big = <<"GET /", (binary:copy(~"a", 8200))/binary>>,
    ?assertEqual(
        {error, request_line_too_long},
        cactus_http1:parse_request_line(Big)
    ).

oversized_with_crlf_rejected_test() ->
    Line = binary:copy(~"a", 8193),
    ?assertEqual(
        {error, request_line_too_long},
        cactus_http1:parse_request_line(<<Line/binary, "\r\n">>)
    ).

%% =============================================================================
%% parse_header/1
%% =============================================================================

%% --- happy path ---

header_parses_simple_test() ->
    ?assertEqual(
        {ok, ~"host", ~"example.com", ~""},
        cactus_http1:parse_header(~"Host: example.com\r\n")
    ).

header_lowercases_name_test() ->
    ?assertEqual(
        {ok, ~"content-type", ~"text/html", ~""},
        cactus_http1:parse_header(~"Content-Type: text/html\r\n")
    ).

header_allows_digit_in_name_test() ->
    ?assertEqual(
        {ok, ~"x1-y2", ~"foo", ~""},
        cactus_http1:parse_header(~"X1-Y2: foo\r\n")
    ).

header_trims_ows_test() ->
    %% SP and HTAB on both sides are trimmed; internal whitespace preserved.
    ?assertEqual(
        {ok, ~"x-y", ~"a b", ~""},
        cactus_http1:parse_header(~"X-Y: \t a b \t\r\n")
    ).

header_allows_htab_in_value_test() ->
    ?assertEqual(
        {ok, ~"x-foo", ~"a\tb", ~""},
        cactus_http1:parse_header(~"X-Foo: a\tb\r\n")
    ).

header_accepts_non_ascii_value_test() ->
    %% Bytes >= 0x80 are accepted in values (lenient — same as cowboy).
    ?assertEqual(
        {ok, ~"x-y", ~"café", ~""},
        cactus_http1:parse_header(~"X-Y: café\r\n")
    ).

header_empty_value_accepted_test() ->
    ?assertEqual(
        {ok, ~"x-empty", ~"", ~""},
        cactus_http1:parse_header(~"X-Empty:\r\n")
    ).

header_all_ows_value_trims_to_empty_test() ->
    ?assertEqual(
        {ok, ~"x-y", ~"", ~""},
        cactus_http1:parse_header(~"X-Y:    \r\n")
    ).

header_passes_rest_test() ->
    ?assertEqual(
        {ok, ~"host", ~"x", ~"Accept: y\r\n"},
        cactus_http1:parse_header(~"Host: x\r\nAccept: y\r\n")
    ).

%% --- end of headers ---

header_end_of_headers_test() ->
    ?assertEqual(
        {end_of_headers, ~""},
        cactus_http1:parse_header(~"\r\n")
    ).

header_end_of_headers_with_body_test() ->
    ?assertEqual(
        {end_of_headers, ~"hello body"},
        cactus_http1:parse_header(~"\r\nhello body")
    ).

%% --- incremental ---

header_empty_input_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_header(~"")).

header_partial_name_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_header(~"Host")).

header_partial_after_colon_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_header(~"Host:")).

header_partial_value_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_header(~"Host: example.com")).

header_partial_cr_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_header(~"Host: example.com\r")).

%% --- bare LF ---

header_bare_lf_at_start_rejected_test() ->
    ?assertEqual({error, bad_header}, cactus_http1:parse_header(~"\n")).

header_bare_lf_mid_buffer_rejected_test() ->
    ?assertEqual({error, bad_header}, cactus_http1:parse_header(~"Host\nfoo")).

%% --- bad header ---

header_empty_name_rejected_test() ->
    ?assertEqual({error, bad_header}, cactus_http1:parse_header(~": value\r\n")).

header_name_with_space_rejected_test() ->
    ?assertEqual({error, bad_header}, cactus_http1:parse_header(~"Ho st: x\r\n")).

header_name_with_control_char_rejected_test() ->
    ?assertEqual({error, bad_header}, cactus_http1:parse_header(~"Ho\x{01}st: x\r\n")).

header_missing_colon_rejected_test() ->
    ?assertEqual({error, bad_header}, cactus_http1:parse_header(~"Host example.com\r\n")).

%% --- header injection ---

header_cr_in_value_rejected_test() ->
    ?assertEqual({error, bad_header}, cactus_http1:parse_header(~"X-Inj: foo\rbar\r\n")).

header_nul_in_value_rejected_test() ->
    ?assertEqual({error, bad_header}, cactus_http1:parse_header(~"X-Inj: foo\x{00}bar\r\n")).

%% --- obs-fold ---

header_obs_fold_space_rejected_test() ->
    ?assertEqual({error, bad_header}, cactus_http1:parse_header(~"  continuation\r\n")).

header_obs_fold_tab_rejected_test() ->
    ?assertEqual({error, bad_header}, cactus_http1:parse_header(~"\tcontinuation\r\n")).

%% --- limits ---

header_oversized_no_crlf_rejected_test() ->
    Big = <<"X: ", (binary:copy(~"a", 8200))/binary>>,
    ?assertEqual({error, header_too_long}, cactus_http1:parse_header(Big)).

header_oversized_with_crlf_rejected_test() ->
    Big = <<(binary:copy(~"a", 8193))/binary, "\r\n">>,
    ?assertEqual({error, header_too_long}, cactus_http1:parse_header(Big)).
