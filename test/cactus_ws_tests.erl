-module(cactus_ws_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% accept_key/1 — RFC 6455 §1.3 worked example
%% =============================================================================

accept_key_rfc_example_test() ->
    %% Sec-WebSocket-Key:    dGhlIHNhbXBsZSBub25jZQ==
    %% Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
    ?assertEqual(
        ~"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        cactus_ws:accept_key(~"dGhlIHNhbXBsZSBub25jZQ==")
    ).

%% =============================================================================
%% handshake_response/1
%% =============================================================================

handshake_valid_test() ->
    Headers = [
        {~"host", ~"example.com"},
        {~"upgrade", ~"websocket"},
        {~"connection", ~"Upgrade"},
        {~"sec-websocket-key", ~"dGhlIHNhbXBsZSBub25jZQ=="}
    ],
    {ok, 101, RespHeaders, ~""} = cactus_ws:handshake_response(Headers),
    ?assertEqual(~"websocket", proplists:get_value(~"upgrade", RespHeaders)),
    ?assertEqual(~"upgrade", proplists:get_value(~"connection", RespHeaders)),
    ?assertEqual(
        ~"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        proplists:get_value(~"sec-websocket-accept", RespHeaders)
    ).

handshake_connection_with_keep_alive_test() ->
    %% Connection header may carry multiple tokens, e.g. `keep-alive, Upgrade`.
    Headers = [
        {~"upgrade", ~"websocket"},
        {~"connection", ~"keep-alive, Upgrade"},
        {~"sec-websocket-key", ~"dGhlIHNhbXBsZSBub25jZQ=="}
    ],
    ?assertMatch({ok, 101, _, _}, cactus_ws:handshake_response(Headers)).

handshake_missing_upgrade_header_test() ->
    Headers = [{~"host", ~"x"}],
    ?assertEqual(
        {error, missing_websocket_upgrade},
        cactus_ws:handshake_response(Headers)
    ).

handshake_wrong_upgrade_value_test() ->
    Headers = [
        {~"upgrade", ~"h2c"},
        {~"connection", ~"Upgrade"},
        {~"sec-websocket-key", ~"abc"}
    ],
    ?assertEqual(
        {error, missing_websocket_upgrade},
        cactus_ws:handshake_response(Headers)
    ).

handshake_missing_connection_test() ->
    Headers = [
        {~"upgrade", ~"websocket"},
        {~"sec-websocket-key", ~"abc"}
    ],
    ?assertEqual(
        {error, missing_connection_upgrade},
        cactus_ws:handshake_response(Headers)
    ).

handshake_connection_without_upgrade_test() ->
    Headers = [
        {~"upgrade", ~"websocket"},
        {~"connection", ~"keep-alive"},
        {~"sec-websocket-key", ~"abc"}
    ],
    ?assertEqual(
        {error, missing_connection_upgrade},
        cactus_ws:handshake_response(Headers)
    ).

handshake_missing_key_test() ->
    Headers = [
        {~"upgrade", ~"websocket"},
        {~"connection", ~"Upgrade"}
    ],
    ?assertEqual(
        {error, missing_websocket_key},
        cactus_ws:handshake_response(Headers)
    ).
