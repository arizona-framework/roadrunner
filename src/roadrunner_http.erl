-module(roadrunner_http).
-moduledoc """
Protocol-version-agnostic HTTP semantics shared by HTTP/1.1
(`roadrunner_http1`) and any future HTTP/2 (`roadrunner_http2_*`)
modules.

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

`roadrunner_http1` re-exports these as type aliases so existing
callers using `roadrunner_http1:request()` / `:headers()` etc.
keep compiling unchanged.
""".

-export([http_date_now/0, format_http_date/1]).

-export_type([headers/0, status/0, redirect_status/0, version/0]).

-type headers() :: [{Name :: binary(), Value :: binary()}].
-type status() :: 100..599.
-type redirect_status() :: 300..399.
-type version() :: {1, 0} | {1, 1} | {2, 0}.

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
runs once per response on the hot path — a 250 k req/s listener
calls it 250 k times per second. Skipping the formatter's
state-machine walk and iolist tree saves real cycles on every
request.
""".
-spec http_date_now() -> binary().
http_date_now() ->
    format_http_date(erlang:system_time(second)).

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
