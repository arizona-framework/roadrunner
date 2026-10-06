-module(roadrunner_http2_request).
-moduledoc false.

%% Build a roadrunner request map from an HTTP/2 HEADERS block
%% (decoded HPACK header list) per RFC 9113 §8.3.
%%
%% The request shape is the same `roadrunner_req:request()` map
%% that HTTP/1.1 produces — pseudo-headers (`:method`, `:scheme`,
%% `:authority`, `:path`) get normalized into the existing `method`
%% / `scheme` / `target` / regular-header fields so handler code
%% (and `roadrunner_req` accessors) doesn't care which protocol
%% served the request.
%%
%% ## Validation (RFC 9113 §8.1.2)
%%
%% - Exactly one each of `:method`, `:scheme`, `:path` is required;
%%   CONNECT requests omit `:scheme`/`:path` and require
%%   `:authority` (we accept the simpler "GET-style" request shape
%%   here; CONNECT and Extended CONNECT for WebSocket-over-h2
%%   support arrive later).
%% - Pseudo-headers MUST appear before regular headers; mixing is
%%   a `protocol_error`.
%% - Pseudo-headers other than the four defined are rejected.
%% - `:path` MUST NOT be empty (an h2 client should send `/` for
%%   the origin form).
%% - Header field names MUST be lowercase — already enforced by
%%   `roadrunner_http2_hpack:decode/2`.
%% - `Connection`-specific headers MUST NOT appear (RFC 9113
%%   §8.2.2). Rejected.

-export([from_headers/3]).

-export_type([build_error/0, request_context/0]).

-type build_error() ::
    missing_pseudo_header
    | duplicate_pseudo_header
    | unknown_pseudo_header
    | pseudo_after_regular
    | empty_path
    | connection_specific_header
    | missing_authority
    | duplicate_host
    | empty_authority
    | authority_mismatch.

-type request_context() :: roadrunner_http:request_context().

-doc """
Build a request map from a decoded HPACK header list. `RequestContext`
carries the per-connection bits the HTTP/1 conn already has —
peer, scheme (from the TLS tag), listener_name, request_id.

The returned map is `roadrunner_req:request()` shape with
`version => {2, 0}`, `target` set to the `:path` pseudo-header
value, and `method` set to `:method`. The `:authority`
pseudo-header is forwarded as a `host` header so handlers that
read it via `roadrunner_req:header/2` still work.

`Body` is the iolist of accumulated DATA-frame payload chunks (or `<<>>`
for header-only requests). Stored on the request map as `iodata()`;
handlers requiring a flat binary call `iolist_to_binary/1` themselves.
""".
-spec from_headers(roadrunner_http:headers(), iodata(), request_context()) ->
    {ok, roadrunner_req:request()} | {error, build_error()}.
from_headers(Headers, Body, RequestContext) ->
    maybe
        %% The parsed `:scheme` value is validated but deliberately
        %% discarded — the authoritative scheme comes from the conn
        %% (`RequestContext.scheme`) since clients can lie about the
        %% pseudo-header value.
        {ok, Method, Path, Authority, Regular} ?= roadrunner_http:request_pseudo_headers(Headers),
        ok ?= check_banned(Regular),
        ok ?= roadrunner_http:check_request_authority(Authority, Regular),
        {ok,
            roadrunner_http:build_request(
                {2, 0}, Method, Path, Authority, Regular, Body, RequestContext
            )}
    end.

%% Function-clause dispatch over the banned set (RFC 9113 §8.2.2)
%% keeps the hot path branch-friendly: the BEAM compiles the
%% literal-binary clauses to a hash/select, no `lists:member`
%% function call per header.
-spec check_banned(roadrunner_http:headers()) ->
    ok | {error, connection_specific_header}.
check_banned([]) -> ok;
check_banned([{~"connection", _} | _]) -> {error, connection_specific_header};
check_banned([{~"keep-alive", _} | _]) -> {error, connection_specific_header};
check_banned([{~"proxy-connection", _} | _]) -> {error, connection_specific_header};
check_banned([{~"transfer-encoding", _} | _]) -> {error, connection_specific_header};
check_banned([{~"upgrade", _} | _]) -> {error, connection_specific_header};
check_banned([{~"te", ~"trailers"} | Rest]) -> check_banned(Rest);
check_banned([{~"te", _} | _]) -> {error, connection_specific_header};
check_banned([_ | Rest]) -> check_banned(Rest).
