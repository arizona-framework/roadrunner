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
