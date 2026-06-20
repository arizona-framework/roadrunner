-module(roadrunner_req_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Pure accessors over a roadrunner_req:request() map.
%% =============================================================================

method_test() ->
    ?assertEqual(~"GET", roadrunner_req:method(sample_req())).

method_is_match_test() ->
    ?assertEqual(true, roadrunner_req:method_is(~"GET", sample_req())).

method_is_no_match_test() ->
    ?assertEqual(false, roadrunner_req:method_is(~"POST", sample_req())).

version_test() ->
    ?assertEqual({1, 1}, roadrunner_req:version(sample_req())).

headers_test() ->
    ?assertEqual(
        [{~"host", ~"example.com"}, {~"accept", ~"*/*"}],
        roadrunner_req:headers(sample_req())
    ).

%% --- path / qs ---

path_no_query_test() ->
    ?assertEqual(~"/foo", roadrunner_req:path(sample_req_target(~"/foo"))).

path_with_query_test() ->
    ?assertEqual(~"/foo", roadrunner_req:path(sample_req_target(~"/foo?a=1&b=2"))).

path_uses_stored_field_test() ->
    %% When the h1 parser already sliced `path`, `path/1` reads it directly
    %% (the O(1) fast clause) rather than re-splitting `target`.
    ?assertEqual(
        ~"/foo",
        roadrunner_req:path(#{target => ~"/foo?a=1&b=2", path => ~"/foo"})
    ).

qs_no_query_test() ->
    ?assertEqual(~"", roadrunner_req:qs(sample_req_target(~"/foo"))).

qs_with_query_test() ->
    ?assertEqual(~"a=1&b=2", roadrunner_req:qs(sample_req_target(~"/foo?a=1&b=2"))).

qs_empty_after_question_test() ->
    %% "/foo?" — split returns ["/foo", ""], qs is empty.
    ?assertEqual(~"", roadrunner_req:qs(sample_req_target(~"/foo?"))).

%% --- header/2 ---

header_found_test() ->
    ?assertEqual(~"example.com", roadrunner_req:header(~"host", sample_req())).

header_not_found_test() ->
    ?assertEqual(undefined, roadrunner_req:header(~"x-missing", sample_req())).

header_case_insensitive_test() ->
    %% Caller passes mixed case; lookup finds the lowercased entry.
    ?assertEqual(~"example.com", roadrunner_req:header(~"Host", sample_req())).

%% --- has_header/2 ---

has_header_present_test() ->
    ?assertEqual(true, roadrunner_req:has_header(~"host", sample_req())).

has_header_present_mixed_case_test() ->
    ?assertEqual(true, roadrunner_req:has_header(~"Host", sample_req())).

has_header_absent_test() ->
    ?assertEqual(false, roadrunner_req:has_header(~"x-missing", sample_req())).

%% --- parse_qs/1 ---

parse_qs_empty_test() ->
    ?assertEqual([], roadrunner_req:parse_qs(sample_req_target(~"/foo"))).

parse_qs_single_test() ->
    ?assertEqual(
        [{~"a", ~"1"}],
        roadrunner_req:parse_qs(sample_req_target(~"/foo?a=1"))
    ).

parse_qs_multiple_test() ->
    ?assertEqual(
        [{~"a", ~"1"}, {~"b", ~"2"}],
        roadrunner_req:parse_qs(sample_req_target(~"/foo?a=1&b=2"))
    ).

parse_qs_decodes_percent_test() ->
    ?assertEqual(
        [{~"q", ~"hello world"}],
        roadrunner_req:parse_qs(sample_req_target(~"/foo?q=hello%20world"))
    ).

%% --- parse_cookies/1 ---

parse_cookies_no_header_test() ->
    ?assertEqual([], roadrunner_req:parse_cookies(sample_req())).

parse_cookies_single_test() ->
    Req = with_cookie(~"sid=abc"),
    ?assertEqual([{~"sid", ~"abc"}], roadrunner_req:parse_cookies(Req)).

parse_cookies_multiple_test() ->
    Req = with_cookie(~"sid=abc; theme=dark"),
    ?assertEqual(
        [{~"sid", ~"abc"}, {~"theme", ~"dark"}],
        roadrunner_req:parse_cookies(Req)
    ).

%% --- body/1 ---

body_present_test() ->
    Req = (sample_req())#{body => ~"hello world"},
    ?assertEqual(~"hello world", roadrunner_req:body(Req)).

body_absent_returns_empty_test() ->
    %% A request map with no body field returns empty bytes.
    ?assertEqual(~"", roadrunner_req:body(sample_req())).

%% --- has_body/1 ---

has_body_present_test() ->
    Req = (sample_req())#{body => ~"hello"},
    ?assertEqual(true, roadrunner_req:has_body(Req)).

has_body_empty_returns_false_test() ->
    Req = (sample_req())#{body => ~""},
    ?assertEqual(false, roadrunner_req:has_body(Req)).

%% --- read_body/1,2 ---

read_body_auto_mode_returns_buffered_body_test() ->
    Req = (sample_req())#{body => ~"already buffered"},
    ?assertEqual({ok, ~"already buffered", Req}, roadrunner_req:read_body(Req)).

read_body_no_body_field_returns_empty_test() ->
    Req = sample_req(),
    ?assertEqual({ok, ~"", Req}, roadrunner_req:read_body(Req)).

read_body_manual_state_full_drain_test() ->
    BS = #{
        framing => {content_length, 5},
        buffered => ~"hello",
        bytes_read => 0,
        recv => fun() -> error(unused) end,
        max => 1000,
        trailer_limits => {8192, 10240, 100}
    },
    Req = (sample_req())#{body_reader => BS},
    {ok, Bytes, Req2} = roadrunner_req:read_body(Req),
    ?assertEqual(~"hello", Bytes),
    ?assertEqual(~"hello", roadrunner_req:body(Req2)).

read_body_manual_state_partial_returns_more_test() ->
    BS = #{
        framing => {content_length, 6},
        buffered => ~"abcdef",
        bytes_read => 0,
        recv => fun() -> error(unused) end,
        max => 1000,
        trailer_limits => {8192, 10240, 100}
    },
    Req = (sample_req())#{body_reader => BS},
    {more, First, Req2} = roadrunner_req:read_body(Req, #{length => 4}),
    ?assertEqual(~"abcd", First),
    {ok, Last, _Req3} = roadrunner_req:read_body(Req2, #{length => 4}),
    ?assertEqual(~"ef", Last).

read_body_manual_state_error_propagates_test() ->
    BS = #{
        framing => {content_length, 100},
        buffered => <<>>,
        bytes_read => 0,
        recv => fun() -> {error, closed} end,
        max => 1000,
        trailer_limits => {8192, 10240, 100}
    },
    Req = (sample_req())#{body_reader => BS},
    ?assertEqual({error, closed}, roadrunner_req:read_body(Req)).

%% --- read_body_chunked/1 ---

read_body_chunked_auto_mode_returns_buffered_test() ->
    Req = (sample_req())#{body => ~"already buffered"},
    ?assertEqual({ok, ~"already buffered", Req}, roadrunner_req:read_body_chunked(Req)).

read_body_chunked_manual_state_yields_one_chunk_test() ->
    BS = #{
        framing => chunked,
        buffered => ~"3\r\nfoo\r\n0\r\n\r\n",
        bytes_read => 0,
        pending => <<>>,
        done => false,
        recv => fun() -> error(unused) end,
        max => 1000,
        trailer_limits => {8192, 10240, 100}
    },
    Req = (sample_req())#{body_reader => BS},
    {more, Bytes, _Req2} = roadrunner_req:read_body_chunked(Req),
    ?assertEqual(~"foo", Bytes).

%% --- forwarded_for/1 ---

forwarded_for_absent_returns_undefined_test() ->
    ?assertEqual(undefined, roadrunner_req:forwarded_for(sample_req())).

forwarded_for_x_forwarded_for_single_test() ->
    Req = (sample_req())#{headers => [{~"x-forwarded-for", ~"1.2.3.4"}]},
    ?assertEqual(~"1.2.3.4", roadrunner_req:forwarded_for(Req)).

forwarded_for_x_forwarded_for_chain_test() ->
    %% Leftmost is the original client; the rest are intermediate proxies.
    Req = (sample_req())#{
        headers => [{~"x-forwarded-for", ~"1.2.3.4, 5.6.7.8, 9.10.11.12"}]
    },
    ?assertEqual(~"1.2.3.4", roadrunner_req:forwarded_for(Req)).

forwarded_for_x_forwarded_for_trims_whitespace_test() ->
    Req = (sample_req())#{headers => [{~"x-forwarded-for", ~"   1.2.3.4   "}]},
    ?assertEqual(~"1.2.3.4", roadrunner_req:forwarded_for(Req)).

forwarded_for_rfc7239_simple_test() ->
    Req = (sample_req())#{
        headers => [{~"forwarded", ~"for=192.0.2.60;proto=http;by=203.0.113.43"}]
    },
    ?assertEqual(~"192.0.2.60", roadrunner_req:forwarded_for(Req)).

forwarded_for_rfc7239_takes_leftmost_element_test() ->
    %% Multiple proxies hop chain — the leftmost forwarded-element
    %% identifies the original client.
    Req = (sample_req())#{
        headers => [{~"forwarded", ~"for=1.2.3.4, for=5.6.7.8;proto=https"}]
    },
    ?assertEqual(~"1.2.3.4", roadrunner_req:forwarded_for(Req)).

forwarded_for_rfc7239_quoted_value_test() ->
    %% IPv6 addresses with ports must be quoted per RFC 7239 §6.
    Req = (sample_req())#{
        headers => [{~"forwarded", ~"for=\"[2001:db8::1]:4711\""}]
    },
    ?assertEqual(~"[2001:db8::1]:4711", roadrunner_req:forwarded_for(Req)).

forwarded_for_rfc7239_case_insensitive_param_test() ->
    Req = (sample_req())#{headers => [{~"forwarded", ~"FOR=10.0.0.1"}]},
    ?assertEqual(~"10.0.0.1", roadrunner_req:forwarded_for(Req)).

forwarded_for_rfc7239_wins_over_x_forwarded_for_test() ->
    %% When both are present, the modern Forwarded header wins.
    Req = (sample_req())#{
        headers => [
            {~"forwarded", ~"for=1.1.1.1"},
            {~"x-forwarded-for", ~"2.2.2.2"}
        ]
    },
    ?assertEqual(~"1.1.1.1", roadrunner_req:forwarded_for(Req)).

forwarded_for_rfc7239_no_for_param_returns_undefined_test() ->
    Req = (sample_req())#{headers => [{~"forwarded", ~"proto=https;by=10.0.0.1"}]},
    ?assertEqual(undefined, roadrunner_req:forwarded_for(Req)).

forwarded_for_rfc7239_malformed_pair_skipped_test() ->
    %% Pair with no `=` is just skipped — don't crash.
    Req = (sample_req())#{
        headers => [{~"forwarded", ~"junk;for=1.2.3.4"}]
    },
    ?assertEqual(~"1.2.3.4", roadrunner_req:forwarded_for(Req)).

forwarded_for_x_forwarded_for_empty_returns_undefined_test() ->
    %% Empty X-Forwarded-For (e.g. proxy stripped it without removing
    %% the header) returns undefined rather than empty binary.
    Req = (sample_req())#{headers => [{~"x-forwarded-for", ~"   "}]},
    ?assertEqual(undefined, roadrunner_req:forwarded_for(Req)).

forwarded_for_rfc7239_unclosed_quote_test() ->
    %% Defensive: malformed quoted value with no closing quote — return
    %% the rest of the string rather than crashing.
    Req = (sample_req())#{
        headers => [{~"forwarded", ~"for=\"unclosed"}]
    },
    ?assertEqual(~"unclosed", roadrunner_req:forwarded_for(Req)).

forwarded_for_rfc7239_empty_value_returns_undefined_test() ->
    %% `for=` with an empty value — normalize to undefined to match
    %% the X-Forwarded-For empty-value behavior.
    Req = (sample_req())#{headers => [{~"forwarded", ~"for=;by=1.1.1.1"}]},
    ?assertEqual(undefined, roadrunner_req:forwarded_for(Req)).

%% --- read_form/1 ---

read_form_urlencoded_test() ->
    Req = (sample_req())#{
        headers => [{~"content-type", ~"application/x-www-form-urlencoded"}],
        body => ~"a=1&b=hello+world&c"
    },
    {ok, urlencoded, Pairs, _Req2} = roadrunner_req:read_form(Req),
    ?assertEqual([{~"a", ~"1"}, {~"b", ~"hello world"}, {~"c", true}], Pairs).

read_form_urlencoded_with_charset_param_test() ->
    %% `; charset=utf-8` after the type — type-prefix match must still
    %% recognize it.
    Req = (sample_req())#{
        headers => [{~"content-type", ~"application/x-www-form-urlencoded; charset=utf-8"}],
        body => ~"a=1"
    },
    {ok, urlencoded, [{~"a", ~"1"}], _Req2} = roadrunner_req:read_form(Req).

read_form_multipart_test() ->
    Body = <<
        "--B\r\n",
        "Content-Disposition: form-data; name=\"field1\"\r\n",
        "\r\n",
        "value1",
        "\r\n--B--\r\n"
    >>,
    Req = (sample_req())#{
        headers => [{~"content-type", ~"multipart/form-data; boundary=B"}],
        body => Body
    },
    {ok, multipart, [Part], _Req2} = roadrunner_req:read_form(Req),
    ?assertEqual(~"value1", maps:get(body, Part)).

read_form_multipart_no_boundary_test() ->
    Req = (sample_req())#{
        headers => [{~"content-type", ~"multipart/form-data"}],
        body => ~"anything"
    },
    ?assertEqual({error, no_boundary}, roadrunner_req:read_form(Req)).

read_form_no_content_type_test() ->
    Req = (sample_req())#{body => ~"a=1"},
    ?assertEqual({error, no_content_type}, roadrunner_req:read_form(Req)).

read_form_unsupported_content_type_test() ->
    Req = (sample_req())#{
        headers => [{~"content-type", ~"application/json"}],
        body => ~"{}"
    },
    ?assertEqual({error, unsupported_content_type}, roadrunner_req:read_form(Req)).

read_form_urlencoded_body_read_error_propagates_test() ->
    BS = #{
        framing => {content_length, 100},
        buffered => <<>>,
        bytes_read => 0,
        pending => <<>>,
        done => false,
        recv => fun() -> {error, closed} end,
        max => 1000,
        trailer_limits => {8192, 10240, 100}
    },
    Req = (sample_req())#{
        headers => [{~"content-type", ~"application/x-www-form-urlencoded"}],
        body_reader => BS
    },
    ?assertEqual({error, closed}, roadrunner_req:read_form(Req)).

read_form_multipart_body_read_error_propagates_test() ->
    BS = #{
        framing => {content_length, 100},
        buffered => <<>>,
        bytes_read => 0,
        pending => <<>>,
        done => false,
        recv => fun() -> {error, closed} end,
        max => 1000,
        trailer_limits => {8192, 10240, 100}
    },
    Req = (sample_req())#{
        headers => [{~"content-type", ~"multipart/form-data; boundary=B"}],
        body_reader => BS
    },
    ?assertEqual({error, closed}, roadrunner_req:read_form(Req)).

read_form_multipart_parse_error_propagates_test() ->
    Req = (sample_req())#{
        headers => [{~"content-type", ~"multipart/form-data; boundary=B"}],
        body => ~"no boundary in body at all"
    },
    ?assertEqual({error, no_initial_boundary}, roadrunner_req:read_form(Req)).

read_body_chunked_manual_state_error_propagates_test() ->
    BS = #{
        framing => chunked,
        buffered => ~"5\r\nhe",
        bytes_read => 0,
        pending => <<>>,
        done => false,
        recv => fun() -> {error, closed} end,
        max => 1000,
        trailer_limits => {8192, 10240, 100}
    },
    Req = (sample_req())#{body_reader => BS},
    ?assertEqual({error, closed}, roadrunner_req:read_body_chunked(Req)).

%% Pending bytes don't satisfy the requested length, recursion needs
%% more from recv, recv errors. The pending-clause must propagate the
%% inner error up untransformed (otherwise we'd build garbage iodata
%% with `[Pending | RestIo]` even though RestIo is an error tuple).
read_body_chunked_manual_pending_then_recv_error_test() ->
    BS = #{
        framing => chunked,
        %% Wire still has half a chunk header — parse_chunk returns
        %% `{more, _}` and the session falls into recv.
        buffered => ~"5\r\n",
        bytes_read => 0,
        pending => ~"hi",
        done => false,
        recv => fun() -> {error, closed} end,
        max => 1000,
        trailer_limits => {8192, 10240, 100}
    },
    Req = (sample_req())#{body_reader => BS},
    ?assertEqual(
        {error, closed},
        roadrunner_req:read_body(Req, #{length => 5})
    ).

has_body_absent_returns_false_test() ->
    ?assertEqual(false, roadrunner_req:has_body(sample_req())).

%% --- bindings/1 ---

bindings_present_test() ->
    Req = (sample_req())#{bindings => #{~"id" => ~"42"}},
    ?assertEqual(#{~"id" => ~"42"}, roadrunner_req:bindings(Req)).

bindings_absent_returns_empty_map_test() ->
    ?assertEqual(#{}, roadrunner_req:bindings(sample_req())).

%% --- peer/1 ---

peer_present_test() ->
    Req = (sample_req())#{peer => {{127, 0, 0, 1}, 54321}},
    ?assertEqual({{127, 0, 0, 1}, 54321}, roadrunner_req:peer(Req)).

peer_absent_returns_undefined_test() ->
    ?assertEqual(undefined, roadrunner_req:peer(sample_req())).

%% --- scheme/1 ---

scheme_http_test() ->
    Req = (sample_req())#{scheme => http},
    ?assertEqual(http, roadrunner_req:scheme(Req)).

scheme_https_test() ->
    Req = (sample_req())#{scheme => https},
    ?assertEqual(https, roadrunner_req:scheme(Req)).

scheme_absent_defaults_to_http_test() ->
    ?assertEqual(http, roadrunner_req:scheme(sample_req())).

%% --- state/1 ---

state_present_test() ->
    Req = (sample_req())#{state => #{dir => ~"/var/www"}},
    ?assertEqual(#{dir => ~"/var/www"}, roadrunner_req:state(Req)).

state_absent_returns_undefined_test() ->
    ?assertEqual(undefined, roadrunner_req:state(sample_req())).

%% --- request_id/1 ---

request_id_present_test() ->
    Req = (sample_req())#{request_id => ~"abcdef0123456789"},
    ?assertEqual(~"abcdef0123456789", roadrunner_req:request_id(Req)).

request_id_absent_returns_undefined_test() ->
    ?assertEqual(undefined, roadrunner_req:request_id(sample_req())).

%% --- listener_name/1 ---

listener_name_present_test() ->
    Req = (sample_req())#{listener_name => my_listener},
    ?assertEqual(my_listener, roadrunner_req:listener_name(Req)).

listener_name_absent_returns_undefined_test() ->
    ?assertEqual(undefined, roadrunner_req:listener_name(sample_req())).

%% --- private/1,2 ---

private_absent_returns_empty_map_test() ->
    ?assertEqual(#{}, roadrunner_req:private(sample_req())).

private_present_returns_map_test() ->
    Req = (sample_req())#{private => #{a => 1}},
    ?assertEqual(#{a => 1}, roadrunner_req:private(Req)).

private_key_present_test() ->
    Req = (sample_req())#{private => #{a => 1}},
    ?assertEqual(1, roadrunner_req:private(a, Req)).

private_key_absent_returns_undefined_test() ->
    Req = (sample_req())#{private => #{a => 1}},
    ?assertEqual(undefined, roadrunner_req:private(missing, Req)).

private_key_on_untouched_req_returns_undefined_test() ->
    ?assertEqual(undefined, roadrunner_req:private(any, sample_req())).

%% --- put_private/3 ---

put_private_creates_map_on_first_write_test() ->
    Req = roadrunner_req:put_private(k, v, sample_req()),
    ?assertEqual(#{k => v}, roadrunner_req:private(Req)).

put_private_overwrites_existing_key_test() ->
    Req0 = roadrunner_req:put_private(k, old, sample_req()),
    Req1 = roadrunner_req:put_private(k, new, Req0),
    ?assertEqual(new, roadrunner_req:private(k, Req1)).

put_private_preserves_other_private_keys_test() ->
    Req0 = roadrunner_req:put_private(a, 1, sample_req()),
    Req1 = roadrunner_req:put_private(b, 2, Req0),
    ?assertEqual(#{a => 1, b => 2}, roadrunner_req:private(Req1)).

put_private_preserves_other_req_fields_test() ->
    Req = roadrunner_req:put_private(k, v, (sample_req())#{state => kept}),
    ?assertEqual(kept, roadrunner_req:state(Req)).

%% --- merge_private/2 ---

merge_private_creates_map_on_first_write_test() ->
    Req = roadrunner_req:merge_private(#{a => 1, b => 2}, sample_req()),
    ?assertEqual(#{a => 1, b => 2}, roadrunner_req:private(Req)).

merge_private_caller_keys_win_on_conflict_test() ->
    Req0 = roadrunner_req:put_private(a, 1, sample_req()),
    Req1 = roadrunner_req:merge_private(#{a => 2, b => 3}, Req0),
    ?assertEqual(#{a => 2, b => 3}, roadrunner_req:private(Req1)).

merge_private_preserves_existing_keys_test() ->
    Req0 = roadrunner_req:put_private(a, 1, sample_req()),
    Req1 = roadrunner_req:merge_private(#{b => 2}, Req0),
    ?assertEqual(#{a => 1, b => 2}, roadrunner_req:private(Req1)).

%% --- delete_private/2 ---

delete_private_removes_key_and_keeps_siblings_test() ->
    Req0 = roadrunner_req:merge_private(#{a => 1, b => 2}, sample_req()),
    Req1 = roadrunner_req:delete_private(a, Req0),
    ?assertEqual(#{b => 2}, roadrunner_req:private(Req1)).

delete_private_absent_key_is_noop_test() ->
    Req0 = roadrunner_req:put_private(a, 1, sample_req()),
    Req1 = roadrunner_req:delete_private(missing, Req0),
    ?assertEqual(#{a => 1}, roadrunner_req:private(Req1)).

%% --- update_private/4 ---

update_private_seeds_init_when_absent_test() ->
    Req = roadrunner_req:update_private(n, fun(X) -> X + 1 end, 0, sample_req()),
    ?assertEqual(0, roadrunner_req:private(n, Req)).

update_private_applies_fun_when_present_test() ->
    Req0 = roadrunner_req:put_private(n, 1, sample_req()),
    Req1 = roadrunner_req:update_private(n, fun(X) -> X + 1 end, 0, Req0),
    ?assertEqual(2, roadrunner_req:private(n, Req1)).

%% --- fixtures ---

sample_req() ->
    #{
        method => ~"GET",
        target => ~"/foo?a=1",
        version => {1, 1},
        headers => [{~"host", ~"example.com"}, {~"accept", ~"*/*"}]
    }.

sample_req_target(Target) ->
    (sample_req())#{target := Target}.

with_cookie(CookieValue) ->
    Req = sample_req(),
    Req#{headers := [{~"cookie", CookieValue} | maps:get(headers, Req)]}.
