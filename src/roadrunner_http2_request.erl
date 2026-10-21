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
%% - `:path` is an origin-form (`/`, then US-ASCII without CTL, SP or
%%   DEL), or `*` for OPTIONS; a well-formed CONNECT is a 501.
%% - Field names are visible US-ASCII without uppercase or `:`, and values
%%   hold no NUL, CR or LF and no leading or trailing SP or HTAB (RFC 9113
%%   §8.2.1): enforced by `roadrunner_http2_hpack:decode/2` as it decodes
%%   each literal field.
%% - `Connection`-specific headers MUST NOT appear (RFC 9113
%%   §8.2.2). Rejected.
%% - `:authority` or `Host` MUST be present, neither empty, each a
%%   `uri-host [":" port]` with no userinfo, and both naming the same
%%   entity when both appear, compared after case and default-port
%%   normalization (RFC 9113 §8.3.1).

-export([from_headers/3]).

-export_type([build_error/0, request_context/0]).

-type build_error() ::
    missing_pseudo_header
    | duplicate_pseudo_header
    | unknown_pseudo_header
    | pseudo_after_regular
    | empty_path
    | bad_path
    | bad_connect
    | not_implemented
    | connection_specific_header
    | duplicate_content_type
    | unsupported_expectation
    | missing_authority
    | duplicate_host
    | empty_authority
    | bad_authority
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
from_headers(Headers, Body, #{scheme := Scheme} = RequestContext) ->
    maybe
        %% The `:scheme` pseudo-header must be present, but its value is
        %% deliberately discarded — the authoritative scheme comes from the conn
        %% (`RequestContext.scheme`) since clients can lie about the
        %% pseudo-header value.
        {ok, Method, Path, Authority, Regular} ?= roadrunner_http:request_pseudo_headers(Headers),
        ok ?= check_banned(Regular),
        ok ?= roadrunner_http:check_request_authority(Authority, Regular, Scheme),
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
    ok | {error, connection_specific_header | duplicate_content_type | unsupported_expectation}.
check_banned([]) ->
    ok;
check_banned([{~"connection", _} | _]) ->
    {error, connection_specific_header};
check_banned([{~"keep-alive", _} | _]) ->
    {error, connection_specific_header};
check_banned([{~"proxy-connection", _} | _]) ->
    {error, connection_specific_header};
check_banned([{~"transfer-encoding", _} | _]) ->
    {error, connection_specific_header};
check_banned([{~"upgrade", _} | _]) ->
    {error, connection_specific_header};
check_banned([{~"te", ~"trailers"} | Rest]) ->
    check_banned(Rest);
check_banned([{~"te", _} | _]) ->
    {error, connection_specific_header};
check_banned([{~"content-type", _} | Rest]) ->
    %% Content-Type is a singleton field (RFC 9110 §5.3, §8.3): a second
    %% one leaves the body's media type ambiguous.
    case lists:keymember(~"content-type", 1, Rest) of
        true -> {error, duplicate_content_type};
        false -> check_banned(Rest)
    end;
check_banned([{~"expect", Expect} | Rest]) ->
    %% An expectation other than `100-continue` is a 417 (RFC 9110 §10.1.1).
    case roadrunner_http:expectation(Expect) of
        unsupported -> {error, unsupported_expectation};
        _ -> check_banned(Rest)
    end;
check_banned([_ | Rest]) ->
    check_banned(Rest).
