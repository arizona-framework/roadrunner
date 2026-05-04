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
    {ok, Req} = roadrunner_http2_request:from_headers(Headers, <<>>, conn_info()),
    ?assertEqual(~"GET", maps:get(method, Req)),
    ?assertEqual(~"/", maps:get(target, Req)),
    ?assertEqual({2, 0}, maps:get(version, Req)),
    %% `:authority` is forwarded as `host`.
    ?assertEqual(~"example.com", proplists:get_value(~"host", maps:get(headers, Req))).

post_with_body_test() ->
    Headers = [
        {~":method", ~"POST"},
        {~":scheme", ~"https"},
        {~":path", ~"/api"},
        {~"content-type", ~"application/json"}
    ],
    Body = ~"{\"hello\":\"world\"}",
    {ok, Req} = roadrunner_http2_request:from_headers(Headers, Body, conn_info()),
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
        {~"x-2", ~"b"},
        {~"x-3", ~"c"}
    ],
    {ok, Req} = roadrunner_http2_request:from_headers(Headers, <<>>, conn_info()),
    %% No `:authority` so no synthesised `host` header is prepended.
    ?assertEqual(
        [{~"x-1", ~"a"}, {~"x-2", ~"b"}, {~"x-3", ~"c"}],
        maps:get(headers, Req)
    ).

missing_method_is_error_test() ->
    Headers = [
        {~":scheme", ~"https"},
        {~":path", ~"/"}
    ],
    ?assertEqual(
        {error, missing_pseudo_header},
        roadrunner_http2_request:from_headers(Headers, <<>>, conn_info())
    ).

missing_path_is_error_test() ->
    Headers = [
        {~":method", ~"GET"},
        {~":scheme", ~"https"}
    ],
    ?assertEqual(
        {error, missing_pseudo_header},
        roadrunner_http2_request:from_headers(Headers, <<>>, conn_info())
    ).

empty_path_is_error_test() ->
    Headers = [
        {~":method", ~"GET"},
        {~":scheme", ~"https"},
        {~":path", ~""}
    ],
    ?assertEqual(
        {error, empty_path},
        roadrunner_http2_request:from_headers(Headers, <<>>, conn_info())
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
        roadrunner_http2_request:from_headers(Headers, <<>>, conn_info())
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
        roadrunner_http2_request:from_headers(Headers, <<>>, conn_info())
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
        roadrunner_http2_request:from_headers(Headers, <<>>, conn_info())
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
                conn_info()
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
        {~":path", ~"/"},
        {~"te", ~"trailers"}
    ],
    ?assertMatch({ok, _}, roadrunner_http2_request:from_headers(GoodHeaders, <<>>, conn_info())),
    BadHeaders = [
        {~":method", ~"GET"},
        {~":scheme", ~"https"},
        {~":path", ~"/"},
        {~"te", ~"gzip"}
    ],
    ?assertEqual(
        {error, connection_specific_header},
        roadrunner_http2_request:from_headers(BadHeaders, <<>>, conn_info())
    ).

%% --- helpers ---

conn_info() ->
    #{
        peer => {{127, 0, 0, 1}, 12345},
        scheme => https,
        listener_name => h2_test,
        request_id => ~"abc123"
    }.
