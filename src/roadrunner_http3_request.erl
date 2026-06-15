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
%%   and if both appear they MUST match (RFC 9114 §4.3.1).
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
    | empty_authority
    | authority_mismatch.

-type request_context() :: #{
    peer := {inet:ip_address(), inet:port_number()} | undefined,
    scheme := http | https,
    request_id := binary(),
    listener_name := atom()
}.

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
    maybe
        {ok, Pseudo, Regular} ?= partition(Headers),
        %% `validate_pseudo` returns the parsed `:scheme` value but we
        %% deliberately discard it — the authoritative scheme comes
        %% from the conn (`RequestContext.scheme`, always `https` over
        %% QUIC) since clients can lie about the pseudo-header value.
        {ok, Method, _Scheme, Path, Authority} ?= validate_pseudo(Pseudo),
        ok ?= check_banned(Regular),
        ok ?= check_content_length(Regular, Body),
        ok ?= check_authority(Authority, Regular),
        {ok, build(Method, Path, Authority, Regular, Body, RequestContext)}
    end.

%% Walk pseudo-headers (names starting with `:`) into a map until the
%% first regular header, then hand off to `partition_regular/1` which
%% body-recurses the rest. Splitting the two phases avoids the prior
%% shape's double recursion (cons-forward AND cons-back on every
%% regular header).
-spec partition(roadrunner_http:headers()) ->
    {ok, map(), roadrunner_http:headers()} | {error, build_error()}.
partition(Headers) ->
    partition(Headers, #{}).

-spec partition(roadrunner_http:headers(), map()) ->
    {ok, map(), roadrunner_http:headers()} | {error, build_error()}.
partition([], Pseudo) ->
    {ok, Pseudo, []};
partition([{<<":", _/binary>> = Name, Value} | Rest], Pseudo) ->
    case Pseudo of
        #{Name := _} ->
            {error, duplicate_pseudo_header};
        _ when
            Name =:= ~":method";
            Name =:= ~":scheme";
            Name =:= ~":authority";
            Name =:= ~":path"
        ->
            partition(Rest, Pseudo#{Name => Value});
        _ ->
            {error, unknown_pseudo_header}
    end;
partition([H | Rest], Pseudo) ->
    case partition_regular(Rest) of
        {ok, Tail} -> {ok, Pseudo, [H | Tail]};
        {error, _} = E -> E
    end.

%% A pseudo-header arriving in the regular-header tail is
%% RFC 9114 §4.3.1 malformed (pseudo after regular). Tail-recursive: the
%% validated headers cons into an accumulator (flipped once at the end)
%% rather than rebuilding the `{ok, _}` result tuple on every frame.
-spec partition_regular(roadrunner_http:headers()) ->
    {ok, roadrunner_http:headers()} | {error, build_error()}.
partition_regular(Headers) ->
    partition_regular(Headers, []).

-spec partition_regular(roadrunner_http:headers(), roadrunner_http:headers()) ->
    {ok, roadrunner_http:headers()} | {error, build_error()}.
partition_regular([], Acc) ->
    {ok, lists:reverse(Acc)};
partition_regular([{<<":", _/binary>>, _} | _], _Acc) ->
    {error, pseudo_after_regular};
partition_regular([H | Rest], Acc) ->
    partition_regular(Rest, [H | Acc]).

-spec validate_pseudo(map()) ->
    {ok, binary(), binary(), binary(), binary() | undefined}
    | {error, build_error()}.
validate_pseudo(Pseudo) ->
    case Pseudo of
        #{
            ~":method" := Method,
            ~":scheme" := Scheme,
            ~":path" := Path
        } when Path =/= ~"" ->
            Authority = maps:get(~":authority", Pseudo, undefined),
            {ok, Method, Scheme, Path, Authority};
        #{~":path" := ~""} ->
            {error, empty_path};
        _ ->
            {error, missing_pseudo_header}
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
%% acceptable. Single-pass walk; the body size is taken only when a value is
%% actually present. Mirrors roadrunner_conn_loop_http2:content_length_matches/2.
-spec check_content_length(roadrunner_http:headers(), iodata()) ->
    ok | {error, content_length_mismatch}.
check_content_length(Headers, Body) ->
    case find_content_length(Headers, undefined) of
        none ->
            ok;
        multiple ->
            {error, content_length_mismatch};
        Value ->
            BodyLen = iolist_size(Body),
            try binary_to_integer(Value) of
                BodyLen -> ok;
                _ -> {error, content_length_mismatch}
            catch
                error:badarg -> {error, content_length_mismatch}
            end
    end.

-spec find_content_length(roadrunner_http:headers(), binary() | undefined) ->
    binary() | none | multiple.
find_content_length([], undefined) ->
    none;
find_content_length([], Value) ->
    Value;
find_content_length([{~"content-length", _} | _], Value) when Value =/= undefined -> multiple;
find_content_length([{~"content-length", Value} | Rest], undefined) ->
    find_content_length(Rest, Value);
find_content_length([_ | Rest], Value) ->
    find_content_length(Rest, Value).

%% RFC 9114 §4.3.1: over QUIC the scheme is always https (a mandatory authority
%% component), so the request MUST carry an `:authority` pseudo-header or a
%% `host` header; if present neither is empty, and if both appear they MUST
%% match. The empty-value clauses precede the equality clause so an empty value
%% loses even when both sides are equally empty.
-spec check_authority(binary() | undefined, roadrunner_http:headers()) ->
    ok | {error, missing_authority | empty_authority | authority_mismatch}.
check_authority(Authority, Regular) ->
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
-spec find_host(roadrunner_http:headers()) -> binary() | undefined.
find_host([]) -> undefined;
find_host([{~"host", Value} | _]) -> Value;
find_host([_ | Rest]) -> find_host(Rest).

-spec build(
    binary(),
    binary(),
    binary() | undefined,
    roadrunner_http:headers(),
    iodata(),
    request_context()
) -> roadrunner_req:request().
build(Method, Path, Authority, Regular, Body, RequestContext) ->
    %% Forward `:authority` as a `host` header so existing handler code
    %% that reads `Host` still works (RFC 9114 §4.3.1 treats `:authority`
    %% like `Host`). When the client also sent a (validated equal) `host`
    %% header, drop it first so a single canonical entry survives instead
    %% of a duplicate.
    HeadersWithHost =
        case Authority of
            undefined -> Regular;
            _ -> [{~"host", Authority} | lists:keydelete(~"host", 1, Regular)]
        end,
    %% The conn loop always builds `RequestContext` with all four
    %% fields populated, so pattern-matching wins vs. four `maps:get/3`.
    #{
        peer := Peer,
        scheme := Scheme,
        request_id := RequestId,
        listener_name := ListenerName
    } = RequestContext,
    #{
        method => Method,
        target => Path,
        version => {3, 0},
        headers => HeadersWithHost,
        body => Body,
        bindings => #{},
        peer => Peer,
        scheme => Scheme,
        request_id => RequestId,
        listener_name => ListenerName
    }.
