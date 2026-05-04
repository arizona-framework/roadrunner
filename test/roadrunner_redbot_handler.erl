-module(roadrunner_redbot_handler).
-moduledoc """
Test fixture driven by `scripts/redbot.escript` against
[REDbot](https://redbot.org) — Mark Nottingham's HTTP/1.1
response-conformance checker (caching, content-encoding, ETag,
Vary, etc.). Each path exposes a different response shape so a
single redbot run probes a representative slice of the
RFC 9110 / RFC 9111 surface roadrunner emits.

Routes:

- `/` — bare text response, no cache directives.
- `/json` — `application/json` body with explicit `Cache-Control: no-cache`.
- `/cached` — public response with `Cache-Control: max-age=300, public`.
- `/etag` — response carrying a strong ETag.
- `/last-modified` — response carrying `Last-Modified`.
- `/conditional` — handler responds 304 to a matching `If-None-Match`.
- `/large` — payload above the gzip threshold (~1 KiB) so the
  compress middleware engages.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(#{target := ~"/"} = Req) ->
    plain(Req, ~"hello\n", []);
handle(#{target := ~"/json"} = Req) ->
    respond(
        Req,
        200,
        [
            {~"content-type", ~"application/json"},
            {~"cache-control", ~"no-cache"}
        ],
        ~"{\"ok\":true}"
    );
handle(#{target := ~"/cached"} = Req) ->
    plain(Req, ~"public asset", [{~"cache-control", ~"max-age=300, public"}]);
handle(#{target := ~"/etag"} = Req) ->
    ETag = ~"\"v1-deadbeef\"",
    plain(
        Req,
        ~"etagged body",
        [{~"etag", ETag}, {~"cache-control", ~"max-age=60"}]
    );
handle(#{target := ~"/last-modified"} = Req) ->
    %% A fixed past timestamp (IMF-fixdate) so redbot treats the
    %% response as well-validatable.
    plain(
        Req,
        ~"timestamped body",
        [
            {~"last-modified", ~"Sun, 06 Nov 1994 08:49:37 GMT"},
            {~"cache-control", ~"max-age=60"}
        ]
    );
handle(#{target := ~"/conditional"} = Req) ->
    ETag = ~"\"v1-cafebabe\"",
    %% Honor `If-None-Match` with a 304 when the etag matches.
    case roadrunner_req:header(~"if-none-match", Req) of
        ETag ->
            respond(Req, 304, [{~"etag", ETag}, {~"content-length", ~"0"}], ~"");
        _ ->
            plain(Req, ~"conditional body", [{~"etag", ETag}])
    end;
handle(#{target := ~"/large"} = Req) ->
    %% Above the 860-byte gzip threshold — the compress middleware
    %% will engage when the listener has it stacked.
    plain(Req, binary:copy(~"hello world! ", 200), []);
handle(Req) ->
    respond(Req, 404, [{~"content-length", ~"0"}], ~"").

%% Convenience wrapper for `text/plain` 200 responses with auto-injected
%% `Content-Length`. RFC 9112 §6.3 — without CL or TE, clients have to
%% read-until-close to find the body end; we emit CL on every response.
plain(Req, Body, Extra) ->
    respond(
        Req,
        200,
        [{~"content-type", ~"text/plain; charset=utf-8"} | Extra],
        Body
    ).

respond(Req, Status, Headers, Body) ->
    Len = integer_to_binary(iolist_size(Body)),
    %% Only inject CL if the handler didn't already set it (e.g. 304).
    Final =
        case lists:keymember(~"content-length", 1, Headers) of
            true -> Headers;
            false -> [{~"content-length", Len} | Headers]
        end,
    {{Status, Final, Body}, Req}.
