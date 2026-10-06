-module(roadrunner_http2_request_tests).
-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Building a request map from HPACK-decoded headers (RFC 9113 §8.3).
%% =============================================================================

minimal_get_test() ->
    Headers = [
        {~":method", ~"GET"},
        {~":scheme", ~"https"},
        {~":authority", ~"example.com"},
        {~":path", ~"/"}
    ],
    {ok, Req} = roadrunner_http2_request:from_headers(Headers, <<>>, request_context()),
    ?assertEqual(~"GET", maps:get(method, Req)),
    ?assertEqual(~"/", maps:get(target, Req)),
    ?assertEqual({2, 0}, maps:get(version, Req)),
    %% `:authority` is forwarded as `host`.
    ?assertEqual(~"example.com", proplists:get_value(~"host", maps:get(headers, Req))).

post_with_body_test() ->
    Headers = [
        {~":method", ~"POST"},
        {~":scheme", ~"https"},
        {~":authority", ~"example.com"},
        {~":path", ~"/api"},
        {~"content-type", ~"application/json"}
    ],
    Body = ~"{\"hello\":\"world\"}",
    {ok, Req} = roadrunner_http2_request:from_headers(Headers, Body, request_context()),
    ?assertEqual(~"POST", maps:get(method, Req)),
    ?assertEqual(Body, maps:get(body, Req)),
    ?assertEqual(
        ~"application/json",
        proplists:get_value(~"content-type", maps:get(headers, Req))
    ).

regular_headers_preserved_in_order_test() ->
    Headers = [
        {~":method", ~"GET"},
        {~":scheme", ~"https"},
        {~":path", ~"/"},
        {~"x-1", ~"a"},
        {~"host", ~"example.com"},
        {~"x-3", ~"c"}
    ],
    {ok, Req} = roadrunner_http2_request:from_headers(Headers, <<>>, request_context()),
    %% No `:authority`: the client's `host` carries the authority, and
    %% nothing is synthesised in front of the headers.
    ?assertEqual(
        [{~"x-1", ~"a"}, {~"host", ~"example.com"}, {~"x-3", ~"c"}],
        maps:get(headers, Req)
    ).

missing_method_is_error_test() ->
    Headers = [
        {~":scheme", ~"https"},
        {~":path", ~"/"}
    ],
    ?assertEqual(
        {error, missing_pseudo_header},
        roadrunner_http2_request:from_headers(Headers, <<>>, request_context())
    ).

missing_path_is_error_test() ->
    Headers = [
        {~":method", ~"GET"},
        {~":scheme", ~"https"}
    ],
    ?assertEqual(
        {error, missing_pseudo_header},
        roadrunner_http2_request:from_headers(Headers, <<>>, request_context())
    ).

empty_path_is_error_test() ->
    Headers = [
        {~":method", ~"GET"},
        {~":scheme", ~"https"},
        {~":path", ~""}
    ],
    ?assertEqual(
        {error, empty_path},
        roadrunner_http2_request:from_headers(Headers, <<>>, request_context())
    ).

duplicate_pseudo_is_error_test() ->
    Headers = [
        {~":method", ~"GET"},
        {~":method", ~"POST"},
        {~":scheme", ~"https"},
        {~":path", ~"/"}
    ],
    ?assertEqual(
        {error, duplicate_pseudo_header},
        roadrunner_http2_request:from_headers(Headers, <<>>, request_context())
    ).

unknown_pseudo_is_error_test() ->
    Headers = [
        {~":bogus", ~"x"},
        {~":method", ~"GET"},
        {~":scheme", ~"https"},
        {~":path", ~"/"}
    ],
    ?assertEqual(
        {error, unknown_pseudo_header},
        roadrunner_http2_request:from_headers(Headers, <<>>, request_context())
    ).

pseudo_after_regular_is_error_test() ->
    Headers = [
        {~":method", ~"GET"},
        {~"x-custom", ~"yes"},
        {~":scheme", ~"https"},
        {~":path", ~"/"}
    ],
    ?assertEqual(
        {error, pseudo_after_regular},
        roadrunner_http2_request:from_headers(Headers, <<>>, request_context())
    ).

pseudo_after_multiple_regulars_is_error_test() ->
    %% Same error class as above, but the pseudo arrives DEEPER in
    %% the regular tail so `partition_regular/1` recurses past
    %% several non-pseudo entries before tripping. Exercises the
    %% error-propagation arm of the regular-walk recursion.
    Headers = [
        {~":method", ~"GET"},
        {~"x-a", ~"1"},
        {~"x-b", ~"2"},
        {~"x-c", ~"3"},
        {~":scheme", ~"https"},
        {~":path", ~"/"}
    ],
    ?assertEqual(
        {error, pseudo_after_regular},
        roadrunner_http2_request:from_headers(Headers, <<>>, request_context())
    ).

connection_specific_header_is_error_test() ->
    %% RFC 9113 §8.2.2: `Connection` and friends MUST NOT appear.
    [
        ?assertEqual(
            {error, connection_specific_header},
            roadrunner_http2_request:from_headers(
                [
                    {~":method", ~"GET"},
                    {~":scheme", ~"https"},
                    {~":path", ~"/"},
                    {Banned, ~"x"}
                ],
                <<>>,
                request_context()
            )
        )
     || Banned <- [
            ~"connection",
            ~"keep-alive",
            ~"proxy-connection",
            ~"transfer-encoding",
            ~"upgrade"
        ]
    ].

te_only_trailers_allowed_test() ->
    GoodHeaders = [
        {~":method", ~"GET"},
        {~":scheme", ~"https"},
        {~":authority", ~"example.com"},
        {~":path", ~"/"},
        {~"te", ~"trailers"}
    ],
    ?assertMatch(
        {ok, _}, roadrunner_http2_request:from_headers(GoodHeaders, <<>>, request_context())
    ),
    BadHeaders = [
        {~":method", ~"GET"},
        {~":scheme", ~"https"},
        {~":path", ~"/"},
        {~"te", ~"gzip"}
    ],
    ?assertEqual(
        {error, connection_specific_header},
        roadrunner_http2_request:from_headers(BadHeaders, <<>>, request_context())
    ).

%% --- authority (RFC 9113 §8.3.1) ---

repeated_host_is_rejected_test() ->
    %% A second `host` could name another entity than the one checked
    %% against `:authority` and still reach the handler.
    Build = fun(Extra) ->
        roadrunner_http2_request:from_headers(
            [{~":method", ~"GET"}, {~":scheme", ~"https"}, {~":path", ~"/"} | Extra],
            <<>>,
            request_context()
        )
    end,
    ?assertEqual(
        {error, duplicate_host},
        Build([{~":authority", ~"a"}, {~"host", ~"a"}, {~"host", ~"evil"}])
    ),
    ?assertEqual({error, duplicate_host}, Build([{~"host", ~"a"}, {~"host", ~"evil"}])).

authority_rules_test() ->
    %% An https request MUST carry `:authority` or `host`, neither empty,
    %% and naming the same entity when both are present.
    Build = fun(Extra) ->
        roadrunner_http2_request:from_headers(
            [{~":method", ~"GET"}, {~":scheme", ~"https"}, {~":path", ~"/"} | Extra],
            <<>>,
            request_context()
        )
    end,
    ?assertEqual({error, missing_authority}, Build([])),
    ?assertEqual({error, empty_authority}, Build([{~":authority", ~""}])),
    ?assertEqual({error, empty_authority}, Build([{~"host", ~""}])),
    ?assertEqual(
        {error, authority_mismatch},
        Build([{~":authority", ~"a.example"}, {~"host", ~"b.example"}])
    ).

authority_and_host_naming_one_entity_test() ->
    %% RFC 9113 §8.3.1 compares the two after RFC 3986 §6.2 normalization:
    %% the host is case-insensitive and the scheme's default port (or an
    %% empty one) names the same entity as no port.
    Build = fun(Authority, Host) ->
        roadrunner_http2_request:from_headers(
            [
                {~":method", ~"GET"},
                {~":scheme", ~"https"},
                {~":path", ~"/"},
                {~":authority", Authority},
                {~"host", Host}
            ],
            <<>>,
            request_context()
        )
    end,
    ?assertMatch({ok, _}, Build(~"Example.com", ~"example.COM")),
    ?assertMatch({ok, _}, Build(~"example.com:443", ~"example.com")),
    ?assertMatch({ok, _}, Build(~"example.com", ~"example.com:")),
    ?assertEqual({error, authority_mismatch}, Build(~"example.com:80", ~"example.com")).

authority_and_equal_host_leave_one_host_test() ->
    %% A client that sends both gets a single `host`, not a duplicate.
    {ok, Req} = roadrunner_http2_request:from_headers(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"https"},
            {~":authority", ~"example.com"},
            {~":path", ~"/"},
            {~"accept", ~"*/*"},
            {~"host", ~"example.com"}
        ],
        <<>>,
        request_context()
    ),
    ?assertEqual(
        [{~"host", ~"example.com"}, {~"accept", ~"*/*"}], maps:get(headers, Req)
    ).

%% --- helpers ---

request_context() ->
    #{
        peer => {{127, 0, 0, 1}, 12345},
        scheme => https,
        listener_name => h2_test,
        request_id => ~"abc123"
    }.
