-module(roadrunner_http).
-moduledoc """
Protocol-version-agnostic HTTP semantics shared by HTTP/1.1
(`roadrunner_http1`) and HTTP/2 (`roadrunner_http2_*`) modules.

What lives here is RFC 9110 semantics — types and helpers whose
meaning doesn't depend on wire framing — not RFC 9112 syntax.
The HTTP/1.1 wire codec (request-line / header / chunked
parsers, status-line + CRLF response encoder) stays in
`roadrunner_http1`. HTTP/2 frame codec + HPACK live in their
own modules.

Items here:

- Header list shape: `[{binary(), binary()}]`.
- HTTP status codes: `100..599` and the redirect subset.
- Protocol version tuple: `{Major, Minor}`.
- IMF-fixdate formatter (`http_date_now/0` for the current
  time, `format_http_date/1` for an arbitrary posix timestamp)
  for the `Date` response header per RFC 9110 §5.6.7 and the
  `Last-Modified` response header used by the static handler.
- Header field-value safety (RFC 9110 §5.5): reject CR/LF/NUL in a
  header name or value before it reaches the wire
  (`check_header_safe/2`), shared by every version's response path.
- Connection-specific field stripping (RFC 9113 §8.2.2 / RFC 9114
  §4.2): drop the hop-by-hop fields HTTP/2 and HTTP/3 MUST NOT
  generate from a response field section
  (`strip_connection_specific_fields/1`), or do it fused with the
  field-value check in a single pass
  (`strip_connection_specific_fields_safe/1`); HTTP/1.1 honours these
  fields, so it does not strip.

`roadrunner_http1` and `roadrunner_req` re-export the primitive
types as aliases so existing callers keep compiling unchanged.
The request map shape lives in `roadrunner_req` alongside the
accessors that operate on it.
""".

-export([http_date_now/0, format_http_date/1, with_date/1, auto_headers/2]).
-export([with_defaults/2, drop_unset/1]).
-export([header_list_size/1]).
-export([check_header_safe/2, is_header_safe/1]).
-export([strip_connection_specific_fields/1, strip_connection_specific_fields_safe/1]).
-export([
    request_pseudo_headers/1,
    check_request_authority/3,
    valid_host/1,
    valid_target_bytes/1,
    check_fields/1,
    valid_field_name/1,
    valid_field_value/1,
    request_content_length/1,
    body_length_fits/3,
    build_request/7
]).

-export_type([headers/0, status/0, redirect_status/0, version/0, request_context/0]).

-define(DATE_CACHE_KEY, {?MODULE, date_cache}).

-include("roadrunner_swar.hrl").

%% Lanes holding a byte of at least `N` (`N` =< 0x80), exactly: each
%% lane's high bit is set before the subtraction, so no borrow crosses
%% into the next lane and no lane is flagged by its neighbour. Only
%% meaningful for lanes below 0x80; the caller rules the others out.
-define(SWAR_AT_LEAST(X, N),
    ((((X) bor ?SWAR_BYTES(128)) - ?SWAR_BYTES(N)) band ?SWAR_BYTES(128))
).

-type headers() :: [{Name :: binary(), Value :: binary()}].
-type status() :: 100..599.
-type redirect_status() :: 300..399.
-type version() :: {1, 0} | {1, 1} | {2, 0} | {3, 0}.
%% The per-connection fields an HTTP/2 or HTTP/3 connection passes to
%% build a request.
-type request_context() :: #{
    peer := {inet:ip_address(), inet:port_number()} | undefined,
    scheme := http | https,
    request_id := binary(),
    listener_name := atom()
}.
%% Why `request_pseudo_headers/1` rejects an HTTP/2 or HTTP/3 request's
%% pseudo-header section.
-type pseudo_error() ::
    missing_pseudo_header
    | duplicate_pseudo_header
    | unknown_pseudo_header
    | pseudo_after_regular
    | empty_path
    | bad_path
    | bad_connect
    | not_implemented.

-define(DAY_NAMES, {~"Mon", ~"Tue", ~"Wed", ~"Thu", ~"Fri", ~"Sat", ~"Sun"}).
-define(MONTH_NAMES, {
    ~"Jan", ~"Feb", ~"Mar", ~"Apr", ~"May", ~"Jun", ~"Jul", ~"Aug", ~"Sep", ~"Oct", ~"Nov", ~"Dec"
}).

-doc """
Format the current UTC time as an IMF-fixdate per RFC 9110 §5.6.7
— the canonical HTTP `Date` header format, e.g.
`Sun, 06 Nov 1994 08:49:37 GMT`. Used by the dispatch layer to
auto-inject the `Date` response header per RFC 9110 §6.6.1.

Built via direct bit-syntax binary construction rather than
`io_lib:format/2` because the shape is fixed (RFC 9110 mandates
exact widths and the day/month abbreviations) and this function
runs on the response hot path.

Cached per process in the process dictionary, keyed by the current
Posix second: the formatted binary is identical for every response
a process emits within the same second, so we recompute it only when
the second ticks over. Per-process rather than via `persistent_term`
because the value changes every second, and a `persistent_term:put`
that frequent forces a global scan of every process heap on the
response hot path; the per-process cache pays a cheap dictionary read
instead, and reformats at most once per second per process: once per
connection on h1/h2, once per request on h3 (its stream workers are
per-request).
""".
-spec http_date_now() -> binary().
http_date_now() ->
    Now = erlang:system_time(second),
    case get(?DATE_CACHE_KEY) of
        {Now, Bin} ->
            Bin;
        _ ->
            Bin = format_http_date(Now),
            _ = put(?DATE_CACHE_KEY, {Now, Bin}),
            Bin
    end.

-doc """
Inject a `Date` response header (RFC 9110 §6.6.1) unless the handler
already set one. Shared by the HTTP/1, HTTP/2, and HTTP/3 response
paths so every response carries `Date` from the one cached clock
(`http_date_now/0`). RFC 9110 makes `Date` a MUST on 2xx/3xx/4xx and
a MAY on 1xx/5xx, so injecting it unconditionally is conformant.
""".
-spec with_date(headers()) -> headers().
with_date(Headers) ->
    case lists:keymember(~"date", 1, Headers) of
        true -> Headers;
        false -> [{~"date", http_date_now()} | Headers]
    end.

-doc """
Inject the framework's automatic response headers for an HTTP/1 or
HTTP/2 (TCP) response: `Date` always (RFC 9110 §6.6.1) plus `Alt-Svc`
advertising the listener's HTTP/3 endpoint (RFC 7838) when it co-serves
h3 on a fixed port. The caller passes the precomputed `Alt-Svc` value
(cached on the connection loop record), or `undefined` when no h3 is
co-served. HTTP/3 responses use `with_date/1` directly — a client
already on h3 needs no Alt-Svc.
""".
-spec auto_headers(headers(), binary() | undefined) -> headers().
auto_headers(Headers, AltSvc) ->
    with_alt_svc(with_date(Headers), AltSvc).

%% Prepend the precomputed `Alt-Svc` value when the listener co-serves
%% h3 — `undefined` otherwise. `Alt-Svc` is list-valued (RFC 7838 §3 /
%% RFC 9110 §5.3), so it composes with any handler-set value; no de-dup
%% needed (unlike the singular `Date`).
-spec with_alt_svc(headers(), binary() | undefined) -> headers().
with_alt_svc(Headers, undefined) ->
    Headers;
with_alt_svc(Headers, AltSvc) ->
    [{~"alt-svc", AltSvc} | Headers].

%% Prepend each default the headers don't already carry, so a handler-set
%% value always wins. Body recursion preserves the default order. Used by
%% middlewares (`roadrunner_cors`, `roadrunner_security_headers`) to merge
%% their pre-built header set onto the handler's response. Headers-first,
%% matching `with_date/1` / `with_alt_svc/2`.
-doc false.
-spec with_defaults(headers(), Defaults :: headers()) -> headers().
with_defaults(Headers, []) ->
    Headers;
with_defaults(Headers, [{Name, _} = Default | Rest]) ->
    case lists:keymember(Name, 1, Headers) of
        true -> with_defaults(Headers, Rest);
        false -> [Default | with_defaults(Headers, Rest)]
    end.

%% Drop the candidates whose value resolved to `false` (the header doesn't
%% apply), leaving a plain header list. Middlewares call this once, at compile
%% time, so the per-request `with_defaults/2` only ever prepends real headers.
-doc false.
-spec drop_unset([{binary(), binary() | false}]) -> headers().
drop_unset(Candidates) ->
    [Header || {_Name, Value} = Header <- Candidates, Value =/= false].

%% RFC 7541 §4.1: the uncompressed size of a header list is the sum over
%% its fields of `byte_size(Name) + byte_size(Value) + 32`. This is the
%% unit bounded by SETTINGS_MAX_HEADER_LIST_SIZE (h2, RFC 9113 §6.5.2)
%% and SETTINGS_MAX_FIELD_SECTION_SIZE (h3, RFC 9114 §7.2.4.1), distinct
%% from the compressed on-wire block the `max_header_block` cap bounds.
-doc false.
-spec header_list_size(headers()) -> non_neg_integer().
header_list_size([{Name, Value} | Rest]) ->
    byte_size(Name) + byte_size(Value) + 32 + header_list_size(Rest);
header_list_size([]) ->
    0.

-doc """
Format a posix timestamp (seconds since epoch) as an IMF-fixdate
per RFC 9110 §5.6.7. Same shape as `http_date_now/0` but for an
explicit timestamp — used by the static file handler to emit the
`Last-Modified` header for a file's mtime.
""".
-spec format_http_date(integer()) -> binary().
format_http_date(Posix) ->
    {{Y, M, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Posix, second),
    DayName = element(calendar:day_of_the_week(Y, M, D), ?DAY_NAMES),
    MonthName = element(M, ?MONTH_NAMES),
    <<DayName/binary, ", ", (pad2(D))/binary, " ", MonthName/binary, " ",
        (integer_to_binary(Y))/binary, " ", (pad2(H))/binary, ":", (pad2(Mi))/binary, ":",
        (pad2(S))/binary, " GMT">>.

%% Two-digit zero-padded integer for the IMF-fixdate fields. Year is
%% 4-digit (always — calendar guarantees positive 4-digit years for
%% modern timestamps), so `integer_to_binary/1` suffices there; only
%% the day/hour/minute/second need the leading-zero pad when < 10.
-spec pad2(0..99) -> binary().
pad2(N) when N < 10 -> <<$0, ($0 + N)>>;
pad2(N) -> integer_to_binary(N).

-doc """
Validate that a header name or value contains no CR, LF, or NUL —
the bytes that would let an attacker who controls the value inject
new headers (or terminate the header block early). Crashes with
`{header_injection, Kind, Bin}` when an unsafe byte is present.

Public so any response path emitting a single header (e.g.
`roadrunner_stream_response` for chunked-response trailers) can run
the check before writing to the wire.
""".
-spec check_header_safe(binary(), name | value) -> ok.
check_header_safe(Bin, Kind) ->
    case is_header_safe(Bin) of
        true -> ok;
        false -> error({header_injection, Kind, Bin})
    end.

%% `true` when `Bin` holds no CR, LF or NUL. SWAR, 7 bytes per step (see
%% `roadrunner_swar.hrl`): a word with no byte below 0x0E is safe; a word
%% that flags, a tab or another low control byte, gets the exact byte
%% check. 30-65% faster than `binary:match/2` with a
%% compiled CR/LF/NUL pattern from 3 bytes up. Exported for the callers
%% that want a boolean (the HTTP/2 and HTTP/3 response gate answers 500
%% instead of crashing); most want `check_header_safe/2`.
-doc false.
%% Two 7-byte words per step, then at most one more word, then the last 0
%% to 6 bytes as a single integer (`header_safe_tail/1`), so no clean byte
%% is walked one at a time (a 97-byte User-Agent 67 -> 47 ns, a 4-byte
%% value 26 -> 17 ns). A flagged word or tail is checked byte by byte.
-spec is_header_safe(binary()) -> boolean().
is_header_safe(<<X:56, Y:56, Rest/binary>> = Bin) ->
    case ?SWAR_HIGH(?SWAR_BELOW(X, 16#0E) bor ?SWAR_BELOW(Y, 16#0E)) of
        0 ->
            is_header_safe(Rest);
        _ ->
            <<Words:14/binary, _/binary>> = Bin,
            is_header_safe_bytes(Words) andalso is_header_safe(Rest)
    end;
is_header_safe(<<X:56, Rest/binary>> = Bin) ->
    case ?SWAR_HIGH(?SWAR_BELOW(X, 16#0E)) of
        0 -> header_safe_tail(Rest);
        _ -> is_header_safe_bytes(Bin)
    end;
is_header_safe(Tail) ->
    header_safe_tail(Tail).

%% The last 0 to 6 bytes as one integer, tested like a word with the lane
%% constants cut to its size (`?SWAR_BELOW(X, 16#0E)` and `?SWAR_HIGH/1`
%% over N lanes): one clause per size keeps the constants literal.
-spec header_safe_tail(binary()) -> boolean().
header_safe_tail(<<X:48>> = Tail) ->
    header_safe_lanes(X, 16#0E0E0E0E0E0E, 16#FFFFFFFFFFFF, 16#808080808080, Tail);
header_safe_tail(<<X:40>> = Tail) ->
    header_safe_lanes(X, 16#0E0E0E0E0E, 16#FFFFFFFFFF, 16#8080808080, Tail);
header_safe_tail(<<X:32>> = Tail) ->
    header_safe_lanes(X, 16#0E0E0E0E, 16#FFFFFFFF, 16#80808080, Tail);
header_safe_tail(<<X:24>> = Tail) ->
    header_safe_lanes(X, 16#0E0E0E, 16#FFFFFF, 16#808080, Tail);
header_safe_tail(<<X:16>> = Tail) ->
    header_safe_lanes(X, 16#0E0E, 16#FFFF, 16#8080, Tail);
header_safe_tail(<<X:8>> = Tail) ->
    header_safe_lanes(X, 16#0E, 16#FF, 16#80, Tail);
header_safe_tail(<<>>) ->
    true.

-spec header_safe_lanes(
    non_neg_integer(), pos_integer(), pos_integer(), pos_integer(), binary()
) -> boolean().
header_safe_lanes(X, Below, All, High, Tail) ->
    case ((X - Below) band (X bxor All)) band High of
        0 -> true;
        _ -> is_header_safe_bytes(Tail)
    end.

-spec is_header_safe_bytes(binary()) -> boolean().
is_header_safe_bytes(<<0, _/binary>>) -> false;
is_header_safe_bytes(<<$\n, _/binary>>) -> false;
is_header_safe_bytes(<<$\r, _/binary>>) -> false;
is_header_safe_bytes(<<_, Rest/binary>>) -> is_header_safe_bytes(Rest);
is_header_safe_bytes(<<>>) -> true.

-doc """
Drop connection-specific header fields from an HTTP/2 or HTTP/3
response field section. RFC 9113 §8.2.2 and RFC 9114 §4.2 forbid
*generating* `connection`, `keep-alive`, `proxy-connection`,
`transfer-encoding`, or `upgrade` over those protocols — they are
hop-by-hop fields (RFC 9110 §7.6.1) meaningful only on an HTTP/1.1
connection. A handler shared across protocols may set one (e.g.
`connection: close`, idiomatic on h1); stripping it on h2/h3 keeps that
handler working while staying conformant, since the framework never
puts the field on the wire. HTTP/1.1 honours these fields, so its
response path does not strip.
""".
-spec strip_connection_specific_fields(headers()) -> headers().
strip_connection_specific_fields(Headers) ->
    [Field || {Name, _} = Field <- Headers, not connection_specific_field(Name)].

-doc """
Single-pass combination of `check_header_safe/2` and
`strip_connection_specific_fields/1` for the HTTP/2 and HTTP/3 trailer
paths, which crash on injection because the status is already sent: in
one traversal it rejects CR/LF/NUL in any name or value (crashing with
`{header_injection, Kind, Bin}`, like `check_header_safe/2`) and drops
the connection-specific fields h2/h3 MUST NOT generate. HTTP/2 and
HTTP/3 response headers answer 500 on injection instead of crashing, so
they run the non-crashing check and `strip_connection_specific_fields/1`
separately.
""".
-spec strip_connection_specific_fields_safe(headers()) -> headers().
%% One pass: check CR/LF/NUL on every field (including ones about to be
%% dropped, matching the prior two-pass behaviour) and cons the field
%% only when it is not connection-specific. Mirrors h1's fused
%% `encode_headers/1`.
strip_connection_specific_fields_safe([]) ->
    [];
strip_connection_specific_fields_safe([{Name, Value} = Field | Rest]) ->
    ok = check_header_safe(Name, name),
    ok = check_header_safe(Value, value),
    case connection_specific_field(Name) of
        true -> strip_connection_specific_fields_safe(Rest);
        false -> [Field | strip_connection_specific_fields_safe(Rest)]
    end.

%% The RFC 9110 §7.6.1 connection-specific (hop-by-hop) field names that
%% RFC 9113 §8.2.2 / RFC 9114 §4.2 forbid an h2/h3 endpoint from
%% generating. Function-clause dispatch mirrors the request-side
%% `check_banned/1` in `roadrunner_http2_request` / `roadrunner_http3_request`.
-spec connection_specific_field(binary()) -> boolean().
connection_specific_field(~"connection") -> true;
connection_specific_field(~"keep-alive") -> true;
connection_specific_field(~"proxy-connection") -> true;
connection_specific_field(~"transfer-encoding") -> true;
connection_specific_field(~"upgrade") -> true;
connection_specific_field(_) -> false.

%% `Regular` without its `host` field. HTTP/2 and HTTP/3 clients usually
%% send `:authority` alone, and `lists:keydelete/3` rebuilds the whole list
%% when the key is absent, so look first: `lists:keymember/3` scans without
%% allocating (8 headers: 92 -> 58 ns).
-spec without_host(headers()) -> headers().
without_host(Regular) ->
    case lists:keymember(~"host", 1, Regular) of
        true -> lists:keydelete(~"host", 1, Regular);
        false -> Regular
    end.

%% The request pseudo-header section shared by HTTP/2 and HTTP/3 (RFC
%% 9113 §8.3.1, RFC 9114 §4.3.1): the same four pseudo-headers under the
%% same rules. Returns them with the regular headers after them; each
%% protocol's own checks on those regular headers run in its request
%% module.
-doc false.
-spec request_pseudo_headers(headers()) ->
    {ok, Method :: binary(), Path :: binary(), Authority :: binary() | undefined, headers()}
    | {error, pseudo_error()}.
request_pseudo_headers(Headers) ->
    pseudo(Headers, undefined, undefined, undefined, undefined).

%% Collect the leading pseudo-headers (names starting with `:`) into
%% arguments, `undefined` until seen, then check that none follows the
%% first regular header and hand back that tail of the list as is. No
%% map and no rebuilt header list (a 6-header HTTP/2 request: 283 ns ->
%% 108 ns, against partitioning into a map plus a reversed accumulator).
%% Errors keep their order: a bad, duplicate or misplaced pseudo-header
%% first, then a missing one or an empty `:path`.
-spec pseudo(
    headers(),
    binary() | undefined,
    binary() | undefined,
    binary() | undefined,
    binary() | undefined
) ->
    {ok, binary(), binary(), binary() | undefined, headers()}
    | {error, pseudo_error()}.
pseudo([{~":method", Value} | Rest], undefined, Scheme, Authority, Path) ->
    pseudo(Rest, Value, Scheme, Authority, Path);
pseudo([{~":scheme", Value} | Rest], Method, undefined, Authority, Path) ->
    pseudo(Rest, Method, Value, Authority, Path);
pseudo([{~":authority", Value} | Rest], Method, Scheme, undefined, Path) ->
    pseudo(Rest, Method, Scheme, Value, Path);
pseudo([{~":path", Value} | Rest], Method, Scheme, Authority, undefined) ->
    pseudo(Rest, Method, Scheme, Authority, Value);
pseudo([{Name, _} | _], _Method, _Scheme, _Authority, _Path) when
    Name =:= ~":method"; Name =:= ~":scheme"; Name =:= ~":authority"; Name =:= ~":path"
->
    {error, duplicate_pseudo_header};
pseudo([{<<":", _/binary>>, _} | _], _Method, _Scheme, _Authority, _Path) ->
    {error, unknown_pseudo_header};
pseudo(Regular, Method, Scheme, Authority, Path) ->
    case no_pseudo(Regular) of
        ok -> validate_pseudo(Method, Scheme, Authority, Path, Regular);
        {error, _} = E -> E
    end.

%% A pseudo-header arriving after a regular header is malformed (RFC 9113
%% §8.1.2.1, RFC 9114 §4.3.1).
-spec no_pseudo(headers()) -> ok | {error, pseudo_after_regular}.
no_pseudo([{<<":", _/binary>>, _} | _]) -> {error, pseudo_after_regular};
no_pseudo([_ | Rest]) -> no_pseudo(Rest);
no_pseudo([]) -> ok.

-spec validate_pseudo(
    binary() | undefined,
    binary() | undefined,
    binary() | undefined,
    binary() | undefined,
    headers()
) ->
    {ok, binary(), binary(), binary() | undefined, headers()}
    | {error, pseudo_error()}.
%% CONNECT carries only `:method` and `:authority` (RFC 9113 §8.5, RFC 9114
%% §4.4); roadrunner doesn't open tunnels, so a well-formed one is not
%% implemented (a 501, as on HTTP/1.1) and one with a `:scheme` or a
%% `:path` is malformed (no extended CONNECT is advertised). Any other
%% request needs `:method`, `:scheme` and a `:path` holding an
%% origin-form (`/` then US-ASCII without CTL, SP or DEL), or `*` for a
%% server-wide OPTIONS (RFC 9113 §8.3.1, RFC 9114 §4.3.1): the same
%% target rules HTTP/1.1 applies.
validate_pseudo(~"CONNECT", undefined, Authority, undefined, _Regular) when
    Authority =/= undefined
->
    {error, not_implemented};
validate_pseudo(~"CONNECT", _Scheme, _Authority, _Path, _Regular) ->
    {error, bad_connect};
validate_pseudo(_Method, _Scheme, _Authority, ~"", _Regular) ->
    {error, empty_path};
validate_pseudo(Method, Scheme, Authority, Path, Regular) when
    Method =/= undefined, Scheme =/= undefined, Path =/= undefined
->
    case valid_path(Method, Path) of
        true -> {ok, Method, Path, Authority, Regular};
        false -> {error, bad_path}
    end;
validate_pseudo(_Method, _Scheme, _Authority, _Path, _Regular) ->
    {error, missing_pseudo_header}.

-spec valid_path(binary(), binary()) -> boolean().
valid_path(_Method, <<$/, _/binary>> = Path) -> valid_target_bytes(Path);
valid_path(~"OPTIONS", ~"*") -> true;
valid_path(_Method, _Path) -> false.

%% Request-target bytes, shared by the HTTP/1.1 request line and the
%% HTTP/2 and HTTP/3 `:path`: US-ASCII (RFC 3986 §2; raw UTF-8 or other
%% high bytes must be percent-encoded) without CTL, SP or DEL, and
%% without `#` or `\\`. A fragment is never part of a request-target (RFC
%% 9112 §3.2) and browsers don't send one; a backslash is no URI byte, and
%% browsers turn it into `/` for http(s), so a raw one only comes from a
%% client that another server could normalize differently. The other
%% bytes RFC 3986 leaves out (`{` `}` `|` `^` `` ` `` and `"` `<` `>`)
%% stay accepted: browsers send several of them unencoded, per the WHATWG
%% URL standard's percent-encode sets.
-doc false.
-spec valid_target_bytes(binary()) -> boolean().
valid_target_bytes(<<C, Rest/binary>>) when C > 16#20, C < 16#7F, C =/= $#, C =/= $\\ ->
    valid_target_bytes(Rest);
valid_target_bytes(<<>>) ->
    true;
valid_target_bytes(_) ->
    false.

%% Field validity shared by HTTP/2 and HTTP/3 (RFC 9113 §8.2.1, RFC 9114
%% §4.2). HTTP/2 applies the two predicates as HPACK decodes each literal
%% field, so a field the dynamic table repeats is checked once per
%% connection; HTTP/3 (whose QPACK keeps no dynamic table) runs
%% `check_fields/1` over each request's fields. A request breaking them
%% is malformed, so a CR or LF never reaches a handler that copies a
%% value into something line-based.
-doc false.
-spec check_fields(headers()) -> ok | {error, bad_field_name | bad_field_value}.
check_fields([{Name, Value} | Rest]) ->
    case valid_field_name(Name) of
        true ->
            case valid_field_value(Value) of
                true -> check_fields(Rest);
                false -> {error, bad_field_value}
            end;
        false ->
            {error, bad_field_name}
    end;
check_fields([]) ->
    ok.

%% A field name is visible US-ASCII without uppercase letters or `:`,
%% after a pseudo-header's leading colon (which pseudo-headers are known
%% is `request_pseudo_headers/1`'s call).
-doc false.
-spec valid_field_name(binary()) -> boolean().
valid_field_name(<<$:, Name/binary>>) -> field_name(Name);
valid_field_name(Name) -> field_name(Name).

-spec field_name(binary()) -> boolean().
field_name(<<>>) -> false;
field_name(Name) -> field_name_bytes(Name).

-spec field_name_bytes(binary()) -> boolean().
field_name_bytes(<<C, Rest/binary>>) when C >= $a, C =< $z; C =:= $- ->
    field_name_bytes(Rest);
field_name_bytes(<<C, _/binary>>) when C >= $A, C =< $Z; C =:= $: ->
    false;
field_name_bytes(<<C, Rest/binary>>) when C > 16#20, C < 16#7F ->
    field_name_bytes(Rest);
field_name_bytes(<<>>) ->
    true;
field_name_bytes(_) ->
    false.

%% A field value holds no NUL, CR or LF, and neither starts nor ends with
%% SP or HTAB.
-doc false.
-spec valid_field_value(binary()) -> boolean().
valid_field_value(<<>>) ->
    true;
valid_field_value(<<C, _/binary>>) when C =:= $\s; C =:= $\t ->
    false;
valid_field_value(Value) ->
    case binary:last(Value) of
        C when C =:= $\s; C =:= $\t -> false;
        _ -> is_header_safe(Value)
    end.

%% The request authority rule shared by HTTP/2 and HTTP/3 (RFC 9113 §8.3.1,
%% RFC 9114 §4.3.1). Roadrunner only serves `http` and `https`, both with a
%% mandatory authority component (QUIC is always `https`, and an HTTP/2
%% request's scheme is the connection's), so the request MUST carry an
%% `:authority` pseudo-header or a `host` header; if present neither is
%% empty, each is a `uri-host [":" port]` (`valid_host/1`, which also
%% refuses the userinfo RFC 9113 §8.3.1 forbids), and if both appear they
%% MUST name the same entity. The empty-value clauses come first so an
%% empty value keeps its own reason. Byte-equal values, what every real
%% client sends, match without normalizing.
-doc false.
-spec check_request_authority(binary() | undefined, headers(), http | https) ->
    ok
    | {error,
        missing_authority
        | empty_authority
        | bad_authority
        | authority_mismatch
        | duplicate_host}.
check_request_authority(Authority, Regular, Scheme) ->
    case {Authority, find_host(Regular)} of
        {_, multiple} ->
            {error, duplicate_host};
        {undefined, undefined} ->
            {error, missing_authority};
        {~"", _} ->
            {error, empty_authority};
        {_, ~""} ->
            {error, empty_authority};
        {_, Host} ->
            case valid_present_host(Authority) andalso valid_present_host(Host) of
                true -> same_authority(Authority, Host, Scheme);
                false -> {error, bad_authority}
            end
    end.

-spec valid_present_host(binary() | undefined) -> boolean().
valid_present_host(undefined) -> true;
valid_present_host(Value) -> valid_host(Value).

-spec same_authority(binary() | undefined, binary() | undefined, http | https) ->
    ok | {error, authority_mismatch}.
same_authority(Same, Same, _Scheme) ->
    ok;
same_authority(_Authority, undefined, _Scheme) ->
    ok;
same_authority(undefined, _Host, _Scheme) ->
    ok;
same_authority(Authority, Host, Scheme) ->
    case normalize_authority(Authority, Scheme) =:= normalize_authority(Host, Scheme) of
        true -> ok;
        false -> {error, authority_mismatch}
    end.

%% Whether a Host field value (or an HTTP/2 or HTTP/3 `:authority`) is a
%% `uri-host [":" port]` with a non-empty host (RFC 9110 §7.2 and §4.2.1,
%% RFC 3986 §3.2.2): a bracketed IP literal or a reg-name (which also
%% covers IPv4), then an optional `:` and digits. A userinfo `@`, a path,
%% whitespace or a second host after a comma all fall outside it, and RFC
%% 9112 §3.2 answers such a Host with 400. The host stays as sent; this
%% only decides whether it is well formed.
-doc false.
-spec valid_host(binary()) -> boolean().
valid_host(<<$[, Rest/binary>>) -> ip_literal(Rest, false);
valid_host(Value) -> reg_name_words(Value, false).

%% A host name is mostly letters, digits, `.` and `-`: take it 7 bytes at
%% a time while every byte is one of those, then let `reg_name/2` walk the
%% rest (the port, any other reg-name byte, or what makes it invalid)
%% byte by byte, which stays the authority on the grammar. Folding with
%% 0x20 lowercases letters; a control byte that the fold would turn into
%% `-`, `.` or a digit is still refused by the `>= 0x2D` test on the
%% unfolded byte, and a byte >= 0x80 by its own high bit.
-spec reg_name_words(binary(), boolean()) -> boolean().
reg_name_words(<<X:56, Rest/binary>> = Bin, Any) ->
    L = X bor ?SWAR_BYTES(16#20),
    High = ?SWAR_BYTES(128),
    Plain =
        ?SWAR_AT_LEAST(X, 16#2D) band (High bxor (X band High)) band
            ((?SWAR_AT_LEAST(L, 16#2D) band (?SWAR_AT_LEAST(L, 16#2F) bxor High)) bor
                (?SWAR_AT_LEAST(L, 16#30) band (?SWAR_AT_LEAST(L, 16#3A) bxor High)) bor
                (?SWAR_AT_LEAST(L, 16#61) band (?SWAR_AT_LEAST(L, 16#7B) bxor High))),
    case Plain of
        High -> reg_name_words(Rest, true);
        _ -> reg_name(Bin, Any)
    end;
reg_name_words(Bin, Any) ->
    reg_name(Bin, Any).

-spec reg_name(binary(), boolean()) -> boolean().
reg_name(<<C, Rest/binary>>, _Any) when
    C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9
->
    reg_name(Rest, true);
reg_name(<<$%, H1, H2, Rest/binary>>, _Any) ->
    is_hex_digit(H1) andalso is_hex_digit(H2) andalso reg_name(Rest, true);
reg_name(<<$:, Port/binary>>, true) ->
    port_digits(Port);
reg_name(<<C, Rest/binary>>, _Any) ->
    is_host_mark(C) andalso reg_name(Rest, true);
reg_name(<<>>, Any) ->
    Any.

%% RFC 3986 §3.2.2: `"[" ( IPv6address / IPvFuture ) "]"`. The bracket
%% content is held to the bytes those two forms use (hex digits, `:`,
%% `.`, and IPvFuture's unreserved and sub-delims), not parsed as an
%% address: what matters here is that nothing outside the authority
%% grammar gets in.
-spec ip_literal(binary(), boolean()) -> boolean().
ip_literal(<<$], Rest/binary>>, true) ->
    case Rest of
        <<>> -> true;
        <<$:, Port/binary>> -> port_digits(Port);
        _ -> false
    end;
ip_literal(<<C, Rest/binary>>, _Any) when
    C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9; C =:= $:
->
    ip_literal(Rest, true);
ip_literal(<<C, Rest/binary>>, _Any) ->
    is_host_mark(C) andalso ip_literal(Rest, true);
ip_literal(<<>>, _Any) ->
    false.

%% `port = *DIGIT` (RFC 3986 §3.2.3); an empty port is allowed.
-spec port_digits(binary()) -> boolean().
port_digits(<<C, Rest/binary>>) when C >= $0, C =< $9 -> port_digits(Rest);
port_digits(<<>>) -> true;
port_digits(_) -> false.

%% The non-alphanumeric unreserved and sub-delims bytes (RFC 3986 §2.2,
%% §2.3), which a reg-name and an IPvFuture literal may hold.
-spec is_host_mark(byte()) -> boolean().
is_host_mark(C) when
    C =:= $-;
    C =:= $.;
    C =:= $_;
    C =:= $~;
    C =:= $!;
    C =:= $$;
    C =:= $&;
    C =:= $';
    C =:= $(;
    C =:= $);
    C =:= $*;
    C =:= $+;
    C =:= $,;
    C =:= $;;
    C =:= $=
->
    true;
is_host_mark(_) ->
    false.

-spec is_hex_digit(byte()) -> boolean().
is_hex_digit(C) when C >= $0, C =< $9; C >= $a, C =< $f; C >= $A, C =< $F -> true;
is_hex_digit(_) -> false.

%% RFC 3986 §6.2 normalization of an `http`/`https` authority, which RFC
%% 9113 §8.3.1 asks for before comparing `:authority` with `host`: the
%% host is case-insensitive (§6.2.2.1; an http authority carries no
%% userinfo and the port is digits, so the whole value is lowercased),
%% and the scheme's default port or an empty port is the same as no port
%% (§6.2.3). Percent-encoded reg-names are left as sent.
-spec normalize_authority(binary(), http | https) -> binary().
normalize_authority(Authority, Scheme) ->
    drop_default_port(roadrunner_bin:ascii_lowercase(Authority), default_port(Scheme)).

-spec default_port(http | https) -> binary().
default_port(http) -> ~":80";
default_port(https) -> ~":443".

-spec drop_default_port(binary(), binary()) -> binary().
drop_default_port(Authority, Port) ->
    HostSize = byte_size(Authority) - byte_size(Port),
    case Authority of
        <<Host:HostSize/binary, Port/binary>> -> Host;
        <<Host:(byte_size(Authority) - 1)/binary, ":">> -> Host;
        _ -> Authority
    end.

%% The `host` header value, `undefined` without one, or `multiple` when
%% it appears more than once: a second `host` could otherwise name a
%% different entity than the one checked and still reach the handler.
-spec find_host(headers()) -> binary() | undefined | multiple.
find_host([]) ->
    undefined;
find_host([{~"host", Value} | Rest]) ->
    case lists:keymember(~"host", 1, Rest) of
        true -> multiple;
        false -> Value
    end;
find_host([_ | Rest]) ->
    find_host(Rest).

%% Whether `Len` request body bytes agree with the request's declared
%% `content-length` (`request_content_length/1`): never past it, and exactly
%% it once the body has `Ended`. No header always agrees; a malformed one
%% never does (RFC 9113 §8.1.1, RFC 9114 §4.1.2).
-doc false.
-spec body_length_fits(none | {ok, non_neg_integer()} | error, non_neg_integer(), boolean()) ->
    boolean().
body_length_fits(none, _Len, _Ended) -> true;
body_length_fits({ok, Declared}, Len, false) -> Len =< Declared;
body_length_fits({ok, Declared}, Len, true) -> Len =:= Declared;
body_length_fits(error, _Len, _Ended) -> false.

%% The `content-length` of an HTTP/2 or HTTP/3 request, which the caller
%% compares with the bytes its DATA frames carried (RFC 9113 §8.1.1, RFC
%% 9114 §4.1.2): `none` without the header, `error` for a repeated or
%% non-integer one. Single-pass walk: find the first value and check
%% there isn't a second.
-doc false.
-spec request_content_length(headers()) -> none | {ok, non_neg_integer()} | error.
request_content_length(Headers) ->
    case find_content_length(Headers, undefined) of
        none ->
            none;
        multiple ->
            error;
        Value ->
            roadrunner_bin:digits_to_integer(Value)
    end.

-spec find_content_length(headers(), binary() | undefined) -> binary() | none | multiple.
find_content_length([], undefined) ->
    none;
find_content_length([], Value) ->
    Value;
find_content_length([{~"content-length", _} | _], Value) when Value =/= undefined ->
    multiple;
find_content_length([{~"content-length", Value} | Rest], undefined) ->
    find_content_length(Rest, Value);
find_content_length([_ | Rest], Value) ->
    find_content_length(Rest, Value).

%% Build the request map for a validated HTTP/2 or HTTP/3 request. The
%% `:authority` pseudo-header is forwarded as a `host` header so handler
%% code that reads `Host` still works (RFC 9113 §8.3.1 and RFC 9114
%% §4.3.1 treat `:authority` like `Host`); a client-sent `host`, already
%% checked equal by `check_request_authority/2`, is dropped first so a
%% single canonical entry survives instead of a duplicate. The connection
%% loop always builds `RequestContext` with all four fields, so it is
%% destructured in one match rather than four `maps:get/3` calls.
-doc false.
-spec build_request(
    version(),
    binary(),
    binary(),
    binary() | undefined,
    headers(),
    iodata(),
    request_context()
) -> roadrunner_req:request().
build_request(Version, Method, Path, Authority, Regular, Body, RequestContext) ->
    HeadersWithHost =
        case Authority of
            undefined -> Regular;
            _ -> [{~"host", Authority} | without_host(Regular)]
        end,
    #{
        peer := Peer,
        scheme := Scheme,
        request_id := RequestId,
        listener_name := ListenerName
    } = RequestContext,
    #{
        method => Method,
        target => Path,
        path => roadrunner_req:target_path(Path),
        version => Version,
        headers => HeadersWithHost,
        body => Body,
        bindings => #{},
        peer => Peer,
        scheme => Scheme,
        request_id => RequestId,
        listener_name => ListenerName
    }.
