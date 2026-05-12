-module(roadrunner_http2_request).
-moduledoc """
Build a roadrunner request map from an HTTP/2 HEADERS block
(decoded HPACK header list) per RFC 9113 §8.3.

The request shape is the same `roadrunner_http1:request()` map
that HTTP/1.1 produces — pseudo-headers (`:method`, `:scheme`,
`:authority`, `:path`) get normalized into the existing `method`
/ `scheme` / `target` / regular-header fields so handler code
(and `roadrunner_req` accessors) doesn't care which protocol
served the request.

## Validation (RFC 9113 §8.1.2)

- Exactly one each of `:method`, `:scheme`, `:path` is required;
  CONNECT requests omit `:scheme`/`:path` and require
  `:authority` (we accept the simpler "GET-style" request shape
  here; CONNECT and Extended CONNECT for WebSocket-over-h2
  support arrive later).
- Pseudo-headers MUST appear before regular headers; mixing is
  a `protocol_error`.
- Pseudo-headers other than the four defined are rejected.
- `:path` MUST NOT be empty (an h2 client should send `/` for
  the origin form).
- Header field names MUST be lowercase — already enforced by
  `roadrunner_http2_hpack:decode/2`.
- `Connection`-specific headers MUST NOT appear (RFC 9113
  §8.2.2). Rejected.
""".

-export([from_headers/3]).

-export_type([build_error/0, conn_info/0]).

-type build_error() ::
    missing_pseudo_header
    | duplicate_pseudo_header
    | unknown_pseudo_header
    | pseudo_after_regular
    | empty_path
    | connection_specific_header.

-type conn_info() :: #{
    peer := {inet:ip_address(), inet:port_number()} | undefined,
    scheme := http | https,
    request_id := binary(),
    listener_name := atom()
}.

-doc """
Build a request map from a decoded HPACK header list. `ConnInfo`
carries the per-connection bits the HTTP/1 conn already has —
peer, scheme (from the TLS tag), listener_name, request_id.

The returned map is `roadrunner_http1:request()` shape with
`version => {2, 0}`, `target` set to the `:path` pseudo-header
value, and `method` set to `:method`. The `:authority`
pseudo-header is forwarded as a `host` header so handlers that
read it via `roadrunner_req:header/2` still work.

`Body` is the iolist of accumulated DATA-frame payload chunks (or `<<>>`
for header-only requests). Stored on the request map as `iodata()`;
handlers requiring a flat binary call `iolist_to_binary/1` themselves.
""".
-spec from_headers([roadrunner_http2_hpack:header()], iodata(), conn_info()) ->
    {ok, roadrunner_http1:request()} | {error, build_error()}.
from_headers(Headers, Body, ConnInfo) ->
    maybe
        {ok, Pseudo, Regular} ?= partition(Headers),
        %% `validate_pseudo` returns the parsed `:scheme` value but we
        %% deliberately discard it — the authoritative scheme comes
        %% from the conn (`ConnInfo.scheme`) since clients can lie
        %% about the pseudo-header value.
        {ok, Method, _Scheme, Path, Authority} ?= validate_pseudo(Pseudo),
        ok ?= check_banned(Regular),
        {ok, build(Method, Path, Authority, Regular, Body, ConnInfo)}
    end.

%% Walk the decoded header list, collecting pseudo-headers (names
%% starting with `:`) into a map keyed by name and regular headers
%% into a list. Body recursion — regular headers cons in front on
%% the way back out so the order matches the wire order.
%% Walk pseudo-headers (names starting with `:`) into a map until
%% the first regular header, then hand off to `partition_regular/1`
%% which body-recurses the rest. Splitting the two phases avoids
%% the prior shape's double recursion (cons-forward AND cons-back
%% on every regular header).
-spec partition([roadrunner_http2_hpack:header()]) ->
    {ok, map(), [roadrunner_http2_hpack:header()]} | {error, build_error()}.
partition(Headers) ->
    partition(Headers, #{}).

-spec partition([roadrunner_http2_hpack:header()], map()) ->
    {ok, map(), [roadrunner_http2_hpack:header()]} | {error, build_error()}.
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

%% Body-recurse the regular-header tail. A pseudo-header arriving
%% here is RFC 9113 §8.1.2.1 PROTOCOL_ERROR.
-spec partition_regular([roadrunner_http2_hpack:header()]) ->
    {ok, [roadrunner_http2_hpack:header()]} | {error, build_error()}.
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

%% Function-clause dispatch over the banned set (RFC 9113 §8.2.2)
%% keeps the hot path branch-friendly: the BEAM compiles the
%% literal-binary clauses to a hash/select, no `lists:member`
%% function call per header.
-spec check_banned([roadrunner_http2_hpack:header()]) ->
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
    [roadrunner_http2_hpack:header()],
    binary(),
    map()
) -> roadrunner_http1:request().
build(Method, Path, Authority, Regular, Body, ConnInfo) ->
    %% Forward `:authority` as a `host` header so existing h1
    %% handler code that reads `Host` still works. (RFC 9113
    %% §8.3.1 says an h2 server MUST treat `:authority` like
    %% `Host`.)
    HeadersWithHost =
        case Authority of
            undefined -> Regular;
            _ -> [{~"host", Authority} | Regular]
        end,
    %% Caller (`roadrunner_conn_loop_http2:dispatch_stream`)
    %% always builds `ConnInfo` with all four fields populated, so
    %% pattern-matching wins vs. four `maps:get/3` calls.
    #{
        peer := Peer,
        scheme := Scheme,
        request_id := RequestId,
        listener_name := ListenerName
    } = ConnInfo,
    #{
        method => Method,
        target => Path,
        version => {2, 0},
        headers => HeadersWithHost,
        body => Body,
        bindings => #{},
        peer => Peer,
        scheme => Scheme,
        request_id => RequestId,
        listener_name => ListenerName
    }.
