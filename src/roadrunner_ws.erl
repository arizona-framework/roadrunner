-module(roadrunner_ws).
-moduledoc """
WebSocket support — RFC 6455.

This first slice provides the **handshake** helpers only. Frame
parsing, masking, and the conn-level protocol switch arrive in later
features.
""".

-export([accept_key/1, handshake_response/1, parse_frame/1, encode_frame/3]).

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
-spec handshake_response(roadrunner_http1:headers()) ->
    {ok, roadrunner_http1:status(), roadrunner_http1:headers(), iodata()}
    | {error,
        missing_websocket_upgrade
        | missing_connection_upgrade
        | missing_websocket_key
        | unsupported_websocket_version}.
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

-spec validate_upgrade(roadrunner_http1:headers()) ->
    {ok, binary()}
    | {error,
        missing_websocket_upgrade
        | missing_connection_upgrade
        | missing_websocket_key
        | unsupported_websocket_version}.
validate_upgrade(Headers) ->
    %% RFC 9110 §7.8 — upgrade tokens are case-insensitive. Browsers
    %% send `websocket` (lowercase) but other clients may send
    %% `WebSocket` or `WEBSOCKET`; accept any case.
    case is_websocket_upgrade(header_lookup(~"upgrade", Headers)) of
        true ->
            case has_upgrade_token(header_lookup(~"connection", Headers)) of
                true ->
                    case validate_version(header_lookup(~"sec-websocket-version", Headers)) of
                        ok ->
                            case header_lookup(~"sec-websocket-key", Headers) of
                                undefined -> {error, missing_websocket_key};
                                Key -> {ok, Key}
                            end;
                        {error, _} = VErr ->
                            VErr
                    end;
                false ->
                    {error, missing_connection_upgrade}
            end;
        false ->
            {error, missing_websocket_upgrade}
    end.

%% RFC 6455 §4.1 / §4.2.2: server MUST accept only `Sec-WebSocket-
%% Version: 13`. Other versions (or missing) → 400. Older drafts
%% (e.g. version 8 / hybi-08) need a different handshake; we don't
%% implement them.
-spec validate_version(binary() | undefined) ->
    ok | {error, unsupported_websocket_version}.
validate_version(~"13") -> ok;
validate_version(_) -> {error, unsupported_websocket_version}.

-spec is_websocket_upgrade(binary() | undefined) -> boolean().
is_websocket_upgrade(undefined) -> false;
is_websocket_upgrade(Value) -> string:lowercase(Value) =:= ~"websocket".

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

-spec header_lookup(binary(), roadrunner_http1:headers()) -> binary() | undefined.
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
- `fragmented_control` — control frame (close/ping/pong) with FIN=0,
  forbidden by RFC 6455 §5.5.
- `control_frame_too_large` — control frame with payload >125 bytes,
  forbidden by RFC 6455 §5.5.
""".
-spec parse_frame(binary()) ->
    {ok, frame(), Rest :: binary()}
    | {more, undefined}
    | {error, bad_opcode | bad_rsv | not_masked | fragmented_control | control_frame_too_large}.
parse_frame(<<_Fin:1, Rsv:3, _:4, _/bitstring>>) when Rsv =/= 0 ->
    {error, bad_rsv};
parse_frame(<<Fin:1, 0:3, Op:4, Mask:1, Len7:7, Rest/binary>>) ->
    case decode_opcode(Op) of
        {ok, Opcode} ->
            case validate_control(Opcode, Fin, Len7) of
                ok -> parse_length(Len7, Mask, Rest, fin_flag(Fin), Opcode);
                {error, _} = E -> E
            end;
        error ->
            {error, bad_opcode}
    end;
parse_frame(_) ->
    {more, undefined}.

%% RFC 6455 §5.5: control frames (close, ping, pong) MUST NOT be
%% fragmented and MUST have payload ≤125 bytes (i.e. encoded with the
%% 7-bit length, not the 16-bit or 64-bit extended forms).
-spec validate_control(opcode(), 0 | 1, 0..127) ->
    ok | {error, fragmented_control | control_frame_too_large}.
validate_control(Op, _Fin, _Len7) when Op =/= close, Op =/= ping, Op =/= pong ->
    ok;
validate_control(_Op, 0, _Len7) ->
    {error, fragmented_control};
validate_control(_Op, 1, Len7) when Len7 > 125 ->
    {error, control_frame_too_large};
validate_control(_Op, 1, _Len7) ->
    ok.

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

-doc """
Encode a single WebSocket frame for the server→client direction.

Server frames are sent **unmasked** per RFC 6455 §5.1. Picks the
shortest valid length encoding: 7-bit literal for ≤125 bytes, 16-bit
extended (126) for ≤65535, 64-bit extended (127) for larger.

`Fin` controls the FIN bit — pass `true` for the only or last frame
of a message and `false` for non-final fragments of a continuation
sequence.
""".
-spec encode_frame(opcode(), iodata(), boolean()) -> iodata().
encode_frame(Opcode, Payload, Fin) ->
    Op = encode_opcode(Opcode),
    FinBit = fin_bit(Fin),
    PayloadBin = iolist_to_binary(Payload),
    Len = byte_size(PayloadBin),
    Header = encode_header(FinBit, Op, Len),
    [Header, PayloadBin].

-spec encode_header(0 | 1, 0..15, non_neg_integer()) -> binary().
encode_header(FinBit, Op, Len) when Len =< 125 ->
    <<FinBit:1, 0:3, Op:4, 0:1, Len:7>>;
encode_header(FinBit, Op, Len) when Len =< 16#FFFF ->
    <<FinBit:1, 0:3, Op:4, 0:1, 126:7, Len:16>>;
encode_header(FinBit, Op, Len) ->
    <<FinBit:1, 0:3, Op:4, 0:1, 127:7, Len:64>>.

-spec encode_opcode(opcode()) -> 0..15.
encode_opcode(continuation) -> ?OP_CONTINUATION;
encode_opcode(text) -> ?OP_TEXT;
encode_opcode(binary) -> ?OP_BINARY;
encode_opcode(close) -> ?OP_CLOSE;
encode_opcode(ping) -> ?OP_PING;
encode_opcode(pong) -> ?OP_PONG.

-spec fin_bit(boolean()) -> 0 | 1.
fin_bit(true) -> 1;
fin_bit(false) -> 0.
