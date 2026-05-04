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
- IMF-fixdate formatter (`http_date_now/0`) for the `Date`
  response header per RFC 9110 §5.6.7.

`roadrunner_http1` re-exports these as type aliases so existing
callers using `roadrunner_http1:request()` / `:headers()` etc.
keep compiling unchanged.
""".

-export([http_date_now/0]).

-export_type([headers/0, status/0, redirect_status/0, version/0]).

-type headers() :: [{Name :: binary(), Value :: binary()}].
-type status() :: 100..599.
-type redirect_status() :: 300..399.
-type version() :: {1, 0} | {1, 1}.

-define(DAY_NAMES, {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}).
-define(MONTH_NAMES,
    {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
).

-doc """
Format the current UTC time as an IMF-fixdate per RFC 9110 §5.6.7
— the canonical HTTP `Date` header format, e.g.
`Sun, 06 Nov 1994 08:49:37 GMT`. Used by the dispatch layer to
auto-inject the `Date` response header per RFC 9110 §6.6.1.
""".
-spec http_date_now() -> binary().
http_date_now() ->
    {{Y, M, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(
        erlang:system_time(second), second
    ),
    DayName = element(calendar:day_of_the_week(Y, M, D), ?DAY_NAMES),
    MonthName = element(M, ?MONTH_NAMES),
    iolist_to_binary(
        io_lib:format(
            "~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B GMT",
            [DayName, D, MonthName, Y, H, Mi, S]
        )
    ).
