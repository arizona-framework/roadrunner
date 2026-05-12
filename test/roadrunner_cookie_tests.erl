-module(roadrunner_cookie_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% parse/1
%% =============================================================================

parse_empty_test() ->
    ?assertEqual([], roadrunner_cookie:parse(~"")).

parse_single_test() ->
    ?assertEqual(
        [{~"sid", ~"abc"}],
        roadrunner_cookie:parse(~"sid=abc")
    ).

parse_multiple_with_canonical_separator_test() ->
    ?assertEqual(
        [{~"sid", ~"abc"}, {~"theme", ~"dark"}],
        roadrunner_cookie:parse(~"sid=abc; theme=dark")
    ).

parse_multiple_no_space_after_semi_test() ->
    ?assertEqual(
        [{~"a", ~"1"}, {~"b", ~"2"}],
        roadrunner_cookie:parse(~"a=1;b=2")
    ).

parse_trims_leading_ows_test() ->
    ?assertEqual(
        [{~"sid", ~"abc"}, {~"theme", ~"dark"}],
        roadrunner_cookie:parse(~"sid=abc;   theme=dark")
    ).

parse_trims_trailing_ows_test() ->
    ?assertEqual(
        [{~"sid", ~"abc"}, {~"theme", ~"dark"}],
        roadrunner_cookie:parse(~"sid=abc   ; theme=dark   ")
    ).

parse_with_htab_separator_test() ->
    %% HTAB is also OWS per RFC 7230 — trim it on both sides.
    ?assertEqual(
        [{~"a", ~"1"}, {~"b", ~"2"}, {~"c", ~"3"}],
        roadrunner_cookie:parse(~"a=1;\tb=2\t;c=3")
    ).

parse_bad_no_equals_skipped_test() ->
    ?assertEqual([], roadrunner_cookie:parse(~"badnoequals")).

parse_empty_name_skipped_test() ->
    ?assertEqual([], roadrunner_cookie:parse(~"=value")).

parse_empty_value_accepted_test() ->
    ?assertEqual([{~"sid", ~""}], roadrunner_cookie:parse(~"sid=")).

parse_skip_bad_among_good_test() ->
    ?assertEqual(
        [{~"sid", ~"abc"}, {~"theme", ~"dark"}],
        roadrunner_cookie:parse(~"sid=abc; bad; theme=dark")
    ).

parse_all_whitespace_pair_skipped_test() ->
    ?assertEqual(
        [{~"a", ~"1"}, {~"b", ~"2"}],
        roadrunner_cookie:parse(~"a=1;   ;b=2")
    ).

parse_value_with_equals_test() ->
    %% Only the first '=' separates name from value.
    ?assertEqual(
        [{~"sid", ~"a=b=c"}],
        roadrunner_cookie:parse(~"sid=a=b=c")
    ).

parse_trims_ows_around_equals_test() ->
    %% Per RFC 6265 §5.2 the name and value are each trimmed of OWS
    %% separately — whitespace surrounding the `=` separator should not
    %% leak into either side. Regression: previously the parser only
    %% trimmed the whole pair, leaving `~"a  "` as the name.
    ?assertEqual(
        [{~"a", ~"b"}],
        roadrunner_cookie:parse(~"  a  =  b  ")
    ).

parse_internal_whitespace_in_value_preserved_test() ->
    %% Internal whitespace inside the value (between non-OWS bytes) is
    %% preserved — only outer LWS is trimmed.
    ?assertEqual(
        [{~"a", ~"b   c"}],
        roadrunner_cookie:parse(~"a=b   c")
    ).

parse_high_bytes_test() ->
    %% Non-ASCII bytes pass through (browsers shouldn't send them but
    %% we don't reject — `parse/1` is documented as lenient).
    ?assertEqual(
        [{~"k", <<255, 254>>}],
        roadrunner_cookie:parse(<<"k=", 255, 254>>)
    ).

parse_only_semicolons_test() ->
    ?assertEqual([], roadrunner_cookie:parse(~";;;;")).

parse_duplicate_names_preserve_order_test() ->
    %% RFC 6265 doesn't say what to do with duplicate cookie names — we
    %% keep all entries in declaration order so callers get a complete
    %% audit of what the client sent. Pinned so a "dedupe last wins"
    %% change is deliberate.
    ?assertEqual(
        [{~"a", ~"1"}, {~"b", ~"2"}, {~"a", ~"3"}],
        roadrunner_cookie:parse(~"a=1; b=2; a=3")
    ).

parse_internal_whitespace_in_name_preserved_test() ->
    %% RFC 6265 §4.1.1 forbids whitespace inside cookie names. We're
    %% lenient: the byte sequence is returned verbatim. Locked in so
    %% strict-mode parsing arrives via opt, not silent break.
    ?assertEqual([{~"foo bar", ~"v"}], roadrunner_cookie:parse(~"foo bar=v")).

%% =============================================================================
%% serialize/3
%% =============================================================================

serialize_minimal_test() ->
    ?assertEqual(
        ~"sid=abc",
        iolist_to_binary(roadrunner_cookie:serialize(~"sid", ~"abc", #{}))
    ).

serialize_with_domain_test() ->
    ?assertEqual(
        ~"sid=abc; Domain=example.com",
        iolist_to_binary(
            roadrunner_cookie:serialize(~"sid", ~"abc", #{domain => ~"example.com"})
        )
    ).

serialize_with_path_test() ->
    ?assertEqual(
        ~"sid=abc; Path=/api",
        iolist_to_binary(
            roadrunner_cookie:serialize(~"sid", ~"abc", #{path => ~"/api"})
        )
    ).

serialize_with_max_age_test() ->
    ?assertEqual(
        ~"sid=abc; Max-Age=3600",
        iolist_to_binary(
            roadrunner_cookie:serialize(~"sid", ~"abc", #{max_age => 3600})
        )
    ).

serialize_with_max_age_zero_test() ->
    ?assertEqual(
        ~"sid=abc; Max-Age=0",
        iolist_to_binary(
            roadrunner_cookie:serialize(~"sid", ~"abc", #{max_age => 0})
        )
    ).

serialize_with_expires_test() ->
    %% Expires takes a pre-formatted IMF-fixdate / RFC 1123 string.
    ?assertEqual(
        ~"sid=abc; Expires=Wed, 09 Jun 2027 10:18:14 GMT",
        iolist_to_binary(
            roadrunner_cookie:serialize(~"sid", ~"abc", #{
                expires => ~"Wed, 09 Jun 2027 10:18:14 GMT"
            })
        )
    ).

serialize_with_secure_test() ->
    ?assertEqual(
        ~"sid=abc; Secure",
        iolist_to_binary(
            roadrunner_cookie:serialize(~"sid", ~"abc", #{secure => true})
        )
    ).

serialize_secure_false_omitted_test() ->
    ?assertEqual(
        ~"sid=abc",
        iolist_to_binary(
            roadrunner_cookie:serialize(~"sid", ~"abc", #{secure => false})
        )
    ).

serialize_with_http_only_test() ->
    ?assertEqual(
        ~"sid=abc; HttpOnly",
        iolist_to_binary(
            roadrunner_cookie:serialize(~"sid", ~"abc", #{http_only => true})
        )
    ).

serialize_http_only_false_omitted_test() ->
    ?assertEqual(
        ~"sid=abc",
        iolist_to_binary(
            roadrunner_cookie:serialize(~"sid", ~"abc", #{http_only => false})
        )
    ).

serialize_with_same_site_strict_test() ->
    ?assertEqual(
        ~"sid=abc; SameSite=Strict",
        iolist_to_binary(
            roadrunner_cookie:serialize(~"sid", ~"abc", #{same_site => strict})
        )
    ).

serialize_with_same_site_lax_test() ->
    ?assertEqual(
        ~"sid=abc; SameSite=Lax",
        iolist_to_binary(
            roadrunner_cookie:serialize(~"sid", ~"abc", #{same_site => lax})
        )
    ).

serialize_with_same_site_none_test() ->
    ?assertEqual(
        ~"sid=abc; SameSite=None",
        iolist_to_binary(
            roadrunner_cookie:serialize(~"sid", ~"abc", #{same_site => none})
        )
    ).

serialize_with_all_attrs_test() ->
    %% All attributes appear in the documented order.
    Opts = #{
        domain => ~"example.com",
        path => ~"/api",
        max_age => 3600,
        expires => ~"Wed, 09 Jun 2027 10:18:14 GMT",
        secure => true,
        http_only => true,
        same_site => strict
    },
    Expected = iolist_to_binary([
        ~"sid=abc",
        ~"; Domain=example.com",
        ~"; Path=/api",
        ~"; Max-Age=3600",
        ~"; Expires=Wed, 09 Jun 2027 10:18:14 GMT",
        ~"; Secure",
        ~"; HttpOnly",
        ~"; SameSite=Strict"
    ]),
    ?assertEqual(
        Expected,
        iolist_to_binary(roadrunner_cookie:serialize(~"sid", ~"abc", Opts))
    ).

%% --- serialize/3 input validation ---

serialize_rejects_empty_name_test() ->
    ?assertError(
        {invalid_cookie_name, ~""},
        roadrunner_cookie:serialize(~"", ~"abc", #{})
    ).

serialize_rejects_separator_in_name_test() ->
    %% `;` is a token separator per RFC 7230 §3.2.6 — must not appear in
    %% a cookie-name or it would smuggle a new pair on the wire.
    ?assertError(
        {invalid_cookie_name, ~"foo;bar"},
        roadrunner_cookie:serialize(~"foo;bar", ~"abc", #{})
    ).

serialize_rejects_equals_in_name_test() ->
    ?assertError(
        {invalid_cookie_name, ~"foo=bar"},
        roadrunner_cookie:serialize(~"foo=bar", ~"abc", #{})
    ).

serialize_rejects_space_in_name_test() ->
    ?assertError(
        {invalid_cookie_name, ~"foo bar"},
        roadrunner_cookie:serialize(~"foo bar", ~"abc", #{})
    ).

serialize_rejects_crlf_in_name_test() ->
    ?assertError(
        {invalid_cookie_name, ~"foo\r\nbar"},
        roadrunner_cookie:serialize(~"foo\r\nbar", ~"abc", #{})
    ).

serialize_rejects_semicolon_in_value_test() ->
    %% Cookie-smuggling: `abc; admin=1` would surface as a phantom
    %% attribute on the client. Reject at the encoder.
    ?assertError(
        {invalid_cookie_value, ~"abc; admin=1"},
        roadrunner_cookie:serialize(~"sid", ~"abc; admin=1", #{})
    ).

serialize_rejects_comma_in_value_test() ->
    ?assertError(
        {invalid_cookie_value, ~"a,b"},
        roadrunner_cookie:serialize(~"sid", ~"a,b", #{})
    ).

serialize_rejects_dquote_in_value_test() ->
    ?assertError(
        {invalid_cookie_value, ~"a\"b"},
        roadrunner_cookie:serialize(~"sid", ~"a\"b", #{})
    ).

serialize_rejects_backslash_in_value_test() ->
    ?assertError(
        {invalid_cookie_value, ~"a\\b"},
        roadrunner_cookie:serialize(~"sid", ~"a\\b", #{})
    ).

serialize_rejects_crlf_in_value_test() ->
    ?assertError(
        {invalid_cookie_value, ~"a\r\nb"},
        roadrunner_cookie:serialize(~"sid", ~"a\r\nb", #{})
    ).

serialize_rejects_nul_in_value_test() ->
    ?assertError(
        {invalid_cookie_value, <<"a", 0, "b">>},
        roadrunner_cookie:serialize(~"sid", <<"a", 0, "b">>, #{})
    ).

serialize_accepts_empty_value_test() ->
    %% RFC 6265 §4.1.1: cookie-value = *cookie-octet, so empty is legal.
    ?assertEqual(
        ~"sid=",
        iolist_to_binary(roadrunner_cookie:serialize(~"sid", ~"", #{}))
    ).

serialize_rejects_semicolon_in_domain_test() ->
    ?assertError(
        {invalid_cookie_attr, domain, ~"ex;ample.com"},
        roadrunner_cookie:serialize(~"sid", ~"abc", #{domain => ~"ex;ample.com"})
    ).

serialize_rejects_space_in_domain_test() ->
    ?assertError(
        {invalid_cookie_attr, domain, ~"example .com"},
        roadrunner_cookie:serialize(~"sid", ~"abc", #{domain => ~"example .com"})
    ).

serialize_rejects_crlf_in_domain_test() ->
    ?assertError(
        {invalid_cookie_attr, domain, ~"example.com\r\nX-Evil: 1"},
        roadrunner_cookie:serialize(~"sid", ~"abc", #{
            domain => ~"example.com\r\nX-Evil: 1"
        })
    ).

serialize_rejects_semicolon_in_path_test() ->
    ?assertError(
        {invalid_cookie_attr, path, ~"/a;b"},
        roadrunner_cookie:serialize(~"sid", ~"abc", #{path => ~"/a;b"})
    ).

serialize_rejects_crlf_in_path_test() ->
    ?assertError(
        {invalid_cookie_attr, path, ~"/a\r\nb"},
        roadrunner_cookie:serialize(~"sid", ~"abc", #{path => ~"/a\r\nb"})
    ).

serialize_rejects_crlf_in_expires_test() ->
    ?assertError(
        {invalid_cookie_attr, expires, ~"Wed\r\nX-Evil: 1"},
        roadrunner_cookie:serialize(~"sid", ~"abc", #{expires => ~"Wed\r\nX-Evil: 1"})
    ).

serialize_rejects_semicolon_in_expires_test() ->
    ?assertError(
        {invalid_cookie_attr, expires, ~"Wed; admin=1"},
        roadrunner_cookie:serialize(~"sid", ~"abc", #{expires => ~"Wed; admin=1"})
    ).

serialize_accepts_token_punctuation_in_name_test() ->
    %% Token punctuation (RFC 7230 §3.2.6): `!#$%&'*+-.^_`|~`. Pin so an
    %% over-eager validator doesn't reject legal cookie names.
    ?assertEqual(
        ~"_a.b-c=v",
        iolist_to_binary(roadrunner_cookie:serialize(~"_a.b-c", ~"v", #{}))
    ).

serialize_accepts_alnum_in_name_test() ->
    %% RFC 7230 §3.2.6 token covers ALPHA and DIGIT; exercise both
    %% uppercase and digit branches of the validator.
    ?assertEqual(
        ~"Foo42=v",
        iolist_to_binary(roadrunner_cookie:serialize(~"Foo42", ~"v", #{}))
    ).
