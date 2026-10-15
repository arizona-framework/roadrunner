-module(roadrunner_http3_request).
-moduledoc false.

%% Build a roadrunner request map from an HTTP/3 HEADERS field section
%% (QPACK-decoded header list) per RFC 9114 §4.

%% The request shape is the same `roadrunner_req:request()` map that
%% HTTP/1.1 and HTTP/2 produce — pseudo-headers (`:method`, `:scheme`,
%% `:authority`, `:path`) get normalized into the existing `method` /
%% `scheme` / `target` / regular-header fields so handler code (and
%% `roadrunner_req` accessors) doesn't care which protocol served the
%% request. Mirrors `roadrunner_http2_request` (the rules are the same
%% bar the protocol version stamped on the map).
%%
%% ## Validation (RFC 9114 §4.3)
%%
%% - Exactly one each of `:method`, `:scheme`, `:path` is required
%%   (the simple "GET-style" request shape; CONNECT / Extended CONNECT
%%   arrive with WebTransport later).
%% - Pseudo-headers MUST appear before regular headers; mixing is a
%%   malformed request.
%% - Pseudo-headers other than the four defined are rejected.
%% - `:path` is an origin-form (`/`, then US-ASCII without CTL, SP or DEL),
%%   or `*` for OPTIONS; a well-formed CONNECT is a 501.
%% - Field names are visible US-ASCII without uppercase or `:`, and values
%%   hold no NUL, CR or LF and no leading or trailing SP or HTAB (RFC 9114
%%   §4.2, `roadrunner_http:check_fields/1`).
%% - Connection-specific headers MUST NOT appear (RFC 9114 §4.2).
%% - The request MUST carry an `:authority` pseudo-header or a `host` header
%%   (https has a mandatory authority component); if present neither is empty,
%%   each is a `uri-host [":" port]` with no userinfo, and if both appear
%%   they MUST name the same entity, compared after case and default-port
%%   normalization (RFC 9114 §4.3.1).
%% - A `content-length` header MUST equal the received body length and MUST NOT
%%   be repeated (RFC 9114 §4.1.2, RFC 9110 §8.6).

-export([from_headers/3, from_headers_reading/2]).

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
    | bad_field_name
    | bad_field_value
    | duplicate_content_type
    | content_length_mismatch
    | missing_authority
    | duplicate_host
    | empty_authority
    | bad_authority
    | authority_mismatch.

-type request_context() :: roadrunner_http:request_context().

-doc """
Build a request map from a QPACK-decoded header list. `RequestContext`
carries the per-connection bits the conn loop already has — peer,
scheme (always `https` over QUIC), listener_name, request_id.

The returned map is `roadrunner_req:request()` shape with `version =>
{3, 0}`, `target` set to the `:path` pseudo-header value, and `method`
set to `:method`. The `:authority` pseudo-header is forwarded as a
`host` header so handlers that read it via `roadrunner_req:header/2`
still work.

`Body` is the iolist of accumulated DATA-frame payloads (or `<<>>` for
header-only requests). Stored on the request map as `iodata()`;
handlers needing a flat binary call `iolist_to_binary/1`.
""".
-spec from_headers(roadrunner_http:headers(), iodata(), request_context()) ->
    {ok, roadrunner_req:request()} | {error, build_error()}.
from_headers(Headers, Body, RequestContext) ->
    build(Headers, Body, RequestContext, true).

-doc """
`from_headers/3` for a manual-mode request whose body is still to come: its
declared `content-length` is checked against the DATA as it arrives, not
here, and the request map carries an empty `body` for the conn to swap for
a body reader.
""".
-spec from_headers_reading(roadrunner_http:headers(), request_context()) ->
    {ok, roadrunner_req:request()} | {error, build_error()}.
from_headers_reading(Headers, RequestContext) ->
    build(Headers, <<>>, RequestContext, false).

-spec build(roadrunner_http:headers(), iodata(), request_context(), boolean()) ->
    {ok, roadrunner_req:request()} | {error, build_error()}.
build(Headers, Body, #{scheme := Scheme} = RequestContext, CheckLength) ->
    maybe
        %% The parsed `:scheme` value is validated but deliberately
        %% discarded — the authoritative scheme comes from the conn
        %% (`RequestContext.scheme`, always `https` over QUIC) since
        %% clients can lie about the pseudo-header value.
        ok ?= roadrunner_http:check_fields(Headers),
        {ok, Method, Path, Authority, Regular} ?= roadrunner_http:request_pseudo_headers(Headers),
        ok ?= check_banned(Regular),
        ok ?= check_content_length(Regular, Body, CheckLength),
        ok ?= roadrunner_http:check_request_authority(Authority, Regular, Scheme),
        {ok,
            roadrunner_http:build_request(
                {3, 0}, Method, Path, Authority, Regular, Body, RequestContext
            )}
    end.

%% Function-clause dispatch over the banned set (RFC 9114 §4.2) keeps
%% the hot path branch-friendly: the BEAM compiles the literal-binary
%% clauses to a hash/select, no `lists:member` call per header.
-spec check_banned(roadrunner_http:headers()) ->
    ok | {error, connection_specific_header | duplicate_content_type}.
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
check_banned([_ | Rest]) ->
    check_banned(Rest).

%% RFC 9114 §4.1.2 / RFC 9110 §8.6: a `content-length` header whose value does
%% not equal the bytes received in DATA frames (or a multi-valued or
%% non-integer value) makes the request malformed; an absent header is always
%% acceptable. The body size is taken only when a value is actually present.
%% A body still to come is not checked here (`from_headers_reading/2`).
-spec check_content_length(roadrunner_http:headers(), iodata(), boolean()) ->
    ok | {error, content_length_mismatch}.
check_content_length(_Headers, _Body, false) ->
    ok;
check_content_length(Headers, Body, true) ->
    case roadrunner_http:request_content_length(Headers) of
        none ->
            ok;
        Declared ->
            case roadrunner_http:body_length_fits(Declared, iolist_size(Body), true) of
                true -> ok;
                false -> {error, content_length_mismatch}
            end
    end.
