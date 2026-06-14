-module(roadrunner_security_headers_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_security_headers).

%% =============================================================================
%% Pure unit tests against `call/3` — no listener, no socket.
%% =============================================================================

defaults_added_on_buffered_http_test() ->
    Req = req(http, []),
    Next = fun(R) -> {{200, [], ~"body"}, R} end,
    {{200, Headers, ~"body"}, _Req2} = call(Req, Next, #{}),
    ?assertEqual(~"nosniff", header(~"x-content-type-options", Headers)),
    ?assertEqual(~"SAMEORIGIN", header(~"x-frame-options", Headers)),
    ?assertEqual(~"strict-origin-when-cross-origin", header(~"referrer-policy", Headers)),
    %% HSTS only on HTTPS; CSP is opt-in.
    ?assertEqual(undefined, header(~"strict-transport-security", Headers)),
    ?assertEqual(undefined, header(~"content-security-policy", Headers)).

hsts_off_by_default_on_https_test() ->
    %% HSTS is opt-in even over HTTPS: the bare middleware does not commit the
    %% host to HTTPS-only. The reversible defaults are still applied.
    Req = req(https, []),
    Next = fun(R) -> {{200, [], ~"body"}, R} end,
    {{200, Headers, _}, _Req2} = call(Req, Next, #{}),
    ?assertEqual(undefined, header(~"strict-transport-security", Headers)),
    ?assertEqual(~"nosniff", header(~"x-content-type-options", Headers)).

hsts_enabled_with_true_on_https_test() ->
    Req = req(https, []),
    Next = fun(R) -> {{200, [], ~"body"}, R} end,
    {{200, Headers, _}, _Req2} = call(Req, Next, #{hsts => true}),
    ?assertEqual(
        ~"max-age=31536000; includeSubDomains",
        header(~"strict-transport-security", Headers)
    ).

hsts_not_emitted_over_http_even_when_enabled_test() ->
    %% Enabled, but the connection is plain HTTP — no HSTS (RFC 6797 §8.1).
    Req = req(http, []),
    Next = fun(R) -> {{200, [], ~"body"}, R} end,
    {{200, Headers, _}, _Req2} = call(Req, Next, #{hsts => true}),
    ?assertEqual(undefined, header(~"strict-transport-security", Headers)).

handler_header_wins_test() ->
    %% Handler already set x-frame-options — the middleware must not override
    %% or duplicate it.
    Req = req(http, []),
    Next = fun(R) -> {{200, [{~"x-frame-options", ~"DENY"}], ~"b"}, R} end,
    {{200, Headers, _}, _Req2} = call(Req, Next, #{}),
    ?assertEqual([~"DENY"], [V || {~"x-frame-options", V} <- Headers]),
    %% The other defaults still get added.
    ?assertEqual(~"nosniff", header(~"x-content-type-options", Headers)).

handler_hsts_wins_test() ->
    Req = req(https, []),
    Next = fun(R) -> {{200, [{~"strict-transport-security", ~"max-age=0"}], ~"b"}, R} end,
    {{200, Headers, _}, _Req2} = call(Req, Next, #{hsts => true}),
    ?assertEqual([~"max-age=0"], [V || {~"strict-transport-security", V} <- Headers]).

override_value_test() ->
    Req = req(http, []),
    Config = #{frame_options => ~"DENY", referrer_policy => ~"no-referrer"},
    Next = fun(R) -> {{200, [], ~"b"}, R} end,
    {{200, Headers, _}, _Req2} = call(Req, Next, Config),
    ?assertEqual(~"DENY", header(~"x-frame-options", Headers)),
    ?assertEqual(~"no-referrer", header(~"referrer-policy", Headers)),
    %% Unconfigured defaults are unchanged.
    ?assertEqual(~"nosniff", header(~"x-content-type-options", Headers)).

disable_header_test() ->
    Req = req(http, []),
    Config = #{content_type_options => false},
    Next = fun(R) -> {{200, [], ~"b"}, R} end,
    {{200, Headers, _}, _Req2} = call(Req, Next, Config),
    ?assertEqual(undefined, header(~"x-content-type-options", Headers)),
    ?assertEqual(~"SAMEORIGIN", header(~"x-frame-options", Headers)).

csp_opt_in_test() ->
    Req = req(http, []),
    Config = #{content_security_policy => ~"default-src 'self'"},
    Next = fun(R) -> {{200, [], ~"b"}, R} end,
    {{200, Headers, _}, _Req2} = call(Req, Next, Config),
    ?assertEqual(~"default-src 'self'", header(~"content-security-policy", Headers)).

hsts_disable_test() ->
    Req = req(https, []),
    Config = #{hsts => false},
    Next = fun(R) -> {{200, [], ~"b"}, R} end,
    {{200, Headers, _}, _Req2} = call(Req, Next, Config),
    ?assertEqual(undefined, header(~"strict-transport-security", Headers)).

hsts_sub_config_test() ->
    %% max_age override, includeSubDomains off, preload on.
    Req = req(https, []),
    Config = #{hsts => #{max_age => 600, include_subdomains => false, preload => true}},
    Next = fun(R) -> {{200, [], ~"b"}, R} end,
    {{200, Headers, _}, _Req2} = call(Req, Next, Config),
    ?assertEqual(~"max-age=600; preload", header(~"strict-transport-security", Headers)).

hsts_subdomains_without_preload_test() ->
    Req = req(https, []),
    Config = #{hsts => #{max_age => 100, include_subdomains => true, preload => false}},
    Next = fun(R) -> {{200, [], ~"b"}, R} end,
    {{200, Headers, _}, _Req2} = call(Req, Next, Config),
    ?assertEqual(
        ~"max-age=100; includeSubDomains",
        header(~"strict-transport-security", Headers)
    ).

stream_response_decorated_test() ->
    Req = req(http, []),
    Fun = fun(_Send) -> ok end,
    Next = fun(R) -> {{stream, 200, [], Fun}, R} end,
    {{stream, 200, Headers, OutFun}, _Req2} = call(Req, Next, #{}),
    ?assertEqual(Fun, OutFun),
    ?assertEqual(~"nosniff", header(~"x-content-type-options", Headers)).

sendfile_response_decorated_test() ->
    %% A file served via sendfile gets the headers too (nosniff matters most
    %% here — MIME-sniffing of served files).
    Req = req(http, []),
    Spec = {~"/tmp/x", 0, 10},
    Next = fun(R) -> {{sendfile, 200, [], Spec}, R} end,
    {{sendfile, 200, Headers, OutSpec}, _Req2} = call(Req, Next, #{}),
    ?assertEqual(Spec, OutSpec),
    ?assertEqual(~"nosniff", header(~"x-content-type-options", Headers)).

loop_response_decorated_test() ->
    Req = req(http, []),
    Next = fun(R) -> {{loop, 200, [], loop_state}, R} end,
    {{loop, 200, Headers, OutState}, _Req2} = call(Req, Next, #{}),
    ?assertEqual(loop_state, OutState),
    ?assertEqual(~"nosniff", header(~"x-content-type-options", Headers)).

websocket_passes_through_test() ->
    Req = req(http, []),
    Next = fun(R) -> {{websocket, some_mod, init_state}, R} end,
    {Response, _Req2} = call(Req, Next, #{}),
    ?assertMatch({websocket, some_mod, init_state}, Response).

%% =============================================================================
%% End-to-end through roadrunner_listener.
%% =============================================================================

plain_listener_sets_headers_test_() ->
    {setup,
        fun() ->
            {ok, _} = roadrunner_listener:start_link(sec_headers_plain_e2e, #{
                port => 0,
                routes => roadrunner_hello_handler,
                middlewares => [roadrunner_security_headers]
            }),
            roadrunner_listener:port(sec_headers_plain_e2e)
        end,
        fun(_) -> ok = roadrunner_listener:stop(sec_headers_plain_e2e) end, fun(Port) ->
            {"plain HTTP response carries the default set, no HSTS", fun() ->
                {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
                ok = gen_tcp:send(Sock, ~"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
                Reply = recv_all(Sock, <<>>),
                ok = gen_tcp:close(Sock),
                {match, _} = re:run(Reply, ~"x-content-type-options: nosniff", [caseless]),
                {match, _} = re:run(Reply, ~"x-frame-options: SAMEORIGIN", [caseless]),
                {match, _} = re:run(
                    Reply, ~"referrer-policy: strict-origin-when-cross-origin", [caseless]
                ),
                %% HSTS must be absent over plain HTTP.
                nomatch = re:run(Reply, ~"strict-transport-security", [caseless])
            end}
        end}.

tls_listener_sets_hsts_test_() ->
    {setup,
        fun() ->
            {ok, _} = application:ensure_all_started(ssl),
            {ok, _} = roadrunner_listener:start_link(sec_headers_tls_e2e, #{
                port => 0,
                tls => roadrunner_test_certs:server_opts(),
                routes => roadrunner_hello_handler,
                middlewares => [{roadrunner_security_headers, #{hsts => true}}]
            }),
            ClientOpts = [{verify, verify_none} | roadrunner_test_certs:client_opts()],
            {roadrunner_listener:port(sec_headers_tls_e2e), ClientOpts}
        end,
        fun(_) -> ok = roadrunner_listener:stop(sec_headers_tls_e2e) end, fun({Port, ClientOpts}) ->
            {"HTTPS response carries HSTS", fun() ->
                {ok, Sock} = ssl:connect(
                    {127, 0, 0, 1}, Port, ClientOpts ++ [binary, {active, false}], 5000
                ),
                ok = ssl:send(
                    Sock, ~"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                ),
                Reply = recv_all_ssl(Sock, <<>>),
                ok = ssl:close(Sock),
                {match, _} = re:run(
                    Reply,
                    ~"strict-transport-security: max-age=31536000; includeSubDomains",
                    [caseless]
                ),
                {match, _} = re:run(Reply, ~"x-content-type-options: nosniff", [caseless])
            end}
        end}.

%% --- helpers ---

%% Compile the config through `init/1` (as the pipeline does at startup), then
%% invoke `call/3` with the resulting state — the contract every test exercises.
call(Req, Next, Config) ->
    ?M:call(Req, Next, ?M:init(Config)).

req(Scheme, Headers) ->
    #{
        method => ~"GET",
        target => ~"/",
        version => {1, 1},
        scheme => Scheme,
        headers => Headers
    }.

header(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, V} -> V;
        false -> undefined
    end.

recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 1000) of
        {ok, Data} -> recv_all(Sock, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.

recv_all_ssl(Sock, Acc) ->
    case ssl:recv(Sock, 0, 2000) of
        {ok, Data} -> recv_all_ssl(Sock, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.
