-module(roadrunner_http3_request_tests).
-include_lib("eunit/include/eunit.hrl").

ctx() ->
    #{peer => undefined, scheme => https, request_id => ~"abc123", listener_name => test_listener}.

from(Headers) ->
    roadrunner_http3_request:from_headers(Headers, ~"", ctx()).

from(Headers, Body) ->
    roadrunner_http3_request:from_headers(Headers, Body, ctx()).

base() ->
    [{~":method", ~"GET"}, {~":scheme", ~"https"}, {~":path", ~"/"}].

build_ok_test() ->
    Headers = [
        {~":method", ~"POST"},
        {~":scheme", ~"https"},
        {~":path", ~"/x"},
        {~":authority", ~"example.com"},
        {~"accept", ~"*/*"}
    ],
    {ok, Req} = roadrunner_http3_request:from_headers(Headers, ~"body", ctx()),
    ?assertEqual(~"POST", maps:get(method, Req)),
    ?assertEqual(~"/x", maps:get(target, Req)),
    ?assertEqual({3, 0}, maps:get(version, Req)),
    ?assertEqual(https, maps:get(scheme, Req)),
    ?assertEqual(~"body", maps:get(body, Req)),
    ?assertEqual(~"abc123", maps:get(request_id, Req)),
    %% :authority forwarded as a prepended host header.
    ?assertEqual([{~"host", ~"example.com"}, {~"accept", ~"*/*"}], maps:get(headers, Req)).

build_without_authority_test() ->
    %% No :authority pseudo, but a Host header supplies the mandatory authority
    %% component (RFC 9114 §4.3.1), so the request is valid and Host passes
    %% through unchanged.
    {ok, Req} = from(base() ++ [{~"host", ~"example.com"}]),
    ?assertEqual([{~"host", ~"example.com"}], maps:get(headers, Req)).

missing_pseudo_test() ->
    ?assertEqual(
        {error, missing_pseudo_header}, from([{~":method", ~"GET"}, {~":scheme", ~"https"}])
    ).

duplicate_pseudo_test() ->
    ?assertEqual(
        {error, duplicate_pseudo_header},
        from([{~":method", ~"GET"}, {~":method", ~"POST"}, {~":scheme", ~"https"}, {~":path", ~"/"}])
    ).

unknown_pseudo_test() ->
    ?assertEqual(
        {error, unknown_pseudo_header},
        from([{~":method", ~"GET"}, {~":bogus", ~"x"}, {~":scheme", ~"https"}, {~":path", ~"/"}])
    ).

pseudo_after_regular_test() ->
    %% Two regular headers before the stray pseudo so the error
    %% propagates back up through partition_regular/1's recursion.
    ?assertEqual(
        {error, pseudo_after_regular},
        from(base() ++ [{~"x-a", ~"1"}, {~"x-b", ~"2"}, {~":authority", ~"h"}])
    ).

empty_path_test() ->
    ?assertEqual(
        {error, empty_path},
        from([{~":method", ~"GET"}, {~":scheme", ~"https"}, {~":path", ~""}])
    ).

banned_headers_test() ->
    lists:foreach(
        fun(Name) ->
            ?assertEqual(
                {error, connection_specific_header},
                from(base() ++ [{Name, ~"x"}])
            )
        end,
        [~"connection", ~"keep-alive", ~"proxy-connection", ~"transfer-encoding", ~"upgrade"]
    ).

te_trailers_allowed_test() ->
    ?assertMatch({ok, _}, from(base() ++ [{~":authority", ~"h"}, {~"te", ~"trailers"}])).

te_other_rejected_test() ->
    ?assertEqual({error, connection_specific_header}, from(base() ++ [{~"te", ~"gzip"}])).

regular_header_passthrough_test() ->
    %% Two regular headers exercise the body-recursion of partition_regular/1;
    %% a Host header supplies the mandatory authority component.
    {ok, Req} = from(base() ++ [{~"host", ~"h"}, {~"x-a", ~"1"}, {~"x-b", ~"2"}]),
    ?assertEqual([{~"host", ~"h"}, {~"x-a", ~"1"}, {~"x-b", ~"2"}], maps:get(headers, Req)).

%% =============================================================================
%% RFC 9114 §4.3.1 authority, §4.1.2 content-length, §4.2 uppercase names
%% =============================================================================

missing_authority_test() ->
    %% Neither :authority nor Host: malformed (https has a mandatory authority).
    ?assertEqual({error, missing_authority}, from(base())).

empty_authority_pseudo_test() ->
    ?assertEqual({error, empty_authority}, from(base() ++ [{~":authority", ~""}])).

empty_host_header_test() ->
    ?assertEqual({error, empty_authority}, from(base() ++ [{~"host", ~""}])).

authority_host_match_test() ->
    %% Both present and equal is valid; the duplicate host header is collapsed
    %% to a single canonical entry.
    {ok, Req} = from(base() ++ [{~":authority", ~"example.com"}, {~"host", ~"example.com"}]),
    ?assertEqual([{~"host", ~"example.com"}], maps:get(headers, Req)).

authority_host_mismatch_test() ->
    ?assertEqual(
        {error, authority_mismatch},
        from(base() ++ [{~":authority", ~"a.com"}, {~"host", ~"b.com"}])
    ).

uppercase_field_name_test() ->
    %% RFC 9114 §4.2: an uppercase field name makes the request malformed (the
    %% banned-header scan catches it before the authority check).
    ?assertEqual({error, uppercase_field_name}, from(base() ++ [{~"X-Custom", ~"v"}])).

mixedcase_value_allowed_test() ->
    %% Only field NAMES are case-checked; an uppercase VALUE is fine.
    ?assertMatch({ok, _}, from(base() ++ [{~"host", ~"h"}, {~"x-token", ~"AbC123"}])).

content_length_match_test() ->
    ?assertMatch(
        {ok, _},
        from(base() ++ [{~"host", ~"h"}, {~"content-length", ~"5"}], ~"abcde")
    ).

content_length_mismatch_test() ->
    ?assertEqual(
        {error, content_length_mismatch},
        from(base() ++ [{~"content-length", ~"5"}], ~"abc")
    ).

content_length_non_integer_test() ->
    ?assertEqual(
        {error, content_length_mismatch},
        from(base() ++ [{~"content-length", ~"banana"}], ~"")
    ).

content_length_multi_valued_test() ->
    ?assertEqual(
        {error, content_length_mismatch},
        from(base() ++ [{~"content-length", ~"5"}, {~"content-length", ~"5"}], ~"abcde")
    ).
