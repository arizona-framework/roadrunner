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
%% - Header field names are lowercase — `quic_qpack:decode/1` returns
%%   them as received, and an h3 client MUST send them lowercase.
%% - Connection-specific headers MUST NOT appear (RFC 9114 §4.2).

-export([from_headers/3]).

-export_type([build_error/0, request_context/0]).

-type build_error() ::
    missing_pseudo_header
    | duplicate_pseudo_header
    | unknown_pseudo_header
    | pseudo_after_regular
    | empty_path
    | connection_specific_header.

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

%% Body-recurse the regular-header tail. A pseudo-header arriving here
%% is RFC 9114 §4.3.1 malformed (pseudo after regular).
-spec partition_regular(roadrunner_http:headers()) ->
    {ok, roadrunner_http:headers()} | {error, build_error()}.
partition_regular([]) ->
    {ok, []};
partition_regular([{<<":", _/binary>>, _} | _]) ->
    {error, pseudo_after_regular};
partition_regular([H | Rest]) ->
    case partition_regular(Rest) of
        {ok, Tail} -> {ok, [H | Tail]};
        {error, _} = E -> E
    end.

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
    %% that reads `Host` still works (RFC 9114 §4.3.1 treats
    %% `:authority` like `Host`).
    HeadersWithHost =
        case Authority of
            undefined -> Regular;
            _ -> [{~"host", Authority} | Regular]
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
