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

%% =============================================================================
%% parse_headers/1
%% =============================================================================

%% --- happy path ---

block_empty_test() ->
    ?assertEqual({ok, [], ~""}, cactus_http1:parse_headers(~"\r\n")).

block_single_header_test() ->
    ?assertEqual(
        {ok, [{~"host", ~"x"}], ~""},
        cactus_http1:parse_headers(~"Host: x\r\n\r\n")
    ).

block_preserves_order_test() ->
    ?assertEqual(
        {ok, [{~"host", ~"a"}, {~"accept", ~"b"}, {~"x-trace", ~"c"}], ~""},
        cactus_http1:parse_headers(~"Host: a\r\nAccept: b\r\nX-Trace: c\r\n\r\n")
    ).

block_keeps_repeated_headers_test() ->
    %% Two Set-Cookie entries must both appear, in order.
    ?assertEqual(
        {ok, [{~"set-cookie", ~"a=1"}, {~"set-cookie", ~"b=2"}], ~""},
        cactus_http1:parse_headers(~"Set-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n")
    ).

block_with_body_test() ->
    ?assertEqual(
        {ok, [{~"host", ~"x"}], ~"hello"},
        cactus_http1:parse_headers(~"Host: x\r\n\r\nhello")
    ).

%% --- incremental ---

block_empty_input_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_headers(~"")).

block_partial_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_headers(~"Host: x\r\n")).

%% --- limits ---

block_too_long_rejected_test() ->
    %% 50 headers × ~210 bytes = ~10500 bytes; trips the 10240 block cap
    %% before the 100-header count cap.
    ValuePad = binary:copy(~"a", 200),
    HdrLine = fun(N) ->
        I = integer_to_binary(N),
        <<"X-H", I/binary, ": ", ValuePad/binary, "\r\n">>
    end,
    Lines = iolist_to_binary([HdrLine(N) || N <- lists:seq(1, 50)]),
    ?assertEqual(
        {error, header_block_too_long},
        cactus_http1:parse_headers(<<Lines/binary, "\r\n">>)
    ).

block_too_many_headers_rejected_test() ->
    %% 101 short headers stays well under the byte cap; trips the count cap.
    HdrLine = fun(N) ->
        I = integer_to_binary(N),
        <<"X-H", I/binary, ": v\r\n">>
    end,
    Lines = iolist_to_binary([HdrLine(N) || N <- lists:seq(1, 101)]),
    ?assertEqual(
        {error, too_many_headers},
        cactus_http1:parse_headers(<<Lines/binary, "\r\n">>)
    ).

block_at_count_limit_accepted_test() ->
    %% Boundary: exactly 100 headers must be accepted (limit is "at most 100").
    HdrLine = fun(N) ->
        I = integer_to_binary(N),
        <<"X-H", I/binary, ": v\r\n">>
    end,
    Lines = iolist_to_binary([HdrLine(N) || N <- lists:seq(1, 100)]),
    {ok, Headers, ~""} = cactus_http1:parse_headers(<<Lines/binary, "\r\n">>),
    ?assertEqual(100, length(Headers)).

%% --- request smuggling defenses ---

block_te_and_cl_rejected_test() ->
    ?assertEqual(
        {error, conflicting_framing},
        cactus_http1:parse_headers(~"Transfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n")
    ).

block_differing_cls_rejected_test() ->
    ?assertEqual(
        {error, conflicting_framing},
        cactus_http1:parse_headers(~"Content-Length: 5\r\nContent-Length: 7\r\n\r\n")
    ).

block_identical_cls_accepted_test() ->
    ?assertEqual(
        {ok, [{~"content-length", ~"5"}, {~"content-length", ~"5"}], ~""},
        cactus_http1:parse_headers(~"Content-Length: 5\r\nContent-Length: 5\r\n\r\n")
    ).

block_only_te_accepted_test() ->
    ?assertEqual(
        {ok, [{~"transfer-encoding", ~"chunked"}], ~""},
        cactus_http1:parse_headers(~"Transfer-Encoding: chunked\r\n\r\n")
    ).

block_only_cl_accepted_test() ->
    ?assertEqual(
        {ok, [{~"content-length", ~"42"}], ~""},
        cactus_http1:parse_headers(~"Content-Length: 42\r\n\r\n")
    ).

%% --- error propagation ---

block_propagates_bad_header_test() ->
    ?assertEqual(
        {error, bad_header},
        cactus_http1:parse_headers(~"Host: x\r\nbad header\r\n\r\n")
    ).

block_propagates_header_too_long_test() ->
    Big = <<(binary:copy(~"a", 8193))/binary, "\r\n">>,
    ?assertEqual(
        {error, header_too_long},
        cactus_http1:parse_headers(<<"Host: x\r\n", Big/binary>>)
    ).

%% =============================================================================
%% parse_request/1
%% =============================================================================

%% --- happy path ---

request_full_test() ->
    ?assertEqual(
        {ok,
            #{
                method => ~"GET",
                target => ~"/foo",
                version => {1, 1},
                headers => [{~"host", ~"x"}]
            },
            ~"body"},
        cactus_http1:parse_request(~"GET /foo HTTP/1.1\r\nHost: x\r\n\r\nbody")
    ).

request_no_headers_test() ->
    ?assertEqual(
        {ok,
            #{
                method => ~"GET",
                target => ~"/",
                version => {1, 1},
                headers => []
            },
            ~""},
        cactus_http1:parse_request(~"GET / HTTP/1.1\r\n\r\n")
    ).

%% --- incremental ---

request_returns_more_until_complete_test_() ->
    %% Every byte-prefix shorter than the full message must return {more, _}.
    Full = ~"GET / HTTP/1.1\r\nHost: x\r\n\r\n",
    Len = byte_size(Full),
    [
        ?_assertMatch(
            {more, _},
            cactus_http1:parse_request(binary:part(Full, 0, N))
        )
     || N <- lists:seq(0, Len - 1)
    ].

%% --- error propagation ---

request_request_line_error_propagates_test() ->
    ?assertEqual(
        {error, bad_request_line},
        cactus_http1:parse_request(~"BAD\r\n\r\n")
    ).

request_bad_version_propagates_test() ->
    ?assertEqual(
        {error, bad_version},
        cactus_http1:parse_request(~"GET / HTTP/2.0\r\n\r\n")
    ).

request_bad_header_propagates_test() ->
    ?assertEqual(
        {error, bad_header},
        cactus_http1:parse_request(~"GET / HTTP/1.1\r\nbad header\r\n\r\n")
    ).

request_smuggling_propagates_test() ->
    ?assertEqual(
        {error, conflicting_framing},
        cactus_http1:parse_request(
            ~"GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n"
        )
    ).

%% =============================================================================
%% parse_chunk/1
%% =============================================================================

%% --- happy path: regular chunks ---

chunk_single_test() ->
    ?assertEqual(
        {ok, ~"hello", ~""},
        cactus_http1:parse_chunk(~"5\r\nhello\r\n")
    ).

chunk_lowercase_hex_size_test() ->
    %% 0xa = 10
    ?assertEqual(
        {ok, ~"helloworld", ~""},
        cactus_http1:parse_chunk(~"a\r\nhelloworld\r\n")
    ).

chunk_uppercase_hex_size_test() ->
    ?assertEqual(
        {ok, ~"helloworld", ~""},
        cactus_http1:parse_chunk(~"A\r\nhelloworld\r\n")
    ).

chunk_multi_digit_size_test() ->
    %% 0x10 = 16
    Data = binary:copy(~"x", 16),
    ?assertEqual(
        {ok, Data, ~""},
        cactus_http1:parse_chunk(<<"10\r\n", Data/binary, "\r\n">>)
    ).

chunk_passes_rest_test() ->
    %% Multi-chunk stream — first call returns the first chunk + rest of buffer.
    ?assertEqual(
        {ok, ~"hello", ~"3\r\nfoo\r\n0\r\n\r\n"},
        cactus_http1:parse_chunk(~"5\r\nhello\r\n3\r\nfoo\r\n0\r\n\r\n")
    ).

chunk_extensions_ignored_test() ->
    ?assertEqual(
        {ok, ~"hello", ~""},
        cactus_http1:parse_chunk(~"5;ext=value\r\nhello\r\n")
    ).

chunk_size_with_bws_before_ext_test() ->
    %% BWS (bad whitespace) around `;` is RFC-permitted — strip it.
    ?assertEqual(
        {ok, ~"hello", ~""},
        cactus_http1:parse_chunk(~"5 ;ext=value\r\nhello\r\n")
    ).

%% --- last chunk ---

chunk_last_no_trailers_test() ->
    ?assertEqual(
        {ok, last, [], ~""},
        cactus_http1:parse_chunk(~"0\r\n\r\n")
    ).

chunk_last_with_trailers_test() ->
    ?assertEqual(
        {ok, last, [{~"x-foo", ~"bar"}], ~""},
        cactus_http1:parse_chunk(~"0\r\nX-Foo: bar\r\n\r\n")
    ).

chunk_last_passes_rest_after_trailers_test() ->
    ?assertEqual(
        {ok, last, [], ~"NEXT"},
        cactus_http1:parse_chunk(~"0\r\n\r\nNEXT")
    ).

%% --- incremental ---

chunk_empty_input_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_chunk(~"")).

chunk_partial_size_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_chunk(~"5")).

chunk_size_no_data_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_chunk(~"5\r\n")).

chunk_partial_data_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_chunk(~"5\r\nhel")).

chunk_data_no_trailing_crlf_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_chunk(~"5\r\nhello")).

chunk_partial_trailing_crlf_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_chunk(~"5\r\nhello\r")).

chunk_last_partial_trailers_returns_more_test() ->
    ?assertMatch({more, _}, cactus_http1:parse_chunk(~"0\r\nX-Foo: bar\r\n")).

%% --- bad chunks ---

chunk_bad_hex_rejected_test() ->
    ?assertEqual(
        {error, bad_chunk_size},
        cactus_http1:parse_chunk(~"xyz\r\nhello\r\n")
    ).

chunk_empty_size_rejected_test() ->
    ?assertEqual(
        {error, bad_chunk_size},
        cactus_http1:parse_chunk(~"\r\nhello\r\n")
    ).

chunk_size_with_only_ext_rejected_test() ->
    %% Empty size before `;` is malformed.
    ?assertEqual(
        {error, bad_chunk_size},
        cactus_http1:parse_chunk(~";ext=value\r\nhello\r\n")
    ).

chunk_oversized_header_no_crlf_rejected_test() ->
    Big = binary:copy(~"a", 8200),
    ?assertEqual({error, bad_chunk}, cactus_http1:parse_chunk(Big)).

chunk_oversized_header_with_crlf_rejected_test() ->
    Big = <<(binary:copy(~"a", 8193))/binary, "\r\n">>,
    ?assertEqual({error, bad_chunk}, cactus_http1:parse_chunk(Big)).

chunk_missing_crlf_after_data_rejected_test() ->
    %% 5 bytes data + 2 bytes that aren't \r\n; full buffer present.
    ?assertEqual(
        {error, bad_chunk},
        cactus_http1:parse_chunk(~"5\r\nhelloXX\r\n")
    ).

chunk_last_bad_trailer_propagates_test() ->
    ?assertEqual(
        {error, bad_header},
        cactus_http1:parse_chunk(~"0\r\nbad trailer\r\n\r\n")
    ).

%% =============================================================================
%% response/3
%% =============================================================================

response_minimal_test() ->
    ?assertEqual(
        ~"HTTP/1.1 200 OK\r\n\r\n",
        iolist_to_binary(cactus_http1:response(200, [], ~""))
    ).

response_with_body_test() ->
    ?assertEqual(
        ~"HTTP/1.1 200 OK\r\n\r\nhello",
        iolist_to_binary(cactus_http1:response(200, [], ~"hello"))
    ).

response_with_single_header_test() ->
    ?assertEqual(
        ~"HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n\r\nhi",
        iolist_to_binary(
            cactus_http1:response(200, [{~"content-type", ~"text/plain"}], ~"hi")
        )
    ).

response_preserves_header_order_test() ->
    %% Headers must appear in the order the caller supplied them — important
    %% for repeated headers like Set-Cookie.
    ?assertEqual(
        ~"HTTP/1.1 200 OK\r\nset-cookie: a=1\r\nset-cookie: b=2\r\nx-trace: 7\r\n\r\n",
        iolist_to_binary(
            cactus_http1:response(
                200,
                [{~"set-cookie", ~"a=1"}, {~"set-cookie", ~"b=2"}, {~"x-trace", ~"7"}],
                ~""
            )
        )
    ).

response_accepts_iolist_body_test() ->
    %% iodata input flows through without forcing a flatten.
    Result = cactus_http1:response(200, [], [~"hello", ~" ", [~"wo", ~"rld"]]),
    ?assertEqual(
        ~"HTTP/1.1 200 OK\r\n\r\nhello world",
        iolist_to_binary(Result)
    ).

response_status_reason_phrases_test_() ->
    Cases = [
        {200, ~"OK"},
        {201, ~"Created"},
        {204, ~"No Content"},
        {301, ~"Moved Permanently"},
        {302, ~"Found"},
        {304, ~"Not Modified"},
        {400, ~"Bad Request"},
        {401, ~"Unauthorized"},
        {403, ~"Forbidden"},
        {404, ~"Not Found"},
        {500, ~"Internal Server Error"},
        {503, ~"Service Unavailable"}
    ],
    [
        ?_assertEqual(
            <<"HTTP/1.1 ", (integer_to_binary(S))/binary, " ", R/binary, "\r\n\r\n">>,
            iolist_to_binary(cactus_http1:response(S, [], ~""))
        )
     || {S, R} <- Cases
    ].

response_unknown_status_has_empty_reason_test() ->
    %% RFC 9112 §4.1 makes reason-phrase optional; we emit an empty one.
    ?assertEqual(
        ~"HTTP/1.1 599 \r\n\r\n",
        iolist_to_binary(cactus_http1:response(599, [], ~""))
    ).

%% --- header injection / response splitting defenses ---

response_rejects_cr_in_header_value_test() ->
    %% Classic HTTP response splitting: CRLF in a header value would
    %% let the attacker inject arbitrary headers (or a whole second
    %% response) into the wire output. Must crash before it hits the
    %% socket.
    ?assertError(
        {header_injection, value, _},
        cactus_http1:response(
            302, [{~"location", ~"http://x.com\r\nX-Inject: evil"}], ~""
        )
    ).

response_rejects_lf_in_header_value_test() ->
    ?assertError(
        {header_injection, value, _},
        cactus_http1:response(200, [{~"x-foo", ~"line1\nline2"}], ~"")
    ).

response_rejects_nul_in_header_value_test() ->
    ?assertError(
        {header_injection, value, _},
        cactus_http1:response(200, [{~"x-foo", <<"a", 0, "b">>}], ~"")
    ).

response_rejects_cr_in_header_name_test() ->
    %% A CR in the NAME would also enable injection (the second line
    %% becomes a fresh header).
    ?assertError(
        {header_injection, name, _},
        cactus_http1:response(200, [{~"x-name\r\nInjected", ~"v"}], ~"")
    ).

response_rejects_lf_in_header_name_test() ->
    ?assertError(
        {header_injection, name, _},
        cactus_http1:response(200, [{~"x-name\nbad", ~"v"}], ~"")
    ).

response_rejects_nul_in_header_name_test() ->
    ?assertError(
        {header_injection, name, _},
        cactus_http1:response(200, [{<<"x-name", 0, "bad">>, ~"v"}], ~"")
    ).
