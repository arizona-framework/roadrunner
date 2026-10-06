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
    request_pseudo_headers/1, check_request_authority/2, request_content_length/1, build_request/7
]).

-export_type([headers/0, status/0, redirect_status/0, version/0, request_context/0]).

-define(DATE_CACHE_KEY, {?MODULE, date_cache}).

-include("roadrunner_swar.hrl").

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
    | empty_path.

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
%% that want a boolean (the HTTP/3 response gate answers 500 instead of
%% crashing); most want `check_header_safe/2`.
-doc false.
-spec is_header_safe(binary()) -> boolean().
is_header_safe(<<X:56, Rest/binary>> = Bin) ->
    case ?SWAR_HIGH(?SWAR_BELOW(X, 16#0E)) of
        0 ->
            is_header_safe(Rest);
        _ ->
            <<Word:7/binary, _/binary>> = Bin,
            is_header_safe_bytes(Word) andalso is_header_safe(Rest)
    end;
is_header_safe(Tail) ->
    is_header_safe_bytes(Tail).

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
`strip_connection_specific_fields/1` for the response paths that crash
on injection (the HTTP/2 conn loop and the HTTP/3 trailer path): in one
traversal it rejects CR/LF/NUL in any name or value (crashing with
`{header_injection, Kind, Bin}`, like `check_header_safe/2`) and drops
the connection-specific fields h2/h3 MUST NOT generate. HTTP/3 response
headers answer 500 on injection instead of crashing, so they run the
non-crashing check and `strip_connection_specific_fields/1` separately.
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
validate_pseudo(_Method, _Scheme, _Authority, ~"", _Regular) ->
    {error, empty_path};
validate_pseudo(Method, Scheme, Authority, Path, Regular) when
    Method =/= undefined, Scheme =/= undefined, Path =/= undefined
->
    {ok, Method, Path, Authority, Regular};
validate_pseudo(_Method, _Scheme, _Authority, _Path, _Regular) ->
    {error, missing_pseudo_header}.

%% The request authority rule shared by HTTP/2 and HTTP/3 (RFC 9113 §8.3.1,
%% RFC 9114 §4.3.1). Roadrunner only serves `http` and `https`, both with a
%% mandatory authority component (QUIC is always `https`, and an HTTP/2
%% request's scheme is the connection's), so the request MUST carry an
%% `:authority` pseudo-header or a `host` header; if present neither is
%% empty, and if both appear they MUST match. The empty-value clauses
%% precede the equality clause so an empty value loses even when both
%% sides are equally empty.
-doc false.
-spec check_request_authority(binary() | undefined, headers()) ->
    ok | {error, missing_authority | empty_authority | authority_mismatch}.
check_request_authority(Authority, Regular) ->
    case {Authority, find_host(Regular)} of
        {undefined, undefined} -> {error, missing_authority};
        {~"", _} -> {error, empty_authority};
        {_, ~""} -> {error, empty_authority};
        {Same, Same} -> ok;
        {_, undefined} -> ok;
        {undefined, _} -> ok;
        {_, _} -> {error, authority_mismatch}
    end.

%% The first `host` header value, or `undefined`.
-spec find_host(headers()) -> binary() | undefined.
find_host([]) -> undefined;
find_host([{~"host", Value} | _]) -> Value;
find_host([_ | Rest]) -> find_host(Rest).

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
            _ -> [{~"host", Authority} | lists:keydelete(~"host", 1, Regular)]
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
        version => Version,
        headers => HeadersWithHost,
        body => Body,
        bindings => #{},
        peer => Peer,
        scheme => Scheme,
        request_id => RequestId,
        listener_name => ListenerName
    }.
