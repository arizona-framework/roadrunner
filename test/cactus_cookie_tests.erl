-module(cactus_cookie_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% parse/1
%% =============================================================================

parse_empty_test() ->
    ?assertEqual([], cactus_cookie:parse(~"")).

parse_single_test() ->
    ?assertEqual(
        [{~"sid", ~"abc"}],
        cactus_cookie:parse(~"sid=abc")
    ).

parse_multiple_with_canonical_separator_test() ->
    ?assertEqual(
        [{~"sid", ~"abc"}, {~"theme", ~"dark"}],
        cactus_cookie:parse(~"sid=abc; theme=dark")
    ).

parse_multiple_no_space_after_semi_test() ->
    ?assertEqual(
        [{~"a", ~"1"}, {~"b", ~"2"}],
        cactus_cookie:parse(~"a=1;b=2")
    ).

parse_trims_leading_ows_test() ->
    ?assertEqual(
        [{~"sid", ~"abc"}, {~"theme", ~"dark"}],
        cactus_cookie:parse(~"sid=abc;   theme=dark")
    ).

parse_trims_trailing_ows_test() ->
    ?assertEqual(
        [{~"sid", ~"abc"}, {~"theme", ~"dark"}],
        cactus_cookie:parse(~"sid=abc   ; theme=dark   ")
    ).

parse_with_htab_separator_test() ->
    %% HTAB is also OWS per RFC 7230 — trim it on both sides.
    ?assertEqual(
        [{~"a", ~"1"}, {~"b", ~"2"}, {~"c", ~"3"}],
        cactus_cookie:parse(~"a=1;\tb=2\t;c=3")
    ).

parse_bad_no_equals_skipped_test() ->
    ?assertEqual([], cactus_cookie:parse(~"badnoequals")).

parse_empty_name_skipped_test() ->
    ?assertEqual([], cactus_cookie:parse(~"=value")).

parse_empty_value_accepted_test() ->
    ?assertEqual([{~"sid", ~""}], cactus_cookie:parse(~"sid=")).

parse_skip_bad_among_good_test() ->
    ?assertEqual(
        [{~"sid", ~"abc"}, {~"theme", ~"dark"}],
        cactus_cookie:parse(~"sid=abc; bad; theme=dark")
    ).

parse_all_whitespace_pair_skipped_test() ->
    ?assertEqual(
        [{~"a", ~"1"}, {~"b", ~"2"}],
        cactus_cookie:parse(~"a=1;   ;b=2")
    ).

parse_value_with_equals_test() ->
    %% Only the first '=' separates name from value.
    ?assertEqual(
        [{~"sid", ~"a=b=c"}],
        cactus_cookie:parse(~"sid=a=b=c")
    ).

parse_trims_ows_around_equals_test() ->
    %% Per RFC 6265 §5.2 the name and value are each trimmed of OWS
    %% separately — whitespace surrounding the `=` separator should not
    %% leak into either side. Regression: previously the parser only
    %% trimmed the whole pair, leaving `~"a  "` as the name.
    ?assertEqual(
        [{~"a", ~"b"}],
        cactus_cookie:parse(~"  a  =  b  ")
    ).

parse_internal_whitespace_in_value_preserved_test() ->
    %% Internal whitespace inside the value (between non-OWS bytes) is
    %% preserved — only outer LWS is trimmed.
    ?assertEqual(
        [{~"a", ~"b   c"}],
        cactus_cookie:parse(~"a=b   c")
    ).

parse_high_bytes_test() ->
    %% Non-ASCII bytes pass through (browsers shouldn't send them but
    %% we don't reject — `parse/1` is documented as lenient).
    ?assertEqual(
        [{~"k", <<255, 254>>}],
        cactus_cookie:parse(<<"k=", 255, 254>>)
    ).

parse_only_semicolons_test() ->
    ?assertEqual([], cactus_cookie:parse(~";;;;")).

parse_duplicate_names_preserve_order_test() ->
    %% RFC 6265 doesn't say what to do with duplicate cookie names — we
    %% keep all entries in declaration order so callers get a complete
    %% audit of what the client sent. Pinned so a "dedupe last wins"
    %% change is deliberate.
    ?assertEqual(
        [{~"a", ~"1"}, {~"b", ~"2"}, {~"a", ~"3"}],
        cactus_cookie:parse(~"a=1; b=2; a=3")
    ).

parse_internal_whitespace_in_name_preserved_test() ->
    %% RFC 6265 §4.1.1 forbids whitespace inside cookie names. We're
    %% lenient: the byte sequence is returned verbatim. Locked in so
    %% strict-mode parsing arrives via opt, not silent break.
    ?assertEqual([{~"foo bar", ~"v"}], cactus_cookie:parse(~"foo bar=v")).

%% =============================================================================
%% serialize/3
%% =============================================================================

serialize_minimal_test() ->
    ?assertEqual(
        ~"sid=abc",
        iolist_to_binary(cactus_cookie:serialize(~"sid", ~"abc", #{}))
    ).

serialize_with_domain_test() ->
    ?assertEqual(
        ~"sid=abc; Domain=example.com",
        iolist_to_binary(
            cactus_cookie:serialize(~"sid", ~"abc", #{domain => ~"example.com"})
        )
    ).

serialize_with_path_test() ->
    ?assertEqual(
        ~"sid=abc; Path=/api",
        iolist_to_binary(
            cactus_cookie:serialize(~"sid", ~"abc", #{path => ~"/api"})
        )
    ).

serialize_with_max_age_test() ->
    ?assertEqual(
        ~"sid=abc; Max-Age=3600",
        iolist_to_binary(
            cactus_cookie:serialize(~"sid", ~"abc", #{max_age => 3600})
        )
    ).

serialize_with_max_age_zero_test() ->
    ?assertEqual(
        ~"sid=abc; Max-Age=0",
        iolist_to_binary(
            cactus_cookie:serialize(~"sid", ~"abc", #{max_age => 0})
        )
    ).

serialize_with_expires_test() ->
    %% Expires takes a pre-formatted IMF-fixdate / RFC 1123 string.
    ?assertEqual(
        ~"sid=abc; Expires=Wed, 09 Jun 2027 10:18:14 GMT",
        iolist_to_binary(
            cactus_cookie:serialize(~"sid", ~"abc", #{
                expires => ~"Wed, 09 Jun 2027 10:18:14 GMT"
            })
        )
    ).

serialize_with_secure_test() ->
    ?assertEqual(
        ~"sid=abc; Secure",
        iolist_to_binary(
            cactus_cookie:serialize(~"sid", ~"abc", #{secure => true})
        )
    ).

serialize_secure_false_omitted_test() ->
    ?assertEqual(
        ~"sid=abc",
        iolist_to_binary(
            cactus_cookie:serialize(~"sid", ~"abc", #{secure => false})
        )
    ).

serialize_with_http_only_test() ->
    ?assertEqual(
        ~"sid=abc; HttpOnly",
        iolist_to_binary(
            cactus_cookie:serialize(~"sid", ~"abc", #{http_only => true})
        )
    ).

serialize_http_only_false_omitted_test() ->
    ?assertEqual(
        ~"sid=abc",
        iolist_to_binary(
            cactus_cookie:serialize(~"sid", ~"abc", #{http_only => false})
        )
    ).

serialize_with_same_site_strict_test() ->
    ?assertEqual(
        ~"sid=abc; SameSite=Strict",
        iolist_to_binary(
            cactus_cookie:serialize(~"sid", ~"abc", #{same_site => strict})
        )
    ).

serialize_with_same_site_lax_test() ->
    ?assertEqual(
        ~"sid=abc; SameSite=Lax",
        iolist_to_binary(
            cactus_cookie:serialize(~"sid", ~"abc", #{same_site => lax})
        )
    ).

serialize_with_same_site_none_test() ->
    ?assertEqual(
        ~"sid=abc; SameSite=None",
        iolist_to_binary(
            cactus_cookie:serialize(~"sid", ~"abc", #{same_site => none})
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
        iolist_to_binary(cactus_cookie:serialize(~"sid", ~"abc", Opts))
    ).
