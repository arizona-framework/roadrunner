-module(roadrunner_etag_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Pure unit tests against `call/3` — no listener, no socket.
%% =============================================================================

adds_weak_etag_when_absent_test() ->
    Req = req(~"GET", []),
    Next = fun(R) -> {{200, [{~"content-type", ~"application/json"}], ~"{}"}, R} end,
    {{200, Headers, Body}, _} = roadrunner_etag:call(Req, Next, undefined),
    ?assertMatch(<<"W/\"", _/binary>>, header(~"etag", Headers)),
    %% Body is passed through unchanged.
    ?assertEqual(~"{}", iolist_to_binary(Body)).

matching_if_none_match_returns_304_test() ->
    Body = ~"hello",
    ETag = etag_of(Body),
    Req = req(~"GET", [{~"if-none-match", ETag}]),
    Next = fun(R) -> {{200, [{~"content-type", ~"text/plain"}], Body}, R} end,
    {{Status, Headers, RespBody}, _} = roadrunner_etag:call(Req, Next, undefined),
    ?assertEqual(304, Status),
    ?assertEqual(ETag, header(~"etag", Headers)),
    ?assertEqual(~"", iolist_to_binary(RespBody)),
    ?assertEqual(~"0", header(~"content-length", Headers)),
    %% A 304 has no body, so the body's Content-Type is dropped.
    ?assertEqual(undefined, header(~"content-type", Headers)).

%% RFC 7232 §2.3.2 weak comparison: a client echoing the tag without the
%% `W/` prefix (strong form) still revalidates.
strong_form_matches_weak_etag_test() ->
    Body = ~"hello",
    <<"W/", Quoted/binary>> = etag_of(Body),
    Req = req(~"GET", [{~"if-none-match", Quoted}]),
    Next = fun(R) -> {{200, [], Body}, R} end,
    {{Status, _, _}, _} = roadrunner_etag:call(Req, Next, undefined),
    ?assertEqual(304, Status).

star_if_none_match_returns_304_test() ->
    Req = req(~"GET", [{~"if-none-match", ~"*"}]),
    Next = fun(R) -> {{200, [], ~"x"}, R} end,
    {{Status, _, _}, _} = roadrunner_etag:call(Req, Next, undefined),
    ?assertEqual(304, Status).

if_none_match_list_returns_304_test() ->
    %% A comma-separated list where the second entry matches.
    Body = ~"hello",
    ETag = etag_of(Body),
    Req = req(~"GET", [{~"if-none-match", <<"\"other\", ", ETag/binary>>}]),
    Next = fun(R) -> {{200, [], Body}, R} end,
    {{Status, _, _}, _} = roadrunner_etag:call(Req, Next, undefined),
    ?assertEqual(304, Status).

non_matching_if_none_match_returns_200_test() ->
    Req = req(~"GET", [{~"if-none-match", ~"\"nope\""}]),
    Next = fun(R) -> {{200, [], ~"hello"}, R} end,
    {{Status, Headers, _}, _} = roadrunner_etag:call(Req, Next, undefined),
    ?assertEqual(200, Status),
    ?assertMatch(<<"W/\"", _/binary>>, header(~"etag", Headers)).

%% A malformed If-None-Match with no quoted entity-tag matches nothing.
unquoted_if_none_match_returns_200_test() ->
    Req = req(~"GET", [{~"if-none-match", ~"bogus"}]),
    Next = fun(R) -> {{200, [], ~"hello"}, R} end,
    {{Status, _, _}, _} = roadrunner_etag:call(Req, Next, undefined),
    ?assertEqual(200, Status).

handler_etag_is_honored_for_match_test() ->
    Strong = ~"\"v1\"",
    Req = req(~"GET", [{~"if-none-match", Strong}]),
    Next = fun(R) -> {{200, [{~"etag", Strong}], ~"body"}, R} end,
    {{Status, _, _}, _} = roadrunner_etag:call(Req, Next, undefined),
    ?assertEqual(304, Status).

handler_etag_not_overwritten_test() ->
    Strong = ~"\"v1\"",
    Req = req(~"GET", []),
    Next = fun(R) -> {{200, [{~"etag", Strong}], ~"body"}, R} end,
    {{200, Headers, _}, _} = roadrunner_etag:call(Req, Next, undefined),
    ?assertEqual(Strong, header(~"etag", Headers)).

head_request_matching_returns_304_test() ->
    Body = ~"hello",
    ETag = etag_of(Body),
    Req = req(~"HEAD", [{~"if-none-match", ETag}]),
    Next = fun(R) -> {{200, [], Body}, R} end,
    {{Status, _, _}, _} = roadrunner_etag:call(Req, Next, undefined),
    ?assertEqual(304, Status).

%% A non-safe method gets no ETag and no 304: ETag/If-None-Match caching is
%% for GET / HEAD.
post_passes_through_test() ->
    Req = req(~"POST", [{~"if-none-match", ~"\"x\""}]),
    Next = fun(R) -> {{200, [], ~"created"}, R} end,
    {{Status, Headers, _}, _} = roadrunner_etag:call(Req, Next, undefined),
    ?assertEqual(200, Status),
    ?assertEqual(undefined, header(~"etag", Headers)).

non_200_passes_through_test() ->
    Req = req(~"GET", []),
    Next = fun(R) -> {{404, [{~"content-type", ~"text/plain"}], ~"nope"}, R} end,
    {{Status, Headers, _}, _} = roadrunner_etag:call(Req, Next, undefined),
    ?assertEqual(404, Status),
    ?assertEqual(undefined, header(~"etag", Headers)).

stream_response_passes_through_test() ->
    Fun = fun(_Send) -> ok end,
    Req = req(~"GET", []),
    Next = fun(R) -> {{stream, 200, [], Fun}, R} end,
    {Response, _} = roadrunner_etag:call(Req, Next, undefined),
    ?assertMatch({stream, 200, [], _}, Response).

%% A 304 echoes cache-relevant headers (Cache-Control) while dropping the
%% body's Content-Type and zeroing Content-Length (RFC 7232 §4.1).
not_modified_keeps_cache_headers_test() ->
    Body = ~"hello",
    ETag = etag_of(Body),
    Req = req(~"GET", [{~"if-none-match", ETag}]),
    Next = fun(R) ->
        {{200, [{~"content-type", ~"text/plain"}, {~"cache-control", ~"max-age=60"}], Body}, R}
    end,
    {{304, Headers, _}, _} = roadrunner_etag:call(Req, Next, undefined),
    ?assertEqual(~"max-age=60", header(~"cache-control", Headers)),
    ?assertEqual(undefined, header(~"content-type", Headers)),
    ?assertEqual(~"0", header(~"content-length", Headers)).

%% =============================================================================
%% Wired as a middleware — `compose/2` runs etag's stateless `init/1` once at
%% compile time, then `call/3` per request, same conditional behavior.
%% =============================================================================

composed_pipeline_runs_init_then_handles_conditional_test() ->
    Body = ~"hello",
    Handler = fun(R) -> {{200, [{~"content-type", ~"text/plain"}], Body}, R} end,
    Pipeline = roadrunner_middleware:compose([roadrunner_etag], Handler),
    %% No If-None-Match → 200 carrying the derived weak ETag.
    {{200, H200, Body}, _} = Pipeline(req(~"GET", [])),
    ETag = header(~"etag", H200),
    ?assertMatch(<<"W/\"", _/binary>>, ETag),
    %% Echoing the ETag → 304, so init's state threaded into call/3.
    {{304, _, RespBody}, _} = Pipeline(req(~"GET", [{~"if-none-match", ETag}])),
    ?assertEqual(~"", iolist_to_binary(RespBody)).

%% --- helpers ---

req(Method, Headers) ->
    #{
        method => Method,
        target => ~"/",
        version => {1, 1},
        headers => Headers
    }.

header(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, V} -> V;
        false -> undefined
    end.

%% The ETag the middleware derives for `Body` (run it with no If-None-Match
%% and read the header back), so match tests need not hardcode a digest.
etag_of(Body) ->
    Next = fun(R) -> {{200, [], Body}, R} end,
    {{200, Headers, _}, _} = roadrunner_etag:call(req(~"GET", []), Next, undefined),
    header(~"etag", Headers).
