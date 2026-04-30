-module(cactus_resp).
-moduledoc """
Convenience builders for the `{Status, Headers, Body}` triple cactus
handlers return.

Each helper sets `Content-Type` and `Content-Length` so handlers don't
repeat the boilerplate. Body framing (`Connection: close`,
`Transfer-Encoding`, etc.) is still the connection layer's job — these
helpers only fill in what the handler can know.
""".

-export([text/2, html/2, json/2, redirect/2]).

-doc "Plain-text response with `text/plain; charset=utf-8`.".
-spec text(StatusCode :: 100..599, Body :: iodata()) ->
    {100..599, cactus_http1:headers(), iodata()}.
text(Status, Body) ->
    with_length(Status, ~"text/plain; charset=utf-8", Body).

-doc "HTML response with `text/html; charset=utf-8`.".
-spec html(StatusCode :: 100..599, Body :: iodata()) ->
    {100..599, cactus_http1:headers(), iodata()}.
html(Status, Body) ->
    with_length(Status, ~"text/html; charset=utf-8", Body).

-doc """
JSON response — the term is encoded via the stdlib `json` module
(OTP 27+) and `Content-Type` is set to `application/json`.
""".
-spec json(StatusCode :: 100..599, Term :: term()) ->
    {100..599, cactus_http1:headers(), iodata()}.
json(Status, Term) ->
    Body = json:encode(Term),
    with_length(Status, ~"application/json", Body).

-doc """
Redirect response — sets the `Location` header and an empty body.
Use a 3xx status (typically 301, 302, 303, 307, or 308).
""".
-spec redirect(StatusCode :: 300..399, Location :: binary()) ->
    {300..399, cactus_http1:headers(), iodata()}.
redirect(Status, Location) when is_binary(Location) ->
    {Status,
        [
            {~"location", Location},
            {~"content-length", ~"0"}
        ],
        ~""}.

-spec with_length(100..599, binary(), iodata()) ->
    {100..599, cactus_http1:headers(), iodata()}.
with_length(Status, ContentType, Body) ->
    {Status,
        [
            {~"content-type", ContentType},
            {~"content-length", integer_to_binary(iolist_size(Body))}
        ],
        Body}.
