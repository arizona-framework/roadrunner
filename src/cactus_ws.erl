-module(cactus_ws).
-moduledoc """
WebSocket support — RFC 6455.

This first slice provides the **handshake** helpers only. Frame
parsing, masking, and the conn-level protocol switch arrive in later
features.
""".

-export([accept_key/1, handshake_response/1]).

%% RFC 6455 §1.3 magic GUID concatenated with the client key before
%% hashing — fixed by spec.
-define(WS_GUID, ~"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").

-doc """
Compute the `Sec-WebSocket-Accept` value from a client-provided
`Sec-WebSocket-Key` per RFC 6455 §4.2.2 step 5: SHA-1 of the key
concatenated with the WebSocket GUID, base64-encoded.
""".
-spec accept_key(Key :: binary()) -> binary().
accept_key(Key) when is_binary(Key) ->
    base64:encode(crypto:hash(sha, <<Key/binary, ?WS_GUID/binary>>)).

-doc """
Validate the request headers for a WebSocket upgrade and build the
`101 Switching Protocols` response triple.

Returns `{ok, 101, Headers, <<>>}` on success, or `{error, Reason}`
when the request is missing or has wrong values for any of the
required handshake headers (`Upgrade: websocket`, a `Connection`
header containing the `upgrade` token, and a non-empty
`Sec-WebSocket-Key`).
""".
-spec handshake_response(cactus_http1:headers()) ->
    {ok, cactus_http1:status(), cactus_http1:headers(), iodata()}
    | {error,
        missing_websocket_upgrade
        | missing_connection_upgrade
        | missing_websocket_key}.
handshake_response(Headers) when is_list(Headers) ->
    case validate_upgrade(Headers) of
        {ok, Key} ->
            Accept = accept_key(Key),
            RespHeaders = [
                {~"upgrade", ~"websocket"},
                {~"connection", ~"upgrade"},
                {~"sec-websocket-accept", Accept}
            ],
            {ok, 101, RespHeaders, ~""};
        {error, _} = Err ->
            Err
    end.

-spec validate_upgrade(cactus_http1:headers()) ->
    {ok, binary()}
    | {error,
        missing_websocket_upgrade
        | missing_connection_upgrade
        | missing_websocket_key}.
validate_upgrade(Headers) ->
    case header_lookup(~"upgrade", Headers) of
        ~"websocket" ->
            case has_upgrade_token(header_lookup(~"connection", Headers)) of
                true ->
                    case header_lookup(~"sec-websocket-key", Headers) of
                        undefined -> {error, missing_websocket_key};
                        Key -> {ok, Key}
                    end;
                false ->
                    {error, missing_connection_upgrade}
            end;
        _ ->
            {error, missing_websocket_upgrade}
    end.

-spec has_upgrade_token(binary() | undefined) -> boolean().
has_upgrade_token(undefined) ->
    false;
has_upgrade_token(Value) ->
    %% Connection may be a comma-separated token list — match
    %% case-insensitively against any token.
    case binary:match(string:lowercase(Value), ~"upgrade") of
        nomatch -> false;
        _ -> true
    end.

-spec header_lookup(binary(), cactus_http1:headers()) -> binary() | undefined.
header_lookup(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, V} -> V;
        false -> undefined
    end.
