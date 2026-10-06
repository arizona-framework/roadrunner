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
%% - `:path` MUST NOT be empty.
%% - Regular field names MUST be lowercase; an uppercase character makes the
%%   request malformed (RFC 9114 §4.2).
%% - Connection-specific headers MUST NOT appear (RFC 9114 §4.2).
%% - The request MUST carry an `:authority` pseudo-header or a `host` header
%%   (https has a mandatory authority component); if present neither is empty,
%%   and if both appear they MUST name the same entity, compared after
%%   case and default-port normalization (RFC 9114 §4.3.1).
%% - A `content-length` header MUST equal the received body length and MUST NOT
%%   be repeated (RFC 9114 §4.1.2, RFC 9110 §8.6).

-export([from_headers/3]).

-export_type([build_error/0, request_context/0]).

-type build_error() ::
    missing_pseudo_header
    | duplicate_pseudo_header
    | unknown_pseudo_header
    | pseudo_after_regular
    | empty_path
    | connection_specific_header
    | uppercase_field_name
    | content_length_mismatch
    | missing_authority
    | duplicate_host
    | empty_authority
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
from_headers(Headers, Body, #{scheme := Scheme} = RequestContext) ->
    maybe
        %% The parsed `:scheme` value is validated but deliberately
        %% discarded — the authoritative scheme comes from the conn
        %% (`RequestContext.scheme`, always `https` over QUIC) since
        %% clients can lie about the pseudo-header value.
        {ok, Method, Path, Authority, Regular} ?= roadrunner_http:request_pseudo_headers(Headers),
        ok ?= check_banned(Regular),
        ok ?= check_content_length(Regular, Body),
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
    ok | {error, connection_specific_header | uppercase_field_name}.
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
check_banned([{Name, _} | Rest]) ->
    %% Any other name is not connection-specific, but RFC 9114 §4.2 makes a
    %% request with an uppercase field name malformed; the banned literals
    %% above are already lowercase, so only these unrecognised names need the
    %% scan. Folding it here keeps one pass over the regular headers.
    case lower_name(Name) of
        ok -> check_banned(Rest);
        {error, _} = Error -> Error
    end.

%% Reject any uppercase ASCII letter in a regular field name (RFC 9114 §4.2:
%% uppercase field names MUST be treated as malformed). Mirrors
%% roadrunner_http2_hpack:validate_lower/1.
-spec lower_name(binary()) -> ok | {error, uppercase_field_name}.
lower_name(<<>>) -> ok;
lower_name(<<C, _/binary>>) when C >= $A, C =< $Z -> {error, uppercase_field_name};
lower_name(<<_, Rest/binary>>) -> lower_name(Rest).

%% RFC 9114 §4.1.2 / RFC 9110 §8.6: a `content-length` header whose value does
%% not equal the bytes received in DATA frames (or a multi-valued or
%% non-integer value) makes the request malformed; an absent header is always
%% acceptable. The body size is taken only when a value is actually present.
-spec check_content_length(roadrunner_http:headers(), iodata()) ->
    ok | {error, content_length_mismatch}.
check_content_length(Headers, Body) ->
    case roadrunner_http:request_content_length(Headers) of
        none ->
            ok;
        {ok, Length} ->
            case iolist_size(Body) of
                Length -> ok;
                _ -> {error, content_length_mismatch}
            end;
        error ->
            {error, content_length_mismatch}
    end.
