-module(roadrunner_multipart_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% boundary/1 — pulling the parameter out of Content-Type.
%% =============================================================================

boundary_simple_test() ->
    ?assertEqual(
        {ok, ~"abc123"},
        roadrunner_multipart:boundary(~"multipart/form-data; boundary=abc123")
    ).

boundary_no_space_test() ->
    ?assertEqual(
        {ok, ~"abc123"},
        roadrunner_multipart:boundary(~"multipart/form-data;boundary=abc123")
    ).

boundary_quoted_test() ->
    %% RFC 2046 allows quoted boundaries containing characters that
    %% would otherwise need escaping.
    ?assertEqual(
        {ok, ~"abc 123"},
        roadrunner_multipart:boundary(~"multipart/form-data; boundary=\"abc 123\"")
    ).

boundary_with_other_params_after_test() ->
    ?assertEqual(
        {ok, ~"xyz"},
        roadrunner_multipart:boundary(~"multipart/form-data; boundary=xyz; charset=utf-8")
    ).

boundary_with_other_params_before_test() ->
    ?assertEqual(
        {ok, ~"xyz"},
        roadrunner_multipart:boundary(~"multipart/form-data; charset=utf-8; boundary=xyz")
    ).

boundary_missing_test() ->
    ?assertEqual(
        {error, no_boundary},
        roadrunner_multipart:boundary(~"multipart/form-data")
    ).

%% =============================================================================
%% params/1 — generic header-parameter parser.
%% =============================================================================

params_form_data_with_name_and_filename_test() ->
    ?assertEqual(
        #{~"name" => ~"a", ~"filename" => ~"f.txt"},
        roadrunner_multipart:params(
            ~"form-data; name=\"a\"; filename=\"f.txt\""
        )
    ).

params_content_type_with_charset_test() ->
    ?assertEqual(
        #{~"charset" => ~"utf-8"},
        roadrunner_multipart:params(~"text/html; charset=utf-8")
    ).

params_no_params_returns_empty_map_test() ->
    ?assertEqual(#{}, roadrunner_multipart:params(~"text/html")).

params_lowercases_param_names_test() ->
    %% Param names are case-insensitive per RFC 7231 §3.1.1.1.
    ?assertEqual(
        #{~"charset" => ~"UTF-8"},
        roadrunner_multipart:params(~"text/html; CHARSET=UTF-8")
    ).

params_skips_malformed_pairs_test() ->
    ?assertEqual(
        #{~"name" => ~"a"},
        roadrunner_multipart:params(~"form-data; junk; name=\"a\"")
    ).

params_trims_unquoted_value_whitespace_test() ->
    ?assertEqual(
        #{~"a" => ~"x"},
        roadrunner_multipart:params(~"type; a= x ")
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
    {ok, [Part]} = roadrunner_multipart:parse(Body, ~"BOUNDARY"),
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
    {ok, [P1, P2]} = roadrunner_multipart:parse(Body, ~"B"),
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
    {ok, [Part]} = roadrunner_multipart:parse(Body, ~"B"),
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
    {ok, [Part]} = roadrunner_multipart:parse(Body, ~"B"),
    ?assertEqual(~"value", maps:get(body, Part)).

parse_empty_part_body_test() ->
    Body = <<
        "--B\r\n",
        "Content-Disposition: form-data; name=\"empty\"\r\n",
        "\r\n",
        "\r\n--B--\r\n"
    >>,
    {ok, [Part]} = roadrunner_multipart:parse(Body, ~"B"),
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
    {ok, [Part]} = roadrunner_multipart:parse(Body, ~"B"),
    Headers = maps:get(headers, Part),
    ?assertEqual(3, length(Headers)),
    ?assertEqual(~"yes", proplists:get_value(~"x-custom", Headers)).

parse_zero_parts_test() ->
    %% Just the terminating boundary, no parts.
    Body = <<"--B--\r\n">>,
    ?assertEqual({ok, []}, roadrunner_multipart:parse(Body, ~"B")).

%% =============================================================================
%% parse/2 — error paths.
%% =============================================================================

parse_no_initial_boundary_test() ->
    ?assertEqual(
        {error, no_initial_boundary},
        roadrunner_multipart:parse(~"random bytes", ~"BOUNDARY")
    ).

parse_no_terminating_boundary_test() ->
    %% Headers + body but no closing `--B--` after.
    Body = <<
        "--B\r\n",
        "Content-Disposition: form-data; name=\"a\"\r\n",
        "\r\nvalue"
    >>,
    ?assertMatch({error, _}, roadrunner_multipart:parse(Body, ~"B")).

parse_malformed_header_test() ->
    Body = <<
        "--B\r\n",
        "no-colon-here\r\n",
        "\r\n",
        "value",
        "\r\n--B--\r\n"
    >>,
    ?assertEqual({error, bad_header}, roadrunner_multipart:parse(Body, ~"B")).

boundary_unclosed_quote_test() ->
    %% Quoted-string boundary with no closing quote — return the rest of
    %% the input. Pragmatic: bad input but parseable.
    ?assertEqual(
        {ok, ~"unclosed"},
        roadrunner_multipart:boundary(~"multipart/form-data; boundary=\"unclosed")
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
    {ok, [Part]} = roadrunner_multipart:parse(Body, ~"B"),
    ?assertEqual(~"v", maps:get(body, Part)).

parse_no_separator_after_first_boundary_test() ->
    %% Bytes after the first boundary marker are neither `--` (end) nor
    %% `\r\n` (next part) — malformed.
    Body = <<"--Bgarbage">>,
    ?assertEqual({error, malformed}, roadrunner_multipart:parse(Body, ~"B")).

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
    ?assertEqual({error, bad_header}, roadrunner_multipart:parse(Body, ~"B")).

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
    ?assertEqual({error, bad_header}, roadrunner_multipart:parse(Body, ~"B")).

parse_no_header_terminator_test() ->
    %% No \r\n\r\n separating headers from body — part is malformed.
    Body = <<
        "--B\r\n",
        "Content-Disposition: form-data; name=\"a\"\r\n",
        "value",
        "\r\n--B--\r\n"
    >>,
    ?assertMatch({error, _}, roadrunner_multipart:parse(Body, ~"B")).

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
        roadrunner_multipart:parse(Body, ~"B")
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
        roadrunner_multipart:parse(Body, ~"B")
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
        roadrunner_multipart:parse(Body, ~"B")
    ).

parse_zero_parts_with_no_crlf_after_terminator_test() ->
    %% RFC 7578 epilogue may be omitted entirely — `--B--` (no CRLF).
    %% Already covered, but pin it next to the `--\r\n` shape.
    ?assertEqual({ok, []}, roadrunner_multipart:parse(<<"--B--">>, ~"B")).

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
        roadrunner_multipart:parse(Body, ~"B")
    ).

%% =============================================================================
%% disposition/1
%% =============================================================================

disposition_test() ->
    ?assertEqual(
        {~"form-data", #{~"name" => ~"avatar", ~"filename" => ~"me.png"}},
        roadrunner_multipart:disposition(~"form-data; name=\"avatar\"; filename=\"me.png\"")
    ).

disposition_lowercases_the_type_test() ->
    ?assertEqual(
        {~"form-data", #{~"name" => ~"a"}},
        roadrunner_multipart:disposition(~" Form-Data ;name=a")
    ).

disposition_without_params_test() ->
    ?assertEqual({~"inline", #{}}, roadrunner_multipart:disposition(~"inline")).

%% =============================================================================
%% read_part/1,2 and read_part_body/1,2 over a buffered (auto mode) body
%% =============================================================================

-define(TWO_PARTS, <<
    "preamble\r\n",
    "--B\r\n",
    "Content-Disposition: form-data; name=\"field\"\r\n",
    "\r\n",
    "value",
    "\r\n--B\r\n",
    "Content-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n",
    "Content-Type: text/plain\r\n",
    "\r\n",
    "hello world",
    "\r\n--B--\r\n",
    "epilogue"
>>).

read_parts_test() ->
    {ok, H1, R1} = roadrunner_multipart:read_part(stream_req(?TWO_PARTS)),
    ?assertEqual([{~"content-disposition", ~"form-data; name=\"field\""}], H1),
    {ok, ~"value", R2} = roadrunner_multipart:read_part_body(R1),
    {ok, H2, R3} = roadrunner_multipart:read_part(R2),
    ?assertEqual(
        [
            {~"content-disposition", ~"form-data; name=\"file\"; filename=\"a.txt\""},
            {~"content-type", ~"text/plain"}
        ],
        H2
    ),
    {ok, ~"hello world", R4} = roadrunner_multipart:read_part_body(R3),
    {done, R5} = roadrunner_multipart:read_part(R4),
    %% Done stays done.
    ?assertMatch({done, _}, roadrunner_multipart:read_part(R5)).

read_part_body_in_pieces_test() ->
    {ok, _, R1} = roadrunner_multipart:read_part(stream_req(?TWO_PARTS)),
    {ok, _, R2} = roadrunner_multipart:read_part(R1),
    {more, ~"hell", R3} = roadrunner_multipart:read_part_body(R2, #{length => 4}),
    {more, ~"o wo", R4} = roadrunner_multipart:read_part_body(R3, #{length => 4}),
    {ok, ~"rld", R5} = roadrunner_multipart:read_part_body(R4, #{length => 4}),
    ?assertMatch({done, _}, roadrunner_multipart:read_part(R5)).

read_part_body_length_reached_before_the_delimiter_test() ->
    %% The delimiter is in the buffer, past `length`: the first piece is cut
    %% at `length`, the second ends at the delimiter.
    {ok, _, R1} = roadrunner_multipart:read_part(stream_req(?TWO_PARTS)),
    {more, ~"val", R2} = roadrunner_multipart:read_part_body(R1, #{length => 3}),
    ?assertMatch({ok, ~"ue", _}, roadrunner_multipart:read_part_body(R2, #{length => 3})).

unread_part_body_is_skipped_test() ->
    {ok, _, R1} = roadrunner_multipart:read_part(stream_req(?TWO_PARTS)),
    {ok, H2, R2} = roadrunner_multipart:read_part(R1),
    ?assertMatch([{~"content-disposition", <<"form-data; name=\"file\"", _/binary>>} | _], H2),
    {ok, ~"hello world", _} = roadrunner_multipart:read_part_body(R2).

partly_read_part_body_is_skipped_test() ->
    {ok, _, R1} = roadrunner_multipart:read_part(stream_req(?TWO_PARTS)),
    {more, ~"v", R2} = roadrunner_multipart:read_part_body(R1, #{length => 1}),
    {ok, _, R3} = roadrunner_multipart:read_part(R2),
    ?assertMatch({ok, ~"hello world", _}, roadrunner_multipart:read_part_body(R3)).

part_without_headers_test() ->
    Body = <<"--B\r\n\r\nraw\r\n--B--">>,
    {ok, [], R1} = roadrunner_multipart:read_part(stream_req(Body)),
    {ok, ~"raw", R2} = roadrunner_multipart:read_part_body(R1),
    ?assertMatch({done, _}, roadrunner_multipart:read_part(R2)).

empty_part_body_test() ->
    Body = <<"--B\r\nX-A: 1\r\n\r\n\r\n--B--">>,
    {ok, [{~"x-a", ~"1"}], R1} = roadrunner_multipart:read_part(stream_req(Body)),
    ?assertMatch({ok, <<>>, _}, roadrunner_multipart:read_part_body(R1)).

no_parts_test() ->
    ?assertMatch({done, _}, roadrunner_multipart:read_part(stream_req(<<"--B--\r\n">>))).

transport_padding_after_a_boundary_test() ->
    %% RFC 2046 §5.1.1: spaces and tabs may follow a boundary.
    Body = <<"--B \t\r\n\r\nv\r\n--B-- ">>,
    {ok, [], R1} = roadrunner_multipart:read_part(stream_req(Body)),
    {ok, ~"v", R2} = roadrunner_multipart:read_part_body(R1),
    ?assertMatch({done, _}, roadrunner_multipart:read_part(R2)).

content_type_is_case_insensitive_test() ->
    Req = stream_req(~"Multipart/Form-Data; boundary=B", <<"--B--">>),
    ?assertMatch({done, _}, roadrunner_multipart:read_part(Req)).

quoted_boundary_test() ->
    Req = stream_req(~"multipart/mixed; boundary=\"a b\"", <<"--a b\r\n\r\nv\r\n--a b--">>),
    {ok, [], R1} = roadrunner_multipart:read_part(Req),
    ?assertMatch({ok, ~"v", _}, roadrunner_multipart:read_part_body(R1)).

not_multipart_test() ->
    ?assertEqual(
        {error, not_multipart},
        roadrunner_multipart:read_part(stream_req(~"text/plain", <<>>))
    ),
    ?assertEqual({error, not_multipart}, roadrunner_multipart:read_part(stream_req(no, <<>>))).

no_boundary_test() ->
    ?assertEqual(
        {error, no_boundary},
        roadrunner_multipart:read_part(stream_req(~"multipart/form-data", <<>>))
    ).

no_initial_boundary_test() ->
    ?assertEqual(
        {error, no_initial_boundary},
        roadrunner_multipart:read_part(stream_req(<<"no boundary here">>))
    ).

no_header_terminator_test() ->
    ?assertEqual(
        {error, no_header_terminator},
        roadrunner_multipart:read_part(stream_req(<<"--B\r\nX-A: 1\r\n">>))
    ).

no_part_terminator_reading_the_body_test() ->
    {ok, [], R1} = roadrunner_multipart:read_part(stream_req(<<"--B\r\n\r\ncut short">>)),
    ?assertEqual({error, no_part_terminator}, roadrunner_multipart:read_part_body(R1)).

no_part_terminator_skipping_the_body_test() ->
    {ok, [], R1} = roadrunner_multipart:read_part(stream_req(<<"--B\r\n\r\ncut short">>)),
    ?assertEqual({error, no_part_terminator}, roadrunner_multipart:read_part(R1)).

headers_too_large_test() ->
    Body = <<"--B\r\nX-Long: 0123456789\r\n\r\nv\r\n--B--">>,
    ?assertEqual(
        {error, headers_too_large},
        roadrunner_multipart:read_part(stream_req(Body), #{length => 10})
    ).

headers_too_large_without_their_end_test() ->
    %% Over the cap before the blank line even arrives.
    Body = <<"--B\r\nX-Long: 0123456789">>,
    ?assertEqual(
        {error, headers_too_large},
        roadrunner_multipart:read_part(stream_req(Body), #{length => 10})
    ).

bad_header_test() ->
    ?assertEqual(
        {error, bad_header},
        roadrunner_multipart:read_part(stream_req(<<"--B\r\nno colon\r\n\r\nv\r\n--B--">>))
    ).

malformed_after_a_boundary_test() ->
    ?assertEqual(
        {error, malformed},
        roadrunner_multipart:read_part(stream_req(<<"--Bxx\r\n\r\nv\r\n--B--">>))
    ).

body_ending_right_after_a_boundary_test() ->
    ?assertEqual(
        {error, no_part_terminator}, roadrunner_multipart:read_part(stream_req(<<"--B">>))
    ),
    ?assertEqual(
        {error, no_part_terminator}, roadrunner_multipart:read_part(stream_req(<<"--B-">>))
    ),
    ?assertEqual(
        {error, no_part_terminator}, roadrunner_multipart:read_part(stream_req(<<"--B\r">>))
    ).

empty_boundary_test() ->
    ?assertEqual(
        {error, no_boundary},
        roadrunner_multipart:read_part(stream_req(~"multipart/form-data; boundary=", <<>>))
    ),
    ?assertEqual(
        {error, no_boundary},
        roadrunner_multipart:read_part(stream_req(~"multipart/form-data; boundary=\"\"", <<>>))
    ).

boundary_over_70_characters_test() ->
    Long = binary:copy(~"b", 71),
    ?assertEqual(
        {error, no_boundary},
        roadrunner_multipart:read_part(
            stream_req(<<"multipart/form-data; boundary=", Long/binary>>, <<>>)
        )
    ),
    Max = binary:copy(~"b", 70),
    ?assertMatch(
        {done, _},
        roadrunner_multipart:read_part(
            stream_req(<<"multipart/form-data; boundary=", Max/binary>>, <<"--", Max/binary, "--">>)
        )
    ).

disposition_keeps_a_semicolon_in_quotes_test() ->
    ?assertEqual(
        {~"form-data", #{~"name" => ~"f", ~"filename" => ~"a;b.txt"}},
        roadrunner_multipart:disposition(~"form-data; name=\"f\"; filename=\"a;b.txt\"")
    ).

params_keeps_a_semicolon_in_quotes_test() ->
    ?assertEqual(
        #{~"boundary" => ~"x;y", ~"charset" => ~"utf-8"},
        roadrunner_multipart:params(~"multipart/form-data; boundary=\"x;y\"; charset=utf-8")
    ).

body_ending_in_headers_after_a_cr_test() ->
    ?assertEqual(
        {error, no_header_terminator}, roadrunner_multipart:read_part(stream_req(<<"--B\r\n\r">>))
    ).

stream_req(Body) ->
    stream_req(~"multipart/form-data; boundary=B", Body).

stream_req(no, Body) ->
    #{method => ~"POST", target => ~"/", version => {1, 1}, headers => [], body => Body};
stream_req(ContentType, Body) ->
    #{
        method => ~"POST",
        target => ~"/",
        version => {1, 1},
        headers => [{~"content-type", ContentType}],
        body => Body
    }.
