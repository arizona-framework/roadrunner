-module(cactus_ws).
-moduledoc """
WebSocket support — RFC 6455.

This first slice provides the **handshake** helpers only. Frame
parsing, masking, and the conn-level protocol switch arrive in later
features.
""".

-export([accept_key/1, handshake_response/1, parse_frame/1]).

-export_type([opcode/0, frame/0]).

-type opcode() :: continuation | text | binary | close | ping | pong.
-type frame() :: #{
    fin := boolean(),
    opcode := opcode(),
    payload := binary()
}.

%% RFC 6455 §1.3 magic GUID concatenated with the client key before
%% hashing — fixed by spec.
-define(WS_GUID, ~"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").

-define(OP_CONTINUATION, 0).
-define(OP_TEXT, 1).
-define(OP_BINARY, 2).
-define(OP_CLOSE, 8).
-define(OP_PING, 9).
-define(OP_PONG, 10).

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

-doc """
Decode a single WebSocket frame from the buffer.

Returns `{ok, Frame, Rest}` on success — `Frame` is a map with
`fin`, `opcode`, and (already-unmasked) `payload`. Returns
`{more, undefined}` when more bytes are needed to complete the
frame, or `{error, _}` for protocol violations:
- `bad_rsv` — any of RSV1/RSV2/RSV3 set (no extensions supported).
- `bad_opcode` — opcode is reserved (3-7, 0xB-0xF).
- `not_masked` — server-side requires the MASK bit on every client frame.
""".
-spec parse_frame(binary()) ->
    {ok, frame(), Rest :: binary()}
    | {more, undefined}
    | {error, bad_opcode | bad_rsv | not_masked}.
parse_frame(<<_Fin:1, Rsv:3, _:4, _/bitstring>>) when Rsv =/= 0 ->
    {error, bad_rsv};
parse_frame(<<Fin:1, 0:3, Op:4, Mask:1, Len7:7, Rest/binary>>) ->
    case decode_opcode(Op) of
        {ok, Opcode} -> parse_length(Len7, Mask, Rest, fin_flag(Fin), Opcode);
        error -> {error, bad_opcode}
    end;
parse_frame(_) ->
    {more, undefined}.

-spec fin_flag(0 | 1) -> boolean().
fin_flag(1) -> true;
fin_flag(0) -> false.

-spec decode_opcode(0..15) -> {ok, opcode()} | error.
decode_opcode(?OP_CONTINUATION) -> {ok, continuation};
decode_opcode(?OP_TEXT) -> {ok, text};
decode_opcode(?OP_BINARY) -> {ok, binary};
decode_opcode(?OP_CLOSE) -> {ok, close};
decode_opcode(?OP_PING) -> {ok, ping};
decode_opcode(?OP_PONG) -> {ok, pong};
decode_opcode(_) -> error.

-spec parse_length(0..127, 0 | 1, binary(), boolean(), opcode()) ->
    {ok, frame(), binary()}
    | {more, undefined}
    | {error, not_masked}.
parse_length(126, Mask, <<Len:16, Rest/binary>>, Fin, Op) ->
    parse_payload(Len, Mask, Rest, Fin, Op);
parse_length(127, Mask, <<Len:64, Rest/binary>>, Fin, Op) ->
    parse_payload(Len, Mask, Rest, Fin, Op);
parse_length(Len7, Mask, Rest, Fin, Op) when Len7 < 126 ->
    parse_payload(Len7, Mask, Rest, Fin, Op);
parse_length(_, _, _, _, _) ->
    {more, undefined}.

-spec parse_payload(non_neg_integer(), 0 | 1, binary(), boolean(), opcode()) ->
    {ok, frame(), binary()}
    | {more, undefined}
    | {error, not_masked}.
parse_payload(_Len, 0, _Bin, _Fin, _Op) ->
    %% Server-side: per RFC 6455 §5.1 every client frame must be masked.
    {error, not_masked};
parse_payload(Len, 1, Bin, Fin, Op) ->
    case Bin of
        <<MaskKey:4/binary, Payload:Len/binary, Rest/binary>> ->
            {ok,
                #{
                    fin => Fin,
                    opcode => Op,
                    payload => unmask(Payload, MaskKey)
                },
                Rest};
        _ ->
            {more, undefined}
    end.

%% Body recursion building an iolist; iolist_to_binary at the end keeps
%% allocations linear regardless of payload size.
-spec unmask(binary(), binary()) -> binary().
unmask(Payload, MaskKey) ->
    iolist_to_binary(unmask_bytes(Payload, MaskKey, 0)).

-spec unmask_bytes(binary(), binary(), non_neg_integer()) -> [byte()].
unmask_bytes(<<>>, _MaskKey, _I) ->
    [];
unmask_bytes(<<B, Rest/binary>>, MaskKey, I) ->
    M = binary:at(MaskKey, I rem 4),
    [B bxor M | unmask_bytes(Rest, MaskKey, I + 1)].
