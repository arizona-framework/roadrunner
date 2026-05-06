-module(roadrunner_ws).
-moduledoc """
WebSocket support — RFC 6455.

This first slice provides the **handshake** helpers only. Frame
parsing, masking, and the conn-level protocol switch arrive in later
features.
""".

-on_load(init_patterns/0).

-export([accept_key/1, handshake_response/1]).
-export([parse_frame/1, parse_frame/2]).
-export([peek_frame_header/2]).
-export([encode_frame/3, encode_frame/4]).
-export([parse_extensions/1, negotiate_extensions/1]).

-export_type([
    opcode/0,
    frame/0,
    extension/0,
    parse_opts/0,
    encode_opts/0,
    permessage_deflate_params/0,
    negotiated/0,
    close_code/0
]).

-define(EXT_OFFER_CP_KEY, {?MODULE, ext_offer_cp}).
-define(EXT_PARAM_CP_KEY, {?MODULE, ext_param_cp}).
-define(EXT_KV_CP_KEY, {?MODULE, ext_kv_cp}).
-define(EXT_QUOTE_CP_KEY, {?MODULE, ext_quote_cp}).
-define(UPGRADE_CP_KEY, {?MODULE, upgrade_cp}).

-type opcode() :: continuation | text | binary | close | ping | pong.
-type frame() :: #{
    fin := boolean(),
    rsv1 := boolean(),
    opcode := opcode(),
    payload := binary()
}.

%% A single offer in the `Sec-WebSocket-Extensions` header. Parameter
%% values are `binary()` for `key=value` pairs or `true` for bare flag
%% parameters (e.g. `client_no_context_takeover`).
-type extension() :: {binary(), [{binary(), binary() | true}]}.

%% Parse-side options. `allow_rsv1 => true` surfaces the RSV1 bit in
%% the returned frame map (per RFC 7692 the bit signals a compressed
%% message). RSV2 and RSV3 are always rejected — no IETF extension
%% uses them.
-type parse_opts() :: #{
    allow_rsv1 => boolean(),
    %% Caller-supplied unmasked payload. When this matches the frame's
    %% length, `parse_frame/2` skips its own `unmask/2` call and uses
    %% the supplied bytes directly. `roadrunner_ws_session` populates
    %% this from its incremental UTF-8 validation pass — same bytes
    %% would otherwise be unmasked twice.
    pre_unmasked => binary()
}.

%% Encode-side options. `rsv1 => true` sets the RSV1 bit on the
%% emitted frame; the caller is responsible for ensuring an
%% extension that uses the bit is in effect.
-type encode_opts() :: #{rsv1 => boolean()}.

%% Negotiated permessage-deflate parameters per RFC 7692 §7.1.
%% Window-bits values are zlib's (8..15). The `*_no_context_takeover`
%% flags mirror the request; when `true`, the corresponding zlib
%% context is reset after every message.
-type permessage_deflate_params() :: #{
    server_max_window_bits := 8..15,
    client_max_window_bits := 8..15,
    server_no_context_takeover := boolean(),
    client_no_context_takeover := boolean()
}.

-type negotiated() ::
    none
    | {permessage_deflate, permessage_deflate_params(), ResponseHeaderValue :: binary()}.

%% Close status codes a server is permitted to send per RFC 6455 §7.4.
%% 1004/1005/1006 are reserved (MUST NOT appear on the wire);
%% 1012/1013 are unassigned. 3000-3999 is the IANA-registered range,
%% 4000-4999 is for application-private use.
-type close_code() ::
    1000..1003 | 1007..1011 | 1014 | 3000..4999.

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
`101 Switching Protocols` response.

Returns `{ok, 101, Headers, <<>>, Negotiated}` on success, or
`{error, Reason}` when the request is missing or has wrong values
for any of the required handshake headers (`Upgrade: websocket`, a
`Connection` header containing the `upgrade` token, and a non-empty
`Sec-WebSocket-Key`).

`Negotiated` is `none` if no extension was offered or accepted, or
`{permessage_deflate, Params, _}` when RFC 7692 was negotiated.
The session uses this to set up zlib state. The agreed extension's
response header is already in `Headers`.
""".
-spec handshake_response(roadrunner_req:headers()) ->
    {ok, roadrunner_req:status(), roadrunner_req:headers(), iodata(), negotiated()}
    | {error,
        missing_websocket_upgrade
        | missing_connection_upgrade
        | missing_websocket_key
        | unsupported_websocket_version}.
handshake_response(Headers) when is_list(Headers) ->
    case validate_upgrade(Headers) of
        {ok, Key} ->
            Accept = accept_key(Key),
            Negotiated = negotiate_extensions(
                parse_extensions(header_lookup(~"sec-websocket-extensions", Headers))
            ),
            RespHeaders = build_handshake_headers(Accept, Negotiated),
            {ok, 101, RespHeaders, ~"", Negotiated};
        {error, _} = Err ->
            Err
    end.

-spec build_handshake_headers(binary(), negotiated()) -> roadrunner_req:headers().
build_handshake_headers(Accept, none) ->
    [
        {~"upgrade", ~"websocket"},
        {~"connection", ~"upgrade"},
        {~"sec-websocket-accept", Accept}
    ];
build_handshake_headers(Accept, {permessage_deflate, _, ResponseValue}) ->
    [
        {~"upgrade", ~"websocket"},
        {~"connection", ~"upgrade"},
        {~"sec-websocket-accept", Accept},
        {~"sec-websocket-extensions", ResponseValue}
    ].

-spec validate_upgrade(roadrunner_req:headers()) ->
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
is_websocket_upgrade(Value) -> roadrunner_bin:ascii_lowercase(Value) =:= ~"websocket".

-spec has_upgrade_token(binary() | undefined) -> boolean().
has_upgrade_token(undefined) ->
    false;
has_upgrade_token(Value) ->
    %% Connection may be a comma-separated token list — match
    %% case-insensitively against any token.
    binary:match(roadrunner_bin:ascii_lowercase(Value), persistent_term:get(?UPGRADE_CP_KEY)) =/=
        nomatch.

-spec header_lookup(binary(), roadrunner_req:headers()) -> binary() | undefined.
header_lookup(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, V} -> V;
        false -> undefined
    end.

-doc """
Parse a `Sec-WebSocket-Extensions` header value into a list of
`{ExtensionName, Params}` tuples per RFC 6455 §9.1 grammar.

Each offer in the header is comma-separated. Within an offer, the
extension name comes first followed by optional `;`-separated
parameters. Parameters may be bare (`client_no_context_takeover`,
returned as `{<<"client_no_context_takeover">>, true}`) or
key=value (`server_max_window_bits=10`, returned as
`{<<"server_max_window_bits">>, <<"10">>}`).

Names and parameter keys are lowercased; parameter values are
returned verbatim (with surrounding quotes stripped). The order of
offers AND of parameters within an offer is preserved — RFC 7692
relies on offer order for negotiation precedence.

Returns `[]` for an absent / empty header value.

```erlang
parse_extensions(<<"permessage-deflate; client_max_window_bits=15, x-foo">>).
%% => [{<<"permessage-deflate">>, [{<<"client_max_window_bits">>, <<"15">>}]},
%%     {<<"x-foo">>, []}]
```
""".
-spec parse_extensions(binary() | undefined) -> [extension()].
parse_extensions(undefined) ->
    [];
parse_extensions(<<>>) ->
    [];
parse_extensions(Value) when is_binary(Value) ->
    Lower = roadrunner_bin:ascii_lowercase(Value),
    OfferCp = persistent_term:get(?EXT_OFFER_CP_KEY),
    ParamCp = persistent_term:get(?EXT_PARAM_CP_KEY),
    KvCp = persistent_term:get(?EXT_KV_CP_KEY),
    [parse_extension_offer(Offer, ParamCp, KvCp) || Offer <- split_offers(Lower, OfferCp)].

%% Comma is the offer separator and is not allowed inside parameter
%% values (RFC 6455 §9.1 grammar uses token / quoted-string for
%% values, both of which forbid `,`). Split-on-comma is safe.
-spec split_offers(binary(), binary:cp()) -> [binary()].
split_offers(Bin, OfferCp) ->
    [
        string:trim(O)
     || O <- binary:split(Bin, OfferCp, [global]), string:trim(O) =/= <<>>
    ].

-spec parse_extension_offer(binary(), binary:cp(), binary:cp()) -> extension().
parse_extension_offer(Offer, ParamCp, KvCp) ->
    case binary:split(Offer, ParamCp, [global]) of
        [Name] ->
            {string:trim(Name), []};
        [Name | Params] ->
            {string:trim(Name), [parse_extension_param(P, KvCp) || P <- Params]}
    end.

-spec parse_extension_param(binary(), binary:cp()) -> {binary(), binary() | true}.
parse_extension_param(Param, KvCp) ->
    case binary:split(string:trim(Param), KvCp) of
        [Key] ->
            {Key, true};
        [Key, Value] ->
            {string:trim(Key), unquote(string:trim(Value))}
    end.

-spec unquote(binary()) -> binary().
unquote(<<$", Rest/binary>>) ->
    case binary:match(Rest, persistent_term:get(?EXT_QUOTE_CP_KEY)) of
        {End, _} -> binary:part(Rest, 0, End);
        nomatch -> Rest
    end;
unquote(V) ->
    V.

-doc """
Pick the first acceptable offer from a parsed `Sec-WebSocket-Extensions`
list. Today only `permessage-deflate` (RFC 7692) is supported; all
other extension names are skipped.

Returns `none` if no acceptable offer is found, or
`{permessage_deflate, NegotiatedParams, ResponseHeaderValue}` where:

- `NegotiatedParams` is a map suitable for setting up the inflate /
  deflate zlib contexts and for honoring the `*_no_context_takeover`
  reset semantics.
- `ResponseHeaderValue` is the value to put in the response's
  `Sec-WebSocket-Extensions` header per RFC 7692 §5.1 (echoes the
  negotiated parameters with their agreed values).

Per RFC 6455 §9.1, when multiple extensions are offered the server
processes them in order and picks the first one it can accept;
unrecognised offers are silently skipped.
""".
-spec negotiate_extensions([extension()]) -> negotiated().
negotiate_extensions([]) ->
    none;
negotiate_extensions([{~"permessage-deflate", Params} | _Rest]) ->
    case negotiate_permessage_deflate(Params) of
        {ok, Negotiated, ResponseValue} ->
            {permessage_deflate, Negotiated, ResponseValue};
        invalid ->
            %% Malformed offer (e.g. out-of-range window bits) — skip
            %% per RFC 7692 §7. Don't try a second permessage-deflate
            %% offer; clients aren't supposed to send more than one.
            none
    end;
negotiate_extensions([_Other | Rest]) ->
    negotiate_extensions(Rest).

%% Walk the offer's parameter list and either return a fully-resolved
%% set of negotiated values + the response header echo, or `invalid`
%% if any parameter is out of spec. Defaults: window bits 15
%% (max history), context takeover ON (most efficient).
-spec negotiate_permessage_deflate([{binary(), binary() | true}]) ->
    {ok, permessage_deflate_params(), binary()} | invalid.
negotiate_permessage_deflate(Params) ->
    case parse_pmd_params(Params, default_pmd()) of
        {ok, Negotiated} ->
            {ok, Negotiated, format_pmd_response(Negotiated)};
        invalid ->
            invalid
    end.

-spec default_pmd() -> permessage_deflate_params().
default_pmd() ->
    #{
        server_max_window_bits => 15,
        client_max_window_bits => 15,
        server_no_context_takeover => false,
        client_no_context_takeover => false
    }.

-spec parse_pmd_params([{binary(), binary() | true}], permessage_deflate_params()) ->
    {ok, permessage_deflate_params()} | invalid.
parse_pmd_params([], Acc) ->
    {ok, Acc};
parse_pmd_params([{~"server_no_context_takeover", true} | Rest], Acc) ->
    parse_pmd_params(Rest, Acc#{server_no_context_takeover => true});
parse_pmd_params([{~"client_no_context_takeover", true} | Rest], Acc) ->
    parse_pmd_params(Rest, Acc#{client_no_context_takeover => true});
parse_pmd_params([{~"server_max_window_bits", Value} | Rest], Acc) ->
    case window_bits(Value) of
        {ok, N} -> parse_pmd_params(Rest, Acc#{server_max_window_bits => N});
        invalid -> invalid
    end;
parse_pmd_params([{~"client_max_window_bits", true} | Rest], Acc) ->
    %% Bare `client_max_window_bits` (no value) means the client
    %% accepts any value the server picks. Default to 15 (max).
    parse_pmd_params(Rest, Acc);
parse_pmd_params([{~"client_max_window_bits", Value} | Rest], Acc) ->
    case window_bits(Value) of
        {ok, N} -> parse_pmd_params(Rest, Acc#{client_max_window_bits => N});
        invalid -> invalid
    end;
parse_pmd_params([{_Other, _} | Rest], Acc) ->
    %% Unknown parameter — skip. RFC 7692 §7 allows future extension
    %% parameters; ignoring keeps us compatible.
    parse_pmd_params(Rest, Acc).

%% Erlang's zlib accepts windowBits 8..15 for inflate (`-N` for raw
%% inflate, same range). Spec-allowed range is also 8..15.
-spec window_bits(binary() | true) -> {ok, 8..15} | invalid.
window_bits(true) ->
    invalid;
window_bits(Bin) when is_binary(Bin) ->
    case string:to_integer(Bin) of
        {N, <<>>} when N >= 8, N =< 15 -> {ok, N};
        _ -> invalid
    end.

%% Build the response header value echoing the agreed parameters.
%% Defaults that the client did NOT request can be omitted from the
%% response — the format below echoes only the non-default settings
%% so clients with strict parsers see a clean response.
-spec format_pmd_response(permessage_deflate_params()) -> binary().
format_pmd_response(#{
    server_max_window_bits := SMW,
    client_max_window_bits := CMW,
    server_no_context_takeover := SNCT,
    client_no_context_takeover := CNCT
}) ->
    Tail = [
        format_pmd_flag(~"server_no_context_takeover", SNCT),
        format_pmd_flag(~"client_no_context_takeover", CNCT),
        format_pmd_kv(~"server_max_window_bits", SMW, 15),
        format_pmd_kv(~"client_max_window_bits", CMW, 15)
    ],
    iolist_to_binary([~"permessage-deflate" | [P || P <- Tail, P =/= []]]).

-spec format_pmd_flag(binary(), boolean()) -> iodata().
format_pmd_flag(_Name, false) -> [];
format_pmd_flag(Name, true) -> [~"; ", Name].

-spec format_pmd_kv(binary(), 8..15, 8..15) -> iodata().
format_pmd_kv(_Name, Default, Default) -> [];
format_pmd_kv(Name, Value, _Default) -> [~"; ", Name, ~"=", integer_to_binary(Value)].

-doc """
Decode a single WebSocket frame from the buffer.

Returns `{ok, Frame, Rest}` on success — `Frame` is a map with
`fin`, `rsv1`, `opcode`, and (already-unmasked) `payload`. Returns
`{more, undefined}` when more bytes are needed to complete the
frame, or `{error, _}` for protocol violations:
- `bad_rsv` — RSV2 or RSV3 set, or RSV1 set without an extension
  permitting it (default: not permitted).
- `bad_opcode` — opcode is reserved (3-7, 0xB-0xF).
- `not_masked` — server-side requires the MASK bit on every client frame.
- `fragmented_control` — control frame (close/ping/pong) with FIN=0,
  forbidden by RFC 6455 §5.5.
- `control_frame_too_large` — control frame with payload >125 bytes,
  forbidden by RFC 6455 §5.5.

Use `parse_frame/2` with `#{allow_rsv1 => true}` once a permessage
extension (RFC 7692) has been negotiated.
""".
-spec parse_frame(binary()) ->
    {ok, frame(), Rest :: binary()}
    | {more, undefined}
    | {error, bad_opcode | bad_rsv | not_masked | fragmented_control | control_frame_too_large}.
parse_frame(Bin) ->
    parse_frame(Bin, #{}).

-doc """
Decode a single WebSocket frame, with extension awareness.

`Opts` may include `allow_rsv1 => true` to permit the RSV1 bit
(needed once `permessage-deflate` is negotiated per RFC 7692).
RSV2 and RSV3 remain unconditionally rejected.
""".
-spec parse_frame(binary(), parse_opts()) ->
    {ok, frame(), Rest :: binary()}
    | {more, undefined}
    | {error, bad_opcode | bad_rsv | not_masked | fragmented_control | control_frame_too_large}.
parse_frame(Bin, Opts) ->
    do_parse_frame(
        Bin,
        maps:get(allow_rsv1, Opts, false),
        maps:get(pre_unmasked, Opts, undefined)
    ).

-spec do_parse_frame(binary(), boolean(), binary() | undefined) ->
    {ok, frame(), Rest :: binary()}
    | {more, undefined}
    | {error, bad_opcode | bad_rsv | not_masked | fragmented_control | control_frame_too_large}.
do_parse_frame(<<_Fin:1, _Rsv1:1, Rsv23:2, _:4, _/bitstring>>, _AllowRsv1, _Pre) when
    Rsv23 =/= 0
->
    {error, bad_rsv};
do_parse_frame(<<_Fin:1, 1:1, 0:2, _:4, _/bitstring>>, false, _Pre) ->
    {error, bad_rsv};
do_parse_frame(<<Fin:1, Rsv1:1, 0:2, Op:4, Mask:1, Len7:7, Rest/binary>>, _AllowRsv1, Pre) ->
    case decode_opcode(Op) of
        {ok, Opcode} ->
            case validate_control(Opcode, Fin, Len7) of
                ok ->
                    parse_length(Len7, Mask, Rest, fin_flag(Fin), rsv_flag(Rsv1), Opcode, Pre);
                {error, _} = E ->
                    E
            end;
        error ->
            {error, bad_opcode}
    end;
do_parse_frame(_, _AllowRsv1, _Pre) ->
    {more, undefined}.

-doc """
Sneak-peek a partially-buffered frame: parse just enough of the
header to expose the payload region. Returns:

- `{ok, #{opcode => _, fin => _, rsv1 => _, total_payload_len => _,
         mask_key => _, payload_offset => _}, BytesAvailable}` when
  the header is fully buffered; `BytesAvailable` is the number of
  payload bytes already in `Buf` (may be 0..total_payload_len).
- `{more, undefined}` if even the header isn't complete.
- `{error, _}` for the same protocol violations `parse_frame/2`
  rejects.

Used by `roadrunner_ws_session` to validate text-frame UTF-8
payload bytes incrementally as TCP chunks arrive — well before
the frame as a whole completes. Honors `allow_rsv1` the same way
`parse_frame/2` does.
""".
-spec peek_frame_header(binary(), parse_opts()) ->
    {ok, map(), non_neg_integer()}
    | {more, undefined}
    | {error, bad_opcode | bad_rsv | not_masked | fragmented_control | control_frame_too_large}.
peek_frame_header(Bin, Opts) ->
    do_peek(Bin, maps:get(allow_rsv1, Opts, false)).

-spec do_peek(binary(), boolean()) ->
    {ok, map(), non_neg_integer()}
    | {more, undefined}
    | {error, bad_opcode | bad_rsv | not_masked | fragmented_control | control_frame_too_large}.
do_peek(<<_Fin:1, _Rsv1:1, Rsv23:2, _:4, _/bitstring>>, _AllowRsv1) when Rsv23 =/= 0 ->
    {error, bad_rsv};
do_peek(<<_Fin:1, 1:1, 0:2, _:4, _/bitstring>>, false) ->
    {error, bad_rsv};
do_peek(<<Fin:1, Rsv1:1, 0:2, Op:4, Mask:1, Len7:7, Rest/binary>>, _AllowRsv1) ->
    case decode_opcode(Op) of
        {ok, Opcode} ->
            case validate_control(Opcode, Fin, Len7) of
                ok -> peek_extract(Opcode, Fin, Rsv1, Mask, Len7, Rest);
                {error, _} = E -> E
            end;
        error ->
            {error, bad_opcode}
    end;
do_peek(_, _AllowRsv1) ->
    {more, undefined}.

-spec peek_extract(opcode(), 0 | 1, 0 | 1, 0 | 1, 0..127, binary()) ->
    {ok, map(), non_neg_integer()} | {more, undefined} | {error, not_masked}.
peek_extract(_Opcode, _Fin, _Rsv1, 0, _Len7, _Rest) ->
    {error, not_masked};
peek_extract(Opcode, Fin, Rsv1, 1, 126, <<Len:16, MaskKey:4/binary, Body/binary>>) ->
    {ok, peek_header(Opcode, Fin, Rsv1, Len, MaskKey, 8), byte_size(Body)};
peek_extract(Opcode, Fin, Rsv1, 1, 127, <<Len:64, MaskKey:4/binary, Body/binary>>) ->
    {ok, peek_header(Opcode, Fin, Rsv1, Len, MaskKey, 14), byte_size(Body)};
peek_extract(Opcode, Fin, Rsv1, 1, Len7, <<MaskKey:4/binary, Body/binary>>) when Len7 < 126 ->
    {ok, peek_header(Opcode, Fin, Rsv1, Len7, MaskKey, 6), byte_size(Body)};
peek_extract(_Opcode, _Fin, _Rsv1, 1, _Len7, _Rest) ->
    {more, undefined}.

-spec peek_header(opcode(), 0 | 1, 0 | 1, non_neg_integer(), binary(), non_neg_integer()) -> map().
peek_header(Opcode, Fin, Rsv1, Len, MaskKey, PayloadOffset) ->
    #{
        opcode => Opcode,
        fin => fin_flag(Fin),
        rsv1 => rsv_flag(Rsv1),
        total_payload_len => Len,
        mask_key => MaskKey,
        payload_offset => PayloadOffset
    }.

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

-spec rsv_flag(0 | 1) -> boolean().
rsv_flag(1) -> true;
rsv_flag(0) -> false.

-spec decode_opcode(0..15) -> {ok, opcode()} | error.
decode_opcode(?OP_CONTINUATION) -> {ok, continuation};
decode_opcode(?OP_TEXT) -> {ok, text};
decode_opcode(?OP_BINARY) -> {ok, binary};
decode_opcode(?OP_CLOSE) -> {ok, close};
decode_opcode(?OP_PING) -> {ok, ping};
decode_opcode(?OP_PONG) -> {ok, pong};
decode_opcode(_) -> error.

-spec parse_length(
    0..127, 0 | 1, binary(), boolean(), boolean(), opcode(), binary() | undefined
) ->
    {ok, frame(), binary()}
    | {more, undefined}
    | {error, not_masked}.
parse_length(126, Mask, <<Len:16, Rest/binary>>, Fin, Rsv1, Op, Pre) ->
    parse_payload(Len, Mask, Rest, Fin, Rsv1, Op, Pre);
parse_length(127, Mask, <<Len:64, Rest/binary>>, Fin, Rsv1, Op, Pre) ->
    parse_payload(Len, Mask, Rest, Fin, Rsv1, Op, Pre);
parse_length(Len7, Mask, Rest, Fin, Rsv1, Op, Pre) when Len7 < 126 ->
    parse_payload(Len7, Mask, Rest, Fin, Rsv1, Op, Pre);
parse_length(_, _, _, _, _, _, _) ->
    {more, undefined}.

-spec parse_payload(
    non_neg_integer(), 0 | 1, binary(), boolean(), boolean(), opcode(), binary() | undefined
) ->
    {ok, frame(), binary()}
    | {more, undefined}
    | {error, not_masked}.
parse_payload(_Len, 0, _Bin, _Fin, _Rsv1, _Op, _Pre) ->
    %% Server-side: per RFC 6455 §5.1 every client frame must be masked.
    {error, not_masked};
parse_payload(Len, 1, Bin, Fin, Rsv1, Op, Pre) ->
    case Bin of
        <<_MaskKey:4/binary, _Payload:Len/binary, Rest/binary>> when
            is_binary(Pre), byte_size(Pre) =:= Len
        ->
            %% Caller already unmasked these bytes (typically via
            %% `roadrunner_ws_session:early_validate_text/3`'s
            %% incremental UTF-8 pass) — skip the redundant unmask.
            {ok,
                #{
                    fin => Fin,
                    rsv1 => Rsv1,
                    opcode => Op,
                    payload => Pre
                },
                Rest};
        <<MaskKey:4/binary, Payload:Len/binary, Rest/binary>> ->
            {ok,
                #{
                    fin => Fin,
                    rsv1 => Rsv1,
                    opcode => Op,
                    payload => unmask(Payload, MaskKey)
                },
                Rest};
        _ ->
            {more, undefined}
    end.

%% Unmask a client→server payload (RFC 6455 §5.3) by XOR'ing
%% against the 32-bit `MaskKey` repeatedly. Processes 16 bytes
%% per recursion (4 × 32-bit words) so the BEAM JIT can emit
%% straight-line code for the common case — same shape as
%% cowlib's `cow_ws:mask/3`. For 1 KB payloads this is ~10×
%% faster than the byte-at-a-time iolist version.
-spec unmask(binary(), binary()) -> binary().
unmask(Payload, <<MaskKey:32>>) ->
    unmask_chunks(Payload, MaskKey, <<>>).

-spec unmask_chunks(binary(), non_neg_integer(), binary()) -> binary().
unmask_chunks(<<O1:32, O2:32, O3:32, O4:32, Rest/binary>>, MK, Acc) ->
    T1 = O1 bxor MK,
    T2 = O2 bxor MK,
    T3 = O3 bxor MK,
    T4 = O4 bxor MK,
    unmask_chunks(Rest, MK, <<Acc/binary, T1:32, T2:32, T3:32, T4:32>>);
unmask_chunks(<<O:32, Rest/binary>>, MK, Acc) ->
    T = O bxor MK,
    unmask_chunks(Rest, MK, <<Acc/binary, T:32>>);
unmask_chunks(<<O:24>>, MK, Acc) ->
    <<MK2:24, _:8>> = <<MK:32>>,
    T = O bxor MK2,
    <<Acc/binary, T:24>>;
unmask_chunks(<<O:16>>, MK, Acc) ->
    <<MK2:16, _:16>> = <<MK:32>>,
    T = O bxor MK2,
    <<Acc/binary, T:16>>;
unmask_chunks(<<O:8>>, MK, Acc) ->
    <<MK2:8, _:24>> = <<MK:32>>,
    T = O bxor MK2,
    <<Acc/binary, T:8>>;
unmask_chunks(<<>>, _MK, Acc) ->
    Acc.

-doc """
Encode a single WebSocket frame for the server→client direction.

Server frames are sent **unmasked** per RFC 6455 §5.1. Picks the
shortest valid length encoding: 7-bit literal for ≤125 bytes, 16-bit
extended (126) for ≤65535, 64-bit extended (127) for larger.

`Fin` controls the FIN bit — pass `true` for the only or last frame
of a message and `false` for non-final fragments of a continuation
sequence.

Use `encode_frame/4` with `#{rsv1 => true}` once `permessage-deflate`
is negotiated and you're emitting a compressed first-fragment.
""".
-spec encode_frame(opcode(), iodata(), boolean()) -> iodata().
encode_frame(Opcode, Payload, Fin) ->
    encode_frame(Opcode, Payload, Fin, #{}).

-spec encode_frame(opcode(), iodata(), boolean(), encode_opts()) -> iodata().
encode_frame(Opcode, Payload, Fin, Opts) ->
    Op = encode_opcode(Opcode),
    FinBit = fin_bit(Fin),
    Rsv1Bit = rsv_bit(maps:get(rsv1, Opts, false)),
    PayloadBin = iolist_to_binary(Payload),
    Len = byte_size(PayloadBin),
    Header = encode_header(FinBit, Rsv1Bit, Op, Len),
    [Header, PayloadBin].

-spec encode_header(0 | 1, 0 | 1, 0..15, non_neg_integer()) -> binary().
encode_header(FinBit, Rsv1Bit, Op, Len) when Len =< 125 ->
    <<FinBit:1, Rsv1Bit:1, 0:2, Op:4, 0:1, Len:7>>;
encode_header(FinBit, Rsv1Bit, Op, Len) when Len =< 16#FFFF ->
    <<FinBit:1, Rsv1Bit:1, 0:2, Op:4, 0:1, 126:7, Len:16>>;
encode_header(FinBit, Rsv1Bit, Op, Len) ->
    <<FinBit:1, Rsv1Bit:1, 0:2, Op:4, 0:1, 127:7, Len:64>>.

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

-spec rsv_bit(boolean()) -> 0 | 1.
rsv_bit(true) -> 1;
rsv_bit(false) -> 0.

%% `-on_load` callback. Compiles the Sec-WebSocket-Extensions
%% splitter patterns once and stashes them in `persistent_term` so
%% the per-handshake parse has no setup cost.
-spec init_patterns() -> ok.
init_patterns() ->
    persistent_term:put(?EXT_OFFER_CP_KEY, binary:compile_pattern(~",")),
    persistent_term:put(?EXT_PARAM_CP_KEY, binary:compile_pattern(~";")),
    persistent_term:put(?EXT_KV_CP_KEY, binary:compile_pattern(~"=")),
    persistent_term:put(?EXT_QUOTE_CP_KEY, binary:compile_pattern(~"\"")),
    persistent_term:put(?UPGRADE_CP_KEY, binary:compile_pattern(~"upgrade")),
    ok.
