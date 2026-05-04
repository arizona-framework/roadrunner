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

-export_type([build_error/0]).

-type build_error() ::
    missing_pseudo_header
    | duplicate_pseudo_header
    | unknown_pseudo_header
    | pseudo_after_regular
    | empty_path
    | connection_specific_header.

%% Connection-specific headers banned in h2 per RFC 9113 §8.2.2.
%% `te` is allowed only with the value `trailers` — we reject all
%% other values. The other entries are unconditionally banned.
-define(BANNED_HEADERS, [
    ~"connection",
    ~"keep-alive",
    ~"proxy-connection",
    ~"transfer-encoding",
    ~"upgrade"
]).

-doc """
Build a request map from a decoded HPACK header list. `ConnInfo`
carries the per-connection bits the HTTP/1 conn already has —
peer, scheme (from the TLS tag), listener_name, request_id.

The returned map is `roadrunner_http1:request()` shape with
`version => {2, 0}`, `target` set to the `:path` pseudo-header
value, and `method` set to `:method`. The `:authority`
pseudo-header is forwarded as a `host` header so handlers that
read it via `roadrunner_req:header/2` still work.

`Body` is the concatenated DATA-frame payload bytes (or `<<>>`
for header-only requests).
""".
-spec from_headers([roadrunner_http2_hpack:header()], binary(), map()) ->
    {ok, roadrunner_http1:request()} | {error, build_error()}.
from_headers(Headers, Body, ConnInfo) ->
    case partition(Headers, #{}, []) of
        {error, _} = E ->
            E;
        {ok, Pseudo, Regular} ->
            case validate_pseudo(Pseudo) of
                {ok, Method, Scheme, Path, Authority} ->
                    case check_banned(Regular) of
                        ok ->
                            {ok,
                                build(
                                    Method,
                                    Scheme,
                                    Path,
                                    Authority,
                                    Regular,
                                    Body,
                                    ConnInfo
                                )};
                        {error, _} = E ->
                            E
                    end;
                {error, _} = E ->
                    E
            end
    end.

%% Walk the decoded header list, collecting pseudo-headers (names
%% starting with `:`) into a map keyed by name and regular headers
%% into a list. Body recursion — regular headers cons in front on
%% the way back out so the order matches the wire order.
-spec partition(
    [roadrunner_http2_hpack:header()],
    map(),
    [roadrunner_http2_hpack:header()]
) ->
    {ok, map(), [roadrunner_http2_hpack:header()]} | {error, build_error()}.
partition([], Pseudo, _Regular) ->
    %% End of input — caller picks up `Pseudo` from the map and
    %% the rest as regular headers (already in the accumulator).
    {ok, Pseudo, []};
partition([{<<":", _/binary>>, _} | _], _Pseudo, [_ | _]) ->
    %% Pseudo-header arrived after a regular header — RFC 9113
    %% §8.1.2.1 protocol error.
    {error, pseudo_after_regular};
partition([{<<":", _/binary>> = Name, Value} | Rest], Pseudo, []) ->
    case is_known_pseudo(Name) of
        false ->
            {error, unknown_pseudo_header};
        true ->
            case maps:is_key(Name, Pseudo) of
                true -> {error, duplicate_pseudo_header};
                false -> partition(Rest, Pseudo#{Name => Value}, [])
            end
    end;
partition([{Name, Value} | Rest], Pseudo, RegSeen) ->
    case partition(Rest, Pseudo, [{Name, Value} | RegSeen]) of
        {ok, Final, Tail} -> {ok, Final, [{Name, Value} | Tail]};
        {error, _} = E -> E
    end.

-spec is_known_pseudo(binary()) -> boolean().
is_known_pseudo(~":method") -> true;
is_known_pseudo(~":scheme") -> true;
is_known_pseudo(~":authority") -> true;
is_known_pseudo(~":path") -> true;
is_known_pseudo(_) -> false.

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

-spec check_banned([roadrunner_http2_hpack:header()]) ->
    ok | {error, connection_specific_header}.
check_banned([]) ->
    ok;
check_banned([{~"te", Value} | _]) when Value =/= ~"trailers" ->
    %% RFC 9113 §8.2.2: only `te: trailers` is allowed.
    {error, connection_specific_header};
check_banned([{Name, _} | Rest]) ->
    case lists:member(Name, ?BANNED_HEADERS) of
        true -> {error, connection_specific_header};
        false -> check_banned(Rest)
    end.

-spec build(
    binary(),
    binary(),
    binary(),
    binary() | undefined,
    [roadrunner_http2_hpack:header()],
    binary(),
    map()
) -> roadrunner_http1:request().
build(Method, _Scheme, Path, Authority, Regular, Body, ConnInfo) ->
    %% Forward `:authority` as a `host` header so existing h1
    %% handler code that reads `Host` still works. (RFC 9113
    %% §8.3.1 says an h2 server MUST treat `:authority` like
    %% `Host`.)
    HeadersWithHost =
        case Authority of
            undefined -> Regular;
            _ -> [{~"host", Authority} | Regular]
        end,
    Base = #{
        method => Method,
        target => Path,
        version => {2, 0},
        headers => HeadersWithHost,
        body => Body,
        bindings => #{},
        peer => maps:get(peer, ConnInfo, undefined),
        scheme => maps:get(scheme, ConnInfo, http),
        request_id => maps:get(request_id, ConnInfo, ~""),
        listener_name => maps:get(listener_name, ConnInfo, undefined)
    },
    Base.
