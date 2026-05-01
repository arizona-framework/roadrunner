-module(cactus_multipart_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% boundary/1 — pulling the parameter out of Content-Type.
%% =============================================================================

boundary_simple_test() ->
    ?assertEqual(
        {ok, ~"abc123"},
        cactus_multipart:boundary(~"multipart/form-data; boundary=abc123")
    ).

boundary_no_space_test() ->
    ?assertEqual(
        {ok, ~"abc123"},
        cactus_multipart:boundary(~"multipart/form-data;boundary=abc123")
    ).

boundary_quoted_test() ->
    %% RFC 2046 allows quoted boundaries containing characters that
    %% would otherwise need escaping.
    ?assertEqual(
        {ok, ~"abc 123"},
        cactus_multipart:boundary(~"multipart/form-data; boundary=\"abc 123\"")
    ).

boundary_with_other_params_after_test() ->
    ?assertEqual(
        {ok, ~"xyz"},
        cactus_multipart:boundary(~"multipart/form-data; boundary=xyz; charset=utf-8")
    ).

boundary_with_other_params_before_test() ->
    ?assertEqual(
        {ok, ~"xyz"},
        cactus_multipart:boundary(~"multipart/form-data; charset=utf-8; boundary=xyz")
    ).

boundary_missing_test() ->
    ?assertEqual(
        {error, no_boundary},
        cactus_multipart:boundary(~"multipart/form-data")
    ).

%% =============================================================================
%% params/1 — generic header-parameter parser.
%% =============================================================================

params_form_data_with_name_and_filename_test() ->
    ?assertEqual(
        #{~"name" => ~"a", ~"filename" => ~"f.txt"},
        cactus_multipart:params(
            ~"form-data; name=\"a\"; filename=\"f.txt\""
        )
    ).

params_content_type_with_charset_test() ->
    ?assertEqual(
        #{~"charset" => ~"utf-8"},
        cactus_multipart:params(~"text/html; charset=utf-8")
    ).

params_no_params_returns_empty_map_test() ->
    ?assertEqual(#{}, cactus_multipart:params(~"text/html")).

params_lowercases_param_names_test() ->
    %% Param names are case-insensitive per RFC 7231 §3.1.1.1.
    ?assertEqual(
        #{~"charset" => ~"UTF-8"},
        cactus_multipart:params(~"text/html; CHARSET=UTF-8")
    ).

params_skips_malformed_pairs_test() ->
    ?assertEqual(
        #{~"name" => ~"a"},
        cactus_multipart:params(~"form-data; junk; name=\"a\"")
    ).

params_trims_unquoted_value_whitespace_test() ->
    ?assertEqual(
        #{~"a" => ~"x"},
        cactus_multipart:params(~"type; a= x ")
    ).

%% =============================================================================
%% parse/2 — happy paths.
%% =============================================================================

parse_single_text_field_test() ->
    Body = <<
        "--BOUNDARY\r\n",
        "Content-Disposition: form-data; name=\"field1\"\r\n",
        "\r\n",
        "value1",
        "\r\n--BOUNDARY--\r\n"
    >>,
    {ok, [Part]} = cactus_multipart:parse(Body, ~"BOUNDARY"),
    ?assertEqual(~"value1", maps:get(body, Part)),
    ?assertEqual(
        ~"form-data; name=\"field1\"",
        proplists:get_value(~"content-disposition", maps:get(headers, Part))
    ).

parse_two_fields_test() ->
    Body = <<
        "--B\r\n",
        "Content-Disposition: form-data; name=\"a\"\r\n",
        "\r\n",
        "first",
        "\r\n--B\r\n",
        "Content-Disposition: form-data; name=\"b\"\r\n",
        "\r\n",
        "second",
        "\r\n--B--\r\n"
    >>,
    {ok, [P1, P2]} = cactus_multipart:parse(Body, ~"B"),
    ?assertEqual(~"first", maps:get(body, P1)),
    ?assertEqual(~"second", maps:get(body, P2)).

parse_file_upload_part_test() ->
    Body = <<
        "--B\r\n",
        "Content-Disposition: form-data; name=\"file\"; filename=\"hello.txt\"\r\n",
        "Content-Type: text/plain\r\n",
        "\r\n",
        "file contents",
        "\r\n--B--\r\n"
    >>,
    {ok, [Part]} = cactus_multipart:parse(Body, ~"B"),
    ?assertEqual(~"file contents", maps:get(body, Part)),
    Headers = maps:get(headers, Part),
    ?assertEqual(~"text/plain", proplists:get_value(~"content-type", Headers)),
    {match, _} = re:run(
        proplists:get_value(~"content-disposition", Headers),
        ~"filename=\"hello\\.txt\""
    ).

parse_preamble_is_skipped_test() ->
    %% RFC 7578 §4.1 — bytes before the first boundary are the preamble
    %% and must be ignored.
    Body = <<
        "ignore me\r\n",
        "--B\r\n",
        "Content-Disposition: form-data; name=\"a\"\r\n",
        "\r\n",
        "value",
        "\r\n--B--\r\n"
    >>,
    {ok, [Part]} = cactus_multipart:parse(Body, ~"B"),
    ?assertEqual(~"value", maps:get(body, Part)).

parse_empty_part_body_test() ->
    Body = <<
        "--B\r\n",
        "Content-Disposition: form-data; name=\"empty\"\r\n",
        "\r\n",
        "\r\n--B--\r\n"
    >>,
    {ok, [Part]} = cactus_multipart:parse(Body, ~"B"),
    ?assertEqual(<<>>, maps:get(body, Part)).

parse_part_with_multiple_headers_test() ->
    Body = <<
        "--B\r\n",
        "Content-Disposition: form-data; name=\"a\"\r\n",
        "Content-Type: text/plain\r\n",
        "X-Custom: yes\r\n",
        "\r\n",
        "v",
        "\r\n--B--\r\n"
    >>,
    {ok, [Part]} = cactus_multipart:parse(Body, ~"B"),
    Headers = maps:get(headers, Part),
    ?assertEqual(3, length(Headers)),
    ?assertEqual(~"yes", proplists:get_value(~"x-custom", Headers)).

parse_zero_parts_test() ->
    %% Just the terminating boundary, no parts.
    Body = <<"--B--\r\n">>,
    ?assertEqual({ok, []}, cactus_multipart:parse(Body, ~"B")).

%% =============================================================================
%% parse/2 — error paths.
%% =============================================================================

parse_no_initial_boundary_test() ->
    ?assertEqual(
        {error, no_initial_boundary},
        cactus_multipart:parse(~"random bytes", ~"BOUNDARY")
    ).

parse_no_terminating_boundary_test() ->
    %% Headers + body but no closing `--B--` after.
    Body = <<
        "--B\r\n",
        "Content-Disposition: form-data; name=\"a\"\r\n",
        "\r\nvalue"
    >>,
    ?assertMatch({error, _}, cactus_multipart:parse(Body, ~"B")).

parse_malformed_header_test() ->
    Body = <<
        "--B\r\n",
        "no-colon-here\r\n",
        "\r\n",
        "value",
        "\r\n--B--\r\n"
    >>,
    ?assertEqual({error, bad_header}, cactus_multipart:parse(Body, ~"B")).

boundary_unclosed_quote_test() ->
    %% Quoted-string boundary with no closing quote — return the rest of
    %% the input. Pragmatic: bad input but parseable.
    ?assertEqual(
        {ok, ~"unclosed"},
        cactus_multipart:boundary(~"multipart/form-data; boundary=\"unclosed")
    ).

parse_terminating_boundary_no_crlf_test() ->
    %% Some clients omit the trailing CRLF after `--<boundary>--`.
    Body = <<
        "--B\r\n",
        "Content-Disposition: form-data; name=\"a\"\r\n",
        "\r\n",
        "v",
        "\r\n--B--"
    >>,
    {ok, [Part]} = cactus_multipart:parse(Body, ~"B"),
    ?assertEqual(~"v", maps:get(body, Part)).

parse_no_separator_after_first_boundary_test() ->
    %% Bytes after the first boundary marker are neither `--` (end) nor
    %% `\r\n` (next part) — malformed.
    Body = <<"--Bgarbage">>,
    ?assertEqual({error, malformed}, cactus_multipart:parse(Body, ~"B")).

parse_error_propagates_through_subsequent_parts_test() ->
    %% Two parts; the second has a malformed header. The inner recursive
    %% parse_parts call returns the error, which the outer call must
    %% propagate.
    Body = <<
        "--B\r\n",
        "Content-Disposition: form-data; name=\"a\"\r\n",
        "\r\n",
        "first",
        "\r\n--B\r\n",
        "no-colon-on-second-part\r\n",
        "\r\n",
        "second",
        "\r\n--B--\r\n"
    >>,
    ?assertEqual({error, bad_header}, cactus_multipart:parse(Body, ~"B")).

parse_error_propagates_through_subsequent_headers_test() ->
    %% Multi-header part where the SECOND header is malformed — the
    %% recursive parse_header_lines call returns the error.
    Body = <<
        "--B\r\n",
        "Content-Disposition: form-data; name=\"a\"\r\n",
        "no-colon-on-this-line\r\n",
        "\r\n",
        "v",
        "\r\n--B--\r\n"
    >>,
    ?assertEqual({error, bad_header}, cactus_multipart:parse(Body, ~"B")).

parse_no_header_terminator_test() ->
    %% No \r\n\r\n separating headers from body — part is malformed.
    Body = <<
        "--B\r\n",
        "Content-Disposition: form-data; name=\"a\"\r\n",
        "value",
        "\r\n--B--\r\n"
    >>,
    ?assertMatch({error, _}, cactus_multipart:parse(Body, ~"B")).

%% =============================================================================
%% Adversarial / corner cases.
%% =============================================================================

parse_part_with_empty_header_block_test() ->
    %% Per RFC 5322 §2.2.3 (referenced by RFC 7578), the header field
    %% list may be empty — the part is just `\r\nbody`. Browsers don't
    %% emit this for form-data, but RFC-compliant clients can.
    Body = <<"--B\r\n\r\nhello\r\n--B--\r\n">>,
    ?assertEqual(
        {ok, [#{headers => [], body => ~"hello"}]},
        cactus_multipart:parse(Body, ~"B")
    ).

parse_part_body_can_contain_boundary_substring_test() ->
    %% The split is on `\r\n--<boundary>`, not on the bare boundary —
    %% so a body byte sequence that *contains* the boundary but isn't
    %% preceded by CRLF stays in the body.
    Body = <<
        "--B\r\n",
        "Content-Type: text/plain\r\n",
        "\r\n",
        "before--Bafter",
        "\r\n--B--\r\n"
    >>,
    ?assertEqual(
        {ok, [
            #{
                headers => [{~"content-type", ~"text/plain"}],
                body => ~"before--Bafter"
            }
        ]},
        cactus_multipart:parse(Body, ~"B")
    ).

parse_header_value_can_contain_colon_test() ->
    %% `binary:split/2` defaults to first match — values like
    %% `12:34:56` (timestamps), `Bearer abc:xyz` (creds) survive.
    Body = <<
        "--B\r\n",
        "X-Time: 12:34:56\r\n",
        "\r\n",
        "v",
        "\r\n--B--\r\n"
    >>,
    ?assertEqual(
        {ok, [#{headers => [{~"x-time", ~"12:34:56"}], body => ~"v"}]},
        cactus_multipart:parse(Body, ~"B")
    ).

parse_zero_parts_with_no_crlf_after_terminator_test() ->
    %% RFC 7578 epilogue may be omitted entirely — `--B--` (no CRLF).
    %% Already covered, but pin it next to the `--\r\n` shape.
    ?assertEqual({ok, []}, cactus_multipart:parse(<<"--B--">>, ~"B")).

parse_part_with_multiple_same_named_headers_preserves_order_test() ->
    %% Repeated headers (e.g. multiple `X-Token` entries) must be kept
    %% as separate `{Name, Value}` pairs in declaration order. The
    %% conn-side wire path documents the same convention for response
    %% headers, so multipart should match.
    Body = <<
        "--B\r\n",
        "X-Token: a\r\n",
        "X-Token: b\r\n",
        "\r\n",
        "v",
        "\r\n--B--\r\n"
    >>,
    ?assertEqual(
        {ok, [
            #{
                headers => [{~"x-token", ~"a"}, {~"x-token", ~"b"}],
                body => ~"v"
            }
        ]},
        cactus_multipart:parse(Body, ~"B")
    ).
