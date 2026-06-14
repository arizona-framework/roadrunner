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
-export([check_header_safe/2, check_header_safe/3]).
-export([unsafe_bytes_pattern/0]).
-export([strip_connection_specific_fields/1, strip_connection_specific_fields_safe/1]).

-export_type([headers/0, status/0, redirect_status/0, version/0]).

-on_load(init_patterns/0).

-define(DATE_CACHE_KEY, {?MODULE, date_cache}).
-define(UNSAFE_BYTES_KEY, {?MODULE, unsafe_bytes_cp}).

-type headers() :: [{Name :: binary(), Value :: binary()}].
-type status() :: 100..599.
-type redirect_status() :: 300..399.
-type version() :: {1, 0} | {1, 1} | {2, 0} | {3, 0}.

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

%% Prepend each candidate the existing list doesn't already carry, so a
%% handler-set value always wins. Body recursion preserves candidate order.
%% Used by middlewares (`roadrunner_cors`, `roadrunner_security_headers`) to
%% merge their pre-built header set onto the handler's response.
-doc false.
-spec with_defaults(Defaults :: headers(), headers()) -> headers().
with_defaults([], Headers) ->
    Headers;
with_defaults([{Name, _} = Default | Rest], Headers) ->
    case lists:keymember(Name, 1, Headers) of
        true -> with_defaults(Rest, Headers);
        false -> [Default | with_defaults(Rest, Headers)]
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
check_header_safe(Bin, Kind) when is_binary(Bin) ->
    check_header_safe(Bin, Kind, persistent_term:get(?UNSAFE_BYTES_KEY)).

%% Accepts a pre-fetched pattern so a caller iterating a header list
%% (`strip_connection_specific_fields_safe/1`, or h1's fused
%% `encode_headers/1`) pays one `persistent_term:get/1` instead of one
%% per field. Exported for those; most callers want `check_header_safe/2`.
-doc false.
-spec check_header_safe(binary(), name | value, binary:cp()) -> ok.
check_header_safe(Bin, Kind, UnsafeCp) when is_binary(Bin) ->
    case binary:match(Bin, UnsafeCp) of
        nomatch -> ok;
        _ -> error({header_injection, Kind, Bin})
    end.

%% The compiled CR/LF/NUL pattern, for a caller that runs the check in a
%% loop and wants a single `persistent_term:get/1` for the whole list:
%% h1's fused `encode_headers/1`, the fused
%% `strip_connection_specific_fields_safe/1`, and the HTTP/3 emit gate
%% (all via `check_header_safe/3` or inline `binary:match`). Callers not
%% already iterating want `check_header_safe/2`.
-doc false.
-spec unsafe_bytes_pattern() -> binary:cp().
unsafe_bytes_pattern() ->
    persistent_term:get(?UNSAFE_BYTES_KEY).

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
strip_connection_specific_fields_safe(Headers) ->
    strip_connection_specific_fields_safe(Headers, persistent_term:get(?UNSAFE_BYTES_KEY)).

%% One pass with the pre-fetched pattern: check CR/LF/NUL on every field
%% (including ones about to be dropped, matching the prior two-pass
%% behaviour) and cons the field only when it is not connection-specific.
%% Mirrors h1's fused `encode_headers_loop/2`.
-spec strip_connection_specific_fields_safe(headers(), binary:cp()) -> headers().
strip_connection_specific_fields_safe([], _UnsafeCp) ->
    [];
strip_connection_specific_fields_safe([{Name, Value} = Field | Rest], UnsafeCp) ->
    ok = check_header_safe(Name, name, UnsafeCp),
    ok = check_header_safe(Value, value, UnsafeCp),
    case connection_specific_field(Name) of
        true -> strip_connection_specific_fields_safe(Rest, UnsafeCp);
        false -> [Field | strip_connection_specific_fields_safe(Rest, UnsafeCp)]
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

%% `-on_load` callback. Stashes the compiled unsafe-bytes pattern in
%% `persistent_term` so `check_header_safe/3` reads a constant on the
%% response hot path. Returns `ok` so module load succeeds; if the
%% compile fails (it shouldn't, the pattern is a literal), the module
%% won't load and we'll see it loudly.
-spec init_patterns() -> ok.
init_patterns() ->
    persistent_term:put(
        ?UNSAFE_BYTES_KEY,
        binary:compile_pattern([~"\r", ~"\n", ~"\0"])
    ),
    ok.
