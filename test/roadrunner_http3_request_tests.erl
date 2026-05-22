-module(roadrunner_http3_request_tests).
-include_lib("eunit/include/eunit.hrl").

ctx() ->
    #{peer => undefined, scheme => https, request_id => ~"abc123", listener_name => test_listener}.

from(Headers) ->
    roadrunner_http3_request:from_headers(Headers, ~"", ctx()).

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
    {ok, Req} = from(base()),
    ?assertEqual([], maps:get(headers, Req)).

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
    ?assertMatch({ok, _}, from(base() ++ [{~"te", ~"trailers"}])).

te_other_rejected_test() ->
    ?assertEqual({error, connection_specific_header}, from(base() ++ [{~"te", ~"gzip"}])).

regular_header_passthrough_test() ->
    %% Two regular headers exercise the body-recursion of partition_regular/1.
    {ok, Req} = from(base() ++ [{~"x-a", ~"1"}, {~"x-b", ~"2"}]),
    ?assertEqual([{~"x-a", ~"1"}, {~"x-b", ~"2"}], maps:get(headers, Req)).
