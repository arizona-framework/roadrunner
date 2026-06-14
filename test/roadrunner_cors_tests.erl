-module(roadrunner_cors_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_cors).
-define(ALLOWLIST, #{origins => [~"https://app.example.com"]}).
-define(ORIGIN, ~"https://app.example.com").

%% =============================================================================
%% Pure unit tests against `call/3` — no listener, no socket.
%% =============================================================================

%% --- not a CORS request ---

no_origin_passes_through_test() ->
    Req = req(~"GET", []),
    Next = fun(R) -> {{200, [{~"x", ~"y"}], ~"body"}, R} end,
    {{200, Headers, ~"body"}, _Req2} = call(Req, Next, ?ALLOWLIST),
    %% Untouched: no Access-Control / Vary headers added.
    ?assertEqual(undefined, header(~"access-control-allow-origin", Headers)),
    ?assertEqual(undefined, header(~"vary", Headers)).

%% --- simple / actual request ---

allowed_origin_echoes_origin_test() ->
    {Headers, _} = simple(?ORIGIN, ?ALLOWLIST),
    ?assertEqual(?ORIGIN, header(~"access-control-allow-origin", Headers)),
    ?assertEqual(~"Origin", header(~"vary", Headers)).

disallowed_origin_has_no_acao_but_vary_test() ->
    {Headers, _} = simple(~"https://evil.example.com", ?ALLOWLIST),
    ?assertEqual(undefined, header(~"access-control-allow-origin", Headers)),
    %% Vary: Origin even when disallowed, so a cache never cross-serves.
    ?assertEqual(~"Origin", header(~"vary", Headers)).

origins_any_without_credentials_is_wildcard_test() ->
    {Headers, _} = simple(?ORIGIN, #{origins => any}),
    ?assertEqual(~"*", header(~"access-control-allow-origin", Headers)).

origins_any_with_credentials_echoes_concrete_test() ->
    {Headers, _} = simple(?ORIGIN, #{origins => any, credentials => true}),
    %% `*` is invalid with credentials — echo the concrete origin instead.
    ?assertEqual(?ORIGIN, header(~"access-control-allow-origin", Headers)),
    ?assertEqual(~"true", header(~"access-control-allow-credentials", Headers)).

origins_predicate_allows_test() ->
    Pred = fun(O) -> O =:= ?ORIGIN end,
    {Headers, _} = simple(?ORIGIN, #{origins => Pred}),
    ?assertEqual(?ORIGIN, header(~"access-control-allow-origin", Headers)).

origins_predicate_denies_test() ->
    Pred = fun(_) -> false end,
    {Headers, _} = simple(?ORIGIN, #{origins => Pred}),
    ?assertEqual(undefined, header(~"access-control-allow-origin", Headers)),
    ?assertEqual(~"Origin", header(~"vary", Headers)).

expose_headers_test() ->
    {Headers, _} = simple(?ORIGIN, cfg(#{expose => [~"x-total-count", ~"x-page"]})),
    ?assertEqual(~"x-total-count, x-page", header(~"access-control-expose-headers", Headers)).

expose_empty_omits_header_test() ->
    {Headers, _} = simple(?ORIGIN, ?ALLOWLIST),
    ?assertEqual(undefined, header(~"access-control-expose-headers", Headers)).

vary_appended_to_existing_test() ->
    Req = req(~"GET", [{~"origin", ?ORIGIN}]),
    Next = fun(R) -> {{200, [{~"vary", ~"Accept-Encoding"}], ~"b"}, R} end,
    {{200, Headers, _}, _} = call(Req, Next, ?ALLOWLIST),
    ?assertEqual(~"Accept-Encoding, Origin", header(~"vary", Headers)).

handler_acao_wins_test() ->
    Req = req(~"GET", [{~"origin", ?ORIGIN}]),
    Next = fun(R) -> {{200, [{~"access-control-allow-origin", ~"https://other"}], ~"b"}, R} end,
    {{200, Headers, _}, _} = call(Req, Next, #{origins => any}),
    ?assertEqual([~"https://other"], [V || {~"access-control-allow-origin", V} <- Headers]).

%% --- response shapes ---

stream_response_decorated_test() ->
    Req = req(~"GET", [{~"origin", ?ORIGIN}]),
    Fun = fun(_Send) -> ok end,
    Next = fun(R) -> {{stream, 200, [], Fun}, R} end,
    {{stream, 200, Headers, OutFun}, _} = call(Req, Next, ?ALLOWLIST),
    ?assertEqual(Fun, OutFun),
    ?assertEqual(?ORIGIN, header(~"access-control-allow-origin", Headers)).

sendfile_response_decorated_test() ->
    Req = req(~"GET", [{~"origin", ?ORIGIN}]),
    Spec = {~"/tmp/x", 0, 10},
    Next = fun(R) -> {{sendfile, 200, [], Spec}, R} end,
    {{sendfile, 200, Headers, OutSpec}, _} = call(Req, Next, ?ALLOWLIST),
    ?assertEqual(Spec, OutSpec),
    ?assertEqual(?ORIGIN, header(~"access-control-allow-origin", Headers)).

loop_response_decorated_test() ->
    Req = req(~"GET", [{~"origin", ?ORIGIN}]),
    Next = fun(R) -> {{loop, 200, [], loop_state}, R} end,
    {{loop, 200, Headers, OutState}, _} = call(Req, Next, ?ALLOWLIST),
    ?assertEqual(loop_state, OutState),
    ?assertEqual(?ORIGIN, header(~"access-control-allow-origin", Headers)).

websocket_passes_through_test() ->
    Req = req(~"GET", [{~"origin", ?ORIGIN}]),
    Next = fun(R) -> {{websocket, some_mod, init_state}, R} end,
    {Response, _} = call(Req, Next, ?ALLOWLIST),
    ?assertMatch({websocket, some_mod, init_state}, Response).

%% --- preflight ---

preflight_allowed_test() ->
    {Status, Headers} = preflight(?ORIGIN, ~"POST", [], ?ALLOWLIST),
    ?assertEqual(204, Status),
    ?assertEqual(?ORIGIN, header(~"access-control-allow-origin", Headers)),
    ?assertEqual(~"GET, HEAD, POST", header(~"access-control-allow-methods", Headers)),
    ?assertEqual(~"Origin", header(~"vary", Headers)).

preflight_short_circuits_without_calling_next_test() ->
    %% A Next that crashes if called proves the handler is never reached.
    Req = req(~"OPTIONS", [
        {~"origin", ?ORIGIN}, {~"access-control-request-method", ~"POST"}
    ]),
    Next = fun(_R) -> error(next_must_not_run) end,
    {{204, _Headers, ~""}, _} = call(Req, Next, ?ALLOWLIST).

preflight_disallowed_has_only_vary_test() ->
    {Status, Headers} = preflight(~"https://evil.example.com", ~"POST", [], ?ALLOWLIST),
    ?assertEqual(204, Status),
    ?assertEqual(undefined, header(~"access-control-allow-origin", Headers)),
    ?assertEqual(~"Origin", header(~"vary", Headers)).

preflight_reflects_requested_headers_test() ->
    {204, Headers} = preflight(
        ?ORIGIN,
        ~"POST",
        [{~"access-control-request-headers", ~"content-type, authorization"}],
        cfg(#{headers => reflect})
    ),
    ?assertEqual(
        ~"content-type, authorization", header(~"access-control-allow-headers", Headers)
    ).

preflight_reflect_without_request_headers_omits_test() ->
    {204, Headers} = preflight(?ORIGIN, ~"POST", [], cfg(#{headers => reflect})),
    ?assertEqual(undefined, header(~"access-control-allow-headers", Headers)).

preflight_headers_list_test() ->
    {204, Headers} = preflight(
        ?ORIGIN, ~"POST", [], cfg(#{headers => [~"content-type", ~"x-api-key"]})
    ),
    ?assertEqual(~"content-type, x-api-key", header(~"access-control-allow-headers", Headers)).

preflight_max_age_test() ->
    {204, Headers} = preflight(?ORIGIN, ~"POST", [], cfg(#{max_age => 600})),
    ?assertEqual(~"600", header(~"access-control-max-age", Headers)).

preflight_credentials_test() ->
    {204, Headers} = preflight(?ORIGIN, ~"POST", [], #{origins => any, credentials => true}),
    ?assertEqual(~"true", header(~"access-control-allow-credentials", Headers)),
    ?assertEqual(?ORIGIN, header(~"access-control-allow-origin", Headers)).

preflight_empty_methods_test() ->
    {204, Headers} = preflight(?ORIGIN, ~"POST", [], cfg(#{methods => []})),
    ?assertEqual(~"", header(~"access-control-allow-methods", Headers)).

options_without_request_method_is_not_preflight_test() ->
    %% An `OPTIONS` lacking `Access-Control-Request-Method` is a normal request,
    %% not a preflight: the handler runs and gets the actual-request headers.
    Req = req(~"OPTIONS", [{~"origin", ?ORIGIN}]),
    Next = fun(R) -> {{200, [], ~"handled"}, R} end,
    {{200, Headers, ~"handled"}, _} = call(Req, Next, ?ALLOWLIST),
    ?assertEqual(?ORIGIN, header(~"access-control-allow-origin", Headers)).

%% --- header injection guard ---

unsafe_origin_crashes_test() ->
    %% An attacker-controlled origin carrying CR/LF must not reach the wire.
    Req = req(~"GET", [{~"origin", <<"https://evil\r\nx-injected: 1">>}]),
    Next = fun(R) -> {{200, [], ~"b"}, R} end,
    ?assertError({header_injection, value, _}, call(Req, Next, #{origins => any})).

%% --- config validation ---

missing_origins_crashes_test() ->
    ?assertError({invalid_cors_opt, origins, undefined}, simple(?ORIGIN, #{})).

bad_origins_type_crashes_test() ->
    ?assertError({invalid_cors_opt, origins, not_valid}, simple(?ORIGIN, #{origins => not_valid})).

bad_origins_charlist_crashes_test() ->
    %% A charlist is a common slip for `[~"..."]`; reject it loudly.
    ?assertError(
        {invalid_cors_opt, origins, "https://app.example.com"},
        simple(?ORIGIN, #{origins => "https://app.example.com"})
    ).

bad_methods_crashes_test() ->
    ?assertError(
        {invalid_cors_opt, methods, get},
        preflight(?ORIGIN, ~"POST", [], cfg(#{methods => get}))
    ).

bad_headers_crashes_test() ->
    ?assertError(
        {invalid_cors_opt, headers, 123},
        preflight(?ORIGIN, ~"POST", [], cfg(#{headers => 123}))
    ).

bad_expose_crashes_test() ->
    ?assertError(
        {invalid_cors_opt, expose, all}, simple(?ORIGIN, cfg(#{expose => all}))
    ).

bad_credentials_crashes_test() ->
    ?assertError(
        {invalid_cors_opt, credentials, yes}, simple(?ORIGIN, cfg(#{credentials => yes}))
    ).

bad_max_age_crashes_test() ->
    ?assertError(
        {invalid_cors_opt, max_age, -1},
        preflight(?ORIGIN, ~"POST", [], cfg(#{max_age => -1}))
    ).

%% =============================================================================
%% End-to-end through roadrunner_listener.
%% =============================================================================

end_to_end_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(cors_e2e, #{
                port => 0,
                routes => roadrunner_hello_handler,
                middlewares => [{roadrunner_cors, #{origins => [~"https://app.example.com"]}}]
            }),
            roadrunner_listener:port(cors_e2e)
        end,
        fun(_) -> ok = roadrunner_listener:stop(cors_e2e) end, fun(Port) ->
            [
                {"cross-origin GET echoes the allowed origin and varies on it", fun() ->
                    Reply = request(Port, [
                        ~"GET / HTTP/1.1\r\n",
                        ~"Host: x\r\n",
                        ~"Origin: https://app.example.com\r\n",
                        ~"Connection: close\r\n\r\n"
                    ]),
                    {match, _} = re:run(
                        Reply, ~"access-control-allow-origin: https://app.example.com", [caseless]
                    ),
                    {match, _} = re:run(Reply, ~"vary: Origin", [caseless])
                end},
                {"OPTIONS preflight short-circuits with 204 and the allow set", fun() ->
                    Reply = request(Port, [
                        ~"OPTIONS / HTTP/1.1\r\n",
                        ~"Host: x\r\n",
                        ~"Origin: https://app.example.com\r\n",
                        ~"Access-Control-Request-Method: POST\r\n",
                        ~"Connection: close\r\n\r\n"
                    ]),
                    ?assertMatch(<<"HTTP/1.1 204", _/binary>>, Reply),
                    {match, _} = re:run(
                        Reply, ~"access-control-allow-origin: https://app.example.com", [caseless]
                    ),
                    {match, _} = re:run(Reply, ~"access-control-allow-methods:", [caseless])
                end}
            ]
        end}.

%% --- helpers ---

%% Compile the config through `init/1` (as the pipeline does at startup), then
%% invoke `call/3` with the resulting state — the contract every test exercises.
%% A bad config raises `{invalid_cors_opt, ...}` from `init/1` here, which the
%% config-validation tests assert on.
call(Req, Next, Config) ->
    ?M:call(Req, Next, ?M:init(Config)).

%% Allowlist config with `Extra` merged in. Updates the `Extra` variable (not a
%% literal map) so the compiler's update-literal warning doesn't fire.
cfg(Extra) ->
    Extra#{origins => [?ORIGIN]}.

%% Run a simple (non-preflight) GET with the given origin and config; returns
%% the response headers and request.
simple(Origin, Config) ->
    Req = req(~"GET", [{~"origin", Origin}]),
    Next = fun(R) -> {{200, [], ~"body"}, R} end,
    {{200, Headers, ~"body"}, Req2} = call(Req, Next, Config),
    {Headers, Req2}.

%% Run a preflight OPTIONS; returns the response status and headers. The Next
%% crashes if called, asserting the short-circuit.
preflight(Origin, RequestMethod, ExtraHeaders, Config) ->
    Req = req(~"OPTIONS", [
        {~"origin", Origin}, {~"access-control-request-method", RequestMethod} | ExtraHeaders
    ]),
    Next = fun(_R) -> error(next_must_not_run) end,
    {{Status, Headers, ~""}, _} = call(Req, Next, Config),
    {Status, Headers}.

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

request(Port, IoData) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Sock, IoData),
    Reply = recv_all(Sock, <<>>),
    ok = gen_tcp:close(Sock),
    Reply.

recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 1000) of
        {ok, Data} -> recv_all(Sock, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.
