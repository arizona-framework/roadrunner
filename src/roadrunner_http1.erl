-module(roadrunner_http1).
-moduledoc """
HTTP/1.1 wire codec — pure binary parsers and encoders.

All functions are pure and incremental: parsers accept partial inputs
and return `{more, _}` until a complete unit can be decoded. They never
raise on hostile input — malformed bytes from the wire become
tagged `{error, _}` results, leaving the caller in control of the
response (`400`, `414`, `431`, etc.).
""".

-export([
    parse_request_line/1,
    parse_header/1,
    parse_headers/1,
    parse_request/1,
    parse_chunk/1,
    check_header_safe/2,
    response/3,
    compute_cached_decisions/1,
    http_date_now/0
]).

-export_type([version/0, headers/0, request/0, status/0, redirect_status/0, cached_decisions/0]).

-on_load(init_patterns/0).

-define(MAX_REQUEST_LINE, 8192).
-define(MAX_HEADER_LINE, 8192).
-define(MAX_HEADER_BLOCK, 10240).
-define(MAX_HEADER_COUNT, 100).
-define(MAX_CHUNK_HEADER, 8192).

%% `binary:match/2` accepts a pre-compiled pattern (`binary:cp()`), and
%% the compile cost is non-trivial. Microbench (OTP 29-rc3, single-byte
%% LF in a 56-byte header block, 200k iterations):
%%   raw `<<$\n>>`         : 32 ms
%%   compiled              : 16 ms  (50% faster)
%%   re:run with compiled  : 57 ms  (78% slower than raw — don't switch)
%% We compile the patterns the parser uses repeatedly and stash them in
%% `persistent_term` so each call reads a constant — `persistent_term:get/1`
%% measured at the same speed as a bound variable.
-define(UNSAFE_BYTES_KEY, {?MODULE, unsafe_bytes_cp}).
-define(LF_KEY, {?MODULE, lf_cp}).

-type version() :: {1, 0} | {1, 1}.
-type headers() :: [{Name :: binary(), Value :: binary()}].
-type status() :: 100..599.
-type redirect_status() :: 300..399.
-type cached_decisions() :: #{
    %% True iff `Transfer-Encoding: chunked` (case-insensitive). Hot path
    %% at body-framing time — saves a per-request lowercase scan.
    is_chunked := boolean(),
    %% True iff *any* `Transfer-Encoding` header is present (chunked or
    %% otherwise). Distinguishes "no TE → use Content-Length" from
    %% "non-chunked TE → bad_transfer_encoding" without a per-request
    %% header re-lookup. Always implied by `is_chunked := true`.
    has_transfer_encoding := boolean(),
    %% True iff `Expect: 100-continue` (case-insensitive). Used by the
    %% body-read path to decide whether to send a 100 before recv.
    expects_continue := boolean(),
    %% Lowercased value of the `Connection` header (`~""` if absent).
    %% `roadrunner_conn:keep_alive_decision/2` and `has_token/2` operate on
    %% this directly without re-lowercasing.
    connection_lower := binary(),
    %% Parsed `Content-Length`. `none` if absent; `{ok, N}` if a valid
    %% non-negative integer; `{error, bad_content_length}` if present but
    %% malformed. `roadrunner_conn:body_framing/1` consumes this directly
    %% on the cached path, avoiding a `roadrunner_req:header/2` lookup
    %% (which lowercases the lookup name) plus a `binary_to_integer/1`.
    content_length := none | {ok, non_neg_integer()} | {error, bad_content_length}
}.
-type request() :: #{
    method := binary(),
    target := binary(),
    version := version(),
    headers := headers(),
    %% Pre-computed decisions for known case-insensitive headers, populated
    %% by `parse_request/1`. Hot-path consumers (`roadrunner_conn:body_framing/1`,
    %% `keep_alive_decision/2`, `has_continue_expectation/1`) read these
    %% instead of re-lowercasing header values per request. Absent for
    %% manually-built request maps — consumers fall back to the raw
    %% `headers` list when missing.
    cached_decisions => cached_decisions(),
    %% Body is set by `roadrunner_conn` before the handler is invoked. The parser
    %% itself never populates this field — it leaves the buffered body in the
    %% `Rest` element of `parse_request/1` instead.
    body => binary(),
    %% Bindings captured from `:param` segments by `roadrunner_router`, also set
    %% by `roadrunner_conn` before dispatch. Empty map when the dispatch is a
    %% single-handler one (no routing) or the route has no params.
    bindings => roadrunner_router:bindings(),
    %% Client TCP peer captured once per connection from `inet:peername/1`.
    %% `undefined` when the OS call fails (rare; usually socket teardown).
    peer => {inet:ip_address(), inet:port_number()} | undefined,
    %% Connection scheme — `http` for plain TCP, `https` for TLS. Set
    %% once per connection by `roadrunner_conn` from the transport tag.
    scheme => http | https,
    %% Per-route opts attached at compile time via the 3-tuple route shape
    %% `{Path, Handler, Opts}`. `undefined` for 2-tuple routes and for
    %% single-handler dispatch (no router involved).
    route_opts => term(),
    %% Body-read state attached by `roadrunner_conn` in `body_buffering => manual`
    %% mode. Threaded through `roadrunner_req:read_body/1,2`. Never present in
    %% `auto` mode or in manually-constructed request maps.
    body_state => roadrunner_conn:body_state(),
    %% Per-request correlation token attached by `roadrunner_conn` once the
    %% headers parse. 16 lowercase hex chars (8 bytes of CSPRNG output).
    %% Mirrored into `logger:set_process_metadata/1` so any `?LOG_*` call
    %% from middleware or the handler picks it up automatically.
    request_id => binary(),
    %% Registered name of the owning `roadrunner_listener`. Set once per
    %% conn from `proto_opts.listener_name`. Surfaced in
    %% `roadrunner_telemetry` event metadata so subscribers can filter by
    %% listener in multi-listener deployments.
    listener_name => atom()
}.

-doc """
Parse the HTTP/1.1 request line.

On success returns the method, request-target, version, and the bytes
that follow the terminating CRLF (the start of the header block).

The request line is capped at 8192 bytes per OTP hardening guidance;
oversized lines are rejected with `request_line_too_long` so the
connection layer can answer `414 URI Too Long`.

Bare LF terminators are rejected as `bad_request_line` per RFC 9112 §2.2.
""".
%% The {more, undefined} return is a deliberate narrowing of the broader
%% {more, undefined | pos_integer()} shape used elsewhere — we do not yet
%% hint at how many more bytes the caller should read. Widen if/when needed.
-spec parse_request_line(binary()) ->
    {ok, Method :: binary(), Target :: binary(), version(), Rest :: binary()}
    | {more, undefined}
    | {error, bad_request_line | bad_version | request_line_too_long}.
%% RFC 9112 §2.2 robustness allowance: a server SHOULD ignore at least
%% one empty line received prior to the request-line. We strip one
%% optional leading `\r\n` and then parse normally. Two consecutive
%% leading CRLFs still fail (the second one becomes a malformed
%% request-line) so this doesn't open a slowloris-style padding vector.
parse_request_line(<<"\r\n", Rest/binary>>) ->
    do_parse_request_line(Rest);
parse_request_line(Bin) when is_binary(Bin) ->
    do_parse_request_line(Bin).

-spec do_parse_request_line(binary()) ->
    {ok, Method :: binary(), Target :: binary(), version(), Rest :: binary()}
    | {more, undefined}
    | {error, bad_request_line | bad_version | request_line_too_long}.
do_parse_request_line(Bin) ->
    case binary:match(Bin, persistent_term:get(?LF_KEY)) of
        nomatch when byte_size(Bin) > ?MAX_REQUEST_LINE ->
            {error, request_line_too_long};
        nomatch ->
            {more, undefined};
        {0, 1} ->
            {error, bad_request_line};
        {LfPos, 1} ->
            extract_line(Bin, LfPos)
    end.

-spec extract_line(binary(), pos_integer()) ->
    {ok, binary(), binary(), version(), binary()}
    | {error, bad_request_line | bad_version | request_line_too_long}.
extract_line(Bin, LfPos) ->
    LineLen = LfPos - 1,
    case Bin of
        <<Line:LineLen/binary, "\r\n", Rest/binary>> when LineLen =< ?MAX_REQUEST_LINE ->
            parse_line(Line, Rest);
        <<_:LineLen/binary, "\r\n", _/binary>> ->
            {error, request_line_too_long};
        _ ->
            {error, bad_request_line}
    end.

-spec parse_line(binary(), binary()) ->
    {ok, binary(), binary(), version(), binary()}
    | {error, bad_request_line | bad_version}.
parse_line(Line, Rest) ->
    case binary:split(Line, ~" ", [global]) of
        [Method, Target, VersionBin] ->
            classify(Method, Target, VersionBin, Rest);
        _ ->
            {error, bad_request_line}
    end.

-spec classify(binary(), binary(), binary(), binary()) ->
    {ok, binary(), binary(), version(), binary()}
    | {error, bad_request_line | bad_version}.
classify(Method, Target, VersionBin, Rest) ->
    case validate_method(Method) of
        ok ->
            case validate_target(Target) of
                ok ->
                    case parse_version(VersionBin) of
                        {ok, V} -> {ok, Method, Target, V, Rest};
                        error -> {error, bad_version}
                    end;
                error ->
                    {error, bad_request_line}
            end;
        error ->
            {error, bad_request_line}
    end.

%% Fast path for standard methods — JIT pattern-table dispatch avoids the
%% per-byte scan in validate_method_chars/1 on the hot path. Custom methods
%% (uppercase ASCII letters only) still parse via the fallback; full RFC 9110 §5.6.2
%% token grammar (digits, lowercase, `-`, etc.) is intentionally not accepted
%% — extension methods like WebDAV's MKCOL or UPnP's M-SEARCH would need it.
-spec validate_method(binary()) -> ok | error.
validate_method(~"GET") -> ok;
validate_method(~"POST") -> ok;
validate_method(~"PUT") -> ok;
validate_method(~"DELETE") -> ok;
validate_method(~"PATCH") -> ok;
validate_method(~"HEAD") -> ok;
validate_method(~"OPTIONS") -> ok;
validate_method(<<>>) -> error;
validate_method(M) -> validate_method_chars(M).

-spec validate_method_chars(binary()) -> ok | error.
validate_method_chars(<<>>) ->
    ok;
validate_method_chars(<<C, Rest/binary>>) when C >= $A, C =< $Z ->
    validate_method_chars(Rest);
validate_method_chars(_) ->
    error.

-spec validate_target(binary()) -> ok | error.
validate_target(<<>>) -> error;
validate_target(T) -> validate_target_chars(T).

-spec validate_target_chars(binary()) -> ok | error.
validate_target_chars(<<>>) ->
    ok;
validate_target_chars(<<C, Rest/binary>>) when C > 16#20, C =/= 16#7F ->
    validate_target_chars(Rest);
validate_target_chars(_) ->
    error.

-spec parse_version(binary()) -> {ok, version()} | error.
parse_version(~"HTTP/1.1") -> {ok, {1, 1}};
parse_version(~"HTTP/1.0") -> {ok, {1, 0}};
parse_version(_) -> error.

-doc """
Parse a single HTTP/1.1 header line.

The argument is the unconsumed buffer after the request line (or a
previous header). On success returns `{ok, Name, Value, Rest}` with the
name lowercased and the value trimmed of leading/trailing OWS; the
`Rest` is the remaining buffer for the next call.

When the input begins with the empty line that terminates the header
block, returns `{end_of_headers, Rest}` so the caller can switch to
body framing without re-scanning bytes.

Header injection (CR or NUL inside a value), obsolete line folding
(continuation lines starting with whitespace, RFC 9112 §5.2 obs-fold),
and lines exceeding 8192 bytes are rejected with `bad_header` /
`header_too_long`. Header names follow the RFC 9110 §5.6.2 token grammar.
""".
%% Spec deviates from the original plan: we return `{end_of_headers, Rest}`
%% (a tuple) rather than the bare atom `end_of_headers`, so the caller does
%% not lose track of the body bytes that follow the empty line.
-spec parse_header(binary()) ->
    {ok, Name :: binary(), Value :: binary(), Rest :: binary()}
    | {end_of_headers, Rest :: binary()}
    | {more, undefined}
    | {error, bad_header | header_too_long}.
parse_header(Bin) when is_binary(Bin) ->
    parse_header(Bin, persistent_term:get(?LF_KEY)).

%% Internal — accepts the compiled LF pattern so callers in a loop
%% (e.g. `parse_headers_loop/4`) can fetch it once and pass it
%% through, instead of paying a `persistent_term:get/1` per header.
-spec parse_header(binary(), binary:cp()) ->
    {ok, binary(), binary(), binary()}
    | {end_of_headers, binary()}
    | {more, undefined}
    | {error, bad_header | header_too_long}.
parse_header(Bin, LfCp) ->
    case binary:match(Bin, LfCp) of
        nomatch when byte_size(Bin) > ?MAX_HEADER_LINE ->
            {error, header_too_long};
        nomatch ->
            {more, undefined};
        {0, 1} ->
            {error, bad_header};
        {LfPos, 1} ->
            extract_header_line(Bin, LfPos)
    end.

-spec extract_header_line(binary(), pos_integer()) ->
    {ok, binary(), binary(), binary()}
    | {end_of_headers, binary()}
    | {error, bad_header | header_too_long}.
extract_header_line(Bin, LfPos) ->
    LineLen = LfPos - 1,
    case Bin of
        <<Line:LineLen/binary, "\r\n", Rest/binary>> when LineLen =< ?MAX_HEADER_LINE ->
            case Line of
                <<>> -> {end_of_headers, Rest};
                _ -> parse_header_line(Line, Rest)
            end;
        <<_:LineLen/binary, "\r\n", _/binary>> ->
            {error, header_too_long};
        _ ->
            {error, bad_header}
    end.

-spec parse_header_line(binary(), binary()) ->
    {ok, binary(), binary(), binary()} | {error, bad_header}.
parse_header_line(<<C, _/binary>>, _Rest) when C =:= $\s; C =:= $\t ->
    %% Obs-fold continuation — RFC 9112 §5.2 says servers MUST reject.
    {error, bad_header};
parse_header_line(Line, Rest) ->
    case binary:split(Line, ~":") of
        [NameRaw, ValueRaw] ->
            classify_header(NameRaw, ValueRaw, Rest);
        [_] ->
            {error, bad_header}
    end.

-spec classify_header(binary(), binary(), binary()) ->
    {ok, binary(), binary(), binary()} | {error, bad_header}.
classify_header(NameRaw, ValueRaw, Rest) ->
    case validate_name(NameRaw) of
        ok ->
            Value = trim_ows(ValueRaw),
            case validate_value(Value) of
                ok -> {ok, roadrunner_bin:ascii_lowercase(NameRaw), Value, Rest};
                error -> {error, bad_header}
            end;
        error ->
            {error, bad_header}
    end.

-spec validate_name(binary()) -> ok | error.
validate_name(<<>>) -> error;
validate_name(N) -> validate_name_chars(N).

-spec validate_name_chars(binary()) -> ok | error.
validate_name_chars(<<>>) ->
    ok;
validate_name_chars(<<C, R/binary>>) ->
    case is_tchar(C) of
        true -> validate_name_chars(R);
        false -> error
    end.

%% RFC 9110 §5.6.2 tchar — ALPHA / DIGIT / one of the listed marks.
-spec is_tchar(byte()) -> boolean().
is_tchar(C) when C >= $A, C =< $Z -> true;
is_tchar(C) when C >= $a, C =< $z -> true;
is_tchar(C) when C >= $0, C =< $9 -> true;
is_tchar(C) when
    C =:= $!;
    C =:= $#;
    C =:= $$;
    C =:= $%;
    C =:= $&;
    C =:= $';
    C =:= $*;
    C =:= $+;
    C =:= $-;
    C =:= $.;
    C =:= $^;
    C =:= $_;
    C =:= $`;
    C =:= $|;
    C =:= $~
->
    true;
is_tchar(_) ->
    false.

-spec trim_ows(binary()) -> binary().
trim_ows(B) -> trim_trailing_ows(trim_leading_ows(B)).

-spec trim_leading_ows(binary()) -> binary().
trim_leading_ows(<<C, R/binary>>) when C =:= $\s; C =:= $\t ->
    trim_leading_ows(R);
trim_leading_ows(B) ->
    B.

-spec trim_trailing_ows(binary()) -> binary().
trim_trailing_ows(<<>>) ->
    <<>>;
trim_trailing_ows(B) ->
    Size = byte_size(B),
    case binary:at(B, Size - 1) of
        C when C =:= $\s; C =:= $\t ->
            trim_trailing_ows(binary:part(B, 0, Size - 1));
        _ ->
            B
    end.

%% Reject CR, LF, NUL, and other CTL bytes inside header values; HTAB allowed.
%% Bytes >= 0x80 (non-ASCII) are accepted leniently — same as cowboy.
-spec validate_value(binary()) -> ok | error.
validate_value(<<>>) ->
    ok;
validate_value(<<C, R/binary>>) when
    C =:= 16#09;
    C >= 16#20, C =< 16#7E;
    C >= 16#80
->
    validate_value(R);
validate_value(_) ->
    error.

-doc """
Parse the full HTTP/1.1 header block.

Loops `parse_header/1` until the empty line that ends the block,
returning the accumulated headers in wire order (repeated headers
preserved as separate entries — important for `Set-Cookie`).

Enforces three hardening limits per OTP PR #11073:
- `max_header_count` = 100
- `max_header_block` = 10240 bytes (cumulative)
- HTTP request smuggling: rejects any block that mixes
  `Transfer-Encoding` with `Content-Length`, or that contains
  multiple `Content-Length` headers with differing values.
""".
-spec parse_headers(binary()) ->
    {ok, headers(), Rest :: binary()}
    | {more, undefined}
    | {error,
        bad_header
        | header_too_long
        | header_block_too_long
        | too_many_headers
        | conflicting_framing}.
parse_headers(Bin) when is_binary(Bin) ->
    %% Fetch the compiled LF pattern ONCE here and thread it through
    %% the per-header loop. Saves a `persistent_term:get/1` per header
    %% (was ~6 per parse on a typical request; now 1).
    LfCp = persistent_term:get(?LF_KEY),
    case parse_headers_loop(Bin, 0, 0, LfCp) of
        {ok, Headers, Rest} ->
            case check_framing(Headers) of
                ok -> {ok, Headers, Rest};
                error -> {error, conflicting_framing}
            end;
        Other ->
            Other
    end.

-spec parse_headers_loop(binary(), non_neg_integer(), non_neg_integer(), binary:cp()) ->
    {ok, headers(), binary()}
    | {more, undefined}
    | {error,
        bad_header
        | header_too_long
        | header_block_too_long
        | too_many_headers}.
parse_headers_loop(_Bin, Count, _Consumed, _LfCp) when Count > ?MAX_HEADER_COUNT ->
    {error, too_many_headers};
parse_headers_loop(_Bin, _Count, Consumed, _LfCp) when Consumed > ?MAX_HEADER_BLOCK ->
    {error, header_block_too_long};
parse_headers_loop(Bin, Count, Consumed, LfCp) ->
    case parse_header(Bin, LfCp) of
        {ok, Name, Value, Rest} ->
            Used = byte_size(Bin) - byte_size(Rest),
            case parse_headers_loop(Rest, Count + 1, Consumed + Used, LfCp) of
                {ok, Tail, FinalRest} -> {ok, [{Name, Value} | Tail], FinalRest};
                Other -> Other
            end;
        {end_of_headers, Rest} ->
            {ok, [], Rest};
        {more, _} = More ->
            More;
        {error, _} = Err ->
            Err
    end.

%% Reject the two classic smuggling shapes:
%% 1. Transfer-Encoding present alongside any Content-Length.
%% 2. Multiple Content-Length headers with differing values.
-spec check_framing(headers()) -> ok | error.
check_framing(Headers) ->
    HasTE = lists:keymember(~"transfer-encoding", 1, Headers),
    Cls = [V || {N, V} <- Headers, N =:= ~"content-length"],
    check_framing(HasTE, Cls).

-spec check_framing(boolean(), [binary()]) -> ok | error.
check_framing(true, []) -> ok;
check_framing(false, []) -> ok;
check_framing(false, [V | Rest]) -> check_cls_consistent(V, Rest);
check_framing(true, [_ | _]) -> error.

-spec check_cls_consistent(binary(), [binary()]) -> ok | error.
check_cls_consistent(_, []) -> ok;
check_cls_consistent(V, [V | Rest]) -> check_cls_consistent(V, Rest);
check_cls_consistent(_, _) -> error.

-doc """
Walk a parsed header list once and return pre-computed decisions for the
case-insensitive headers that the connection layer reads on every request.

Header names are already lowercased by `parse_header/1`; this pass also
lowercases the value of `Connection` (whose tokens are case-insensitive
per RFC 9110) and computes booleans for `Transfer-Encoding: chunked` and
`Expect: 100-continue`.

Reusing the cached values avoids ~3 lowercase scans per request on the
hot path measured via `scripts/stress.escript --profile`.
""".
-spec compute_cached_decisions(headers()) -> cached_decisions().
compute_cached_decisions(Headers) ->
    compute_cached_decisions_loop(Headers, #{
        is_chunked => false,
        has_transfer_encoding => false,
        expects_continue => false,
        connection_lower => ~"",
        content_length => none
    }).

-spec compute_cached_decisions_loop(headers(), cached_decisions()) -> cached_decisions().
compute_cached_decisions_loop([], Acc) ->
    Acc;
compute_cached_decisions_loop([{~"transfer-encoding", V} | Rest], Acc) ->
    Acc1 = Acc#{has_transfer_encoding := true},
    Acc2 =
        case roadrunner_bin:ascii_lowercase(V) of
            ~"chunked" -> Acc1#{is_chunked := true};
            _ -> Acc1
        end,
    compute_cached_decisions_loop(Rest, Acc2);
compute_cached_decisions_loop([{~"expect", V} | Rest], Acc) ->
    Acc1 =
        case roadrunner_bin:ascii_lowercase(V) of
            ~"100-continue" -> Acc#{expects_continue := true};
            _ -> Acc
        end,
    compute_cached_decisions_loop(Rest, Acc1);
compute_cached_decisions_loop([{~"connection", V} | Rest], Acc) ->
    compute_cached_decisions_loop(
        Rest, Acc#{connection_lower := roadrunner_bin:ascii_lowercase(V)}
    );
compute_cached_decisions_loop([{~"content-length", V} | Rest], Acc) ->
    compute_cached_decisions_loop(Rest, Acc#{content_length := parse_content_length(V)});
compute_cached_decisions_loop([_ | Rest], Acc) ->
    compute_cached_decisions_loop(Rest, Acc).

-spec parse_content_length(binary()) ->
    {ok, non_neg_integer()} | {error, bad_content_length}.
parse_content_length(V) ->
    try binary_to_integer(V) of
        N when N >= 0 -> {ok, N};
        _ -> {error, bad_content_length}
    catch
        _:_ -> {error, bad_content_length}
    end.

-doc """
Parse a complete HTTP/1.1 request (request line + header block).

Returns `{ok, Request, Rest}` where `Request` is a map with `method`,
`target`, `version`, and `headers` keys, and `Rest` is the remaining
buffer (the start of the body, not yet framed).

Body framing (Content-Length / chunked) is the next layer's job —
this function stops cleanly at the empty line that terminates the
header block.

Spec deviates from the original plan: the result is a map rather than
a record, so callers don't need to include a header file.
""".
-spec parse_request(binary()) ->
    {ok, request(), Rest :: binary()}
    | {more, undefined}
    | {error,
        bad_request_line
        | bad_version
        | request_line_too_long
        | bad_header
        | header_too_long
        | header_block_too_long
        | too_many_headers
        | conflicting_framing
        | missing_host}.
parse_request(Bin) when is_binary(Bin) ->
    case parse_request_line(Bin) of
        {ok, Method, Target, Version, Rest} ->
            case parse_headers(Rest) of
                {ok, Headers, Rest2} ->
                    case validate_host(Version, Headers) of
                        ok ->
                            Req = #{
                                method => Method,
                                target => Target,
                                version => Version,
                                headers => Headers,
                                cached_decisions => compute_cached_decisions(Headers)
                            },
                            {ok, Req, Rest2};
                        {error, _} = HostErr ->
                            HostErr
                    end;
                {more, _} = More ->
                    More;
                {error, _} = Err ->
                    Err
            end;
        {more, _} = More ->
            More;
        {error, _} = Err ->
            Err
    end.

%% RFC 9112 §3.2 / 7230 §5.4: HTTP/1.1 requests MUST include a Host
%% header. Absence is a 400 Bad Request, also a request-smuggling
%% mitigation when proxies forward to backends that disagree on the
%% target host. HTTP/1.0 didn't require it.
-spec validate_host(version(), headers()) -> ok | {error, missing_host}.
validate_host({1, 1}, Headers) ->
    case lists:keymember(~"host", 1, Headers) of
        true -> ok;
        false -> {error, missing_host}
    end;
validate_host({1, 0}, _Headers) ->
    ok.

-doc """
Parse a single chunk from a chunked transfer-encoded body.

Returns one of:
- `{ok, Data, Rest}` for a regular chunk — `Data` is the chunk payload,
  `Rest` is the buffer starting at the next chunk header.
- `{ok, last, Trailers, Rest}` when the size-0 last chunk is reached —
  `Trailers` is the (possibly empty) trailer header block, `Rest` is
  whatever follows the empty line that closes it (typically the start
  of the next pipelined message).
- `{more, undefined}` when more bytes are needed.
- `{error, bad_chunk_size}` when the size field cannot be parsed (bad
  hex, empty, etc.).
- `{error, bad_chunk}` for any other structural failure (oversized
  chunk header, missing CRLF after data).

Chunk extensions are parsed and discarded per RFC 9112 §7.1. The chunk
header line is capped at 8192 bytes.
""".
-spec parse_chunk(binary()) ->
    {ok, Data :: binary(), Rest :: binary()}
    | {ok, last, Trailers :: headers(), Rest :: binary()}
    | {more, undefined}
    | {error,
        bad_chunk_size
        | bad_chunk
        | bad_header
        | header_too_long
        | header_block_too_long
        | too_many_headers
        | conflicting_framing}.
parse_chunk(Bin) when is_binary(Bin) ->
    case parse_chunk_size_line(Bin) of
        {ok, 0, AfterSize} ->
            parse_last_chunk(AfterSize);
        {ok, Size, AfterSize} ->
            parse_chunk_data(Size, AfterSize);
        Other ->
            Other
    end.

-spec parse_last_chunk(binary()) ->
    {ok, last, headers(), binary()}
    | {more, undefined}
    | {error,
        bad_header
        | header_too_long
        | header_block_too_long
        | too_many_headers
        | conflicting_framing}.
parse_last_chunk(AfterSize) ->
    case parse_headers(AfterSize) of
        {ok, Trailers, Rest} -> {ok, last, Trailers, Rest};
        {more, _} = More -> More;
        {error, _} = Err -> Err
    end.

-spec parse_chunk_data(pos_integer(), binary()) ->
    {ok, binary(), binary()} | {more, undefined} | {error, bad_chunk}.
parse_chunk_data(Size, AfterSize) ->
    case AfterSize of
        <<Data:Size/binary, "\r\n", Rest/binary>> ->
            {ok, Data, Rest};
        _ when byte_size(AfterSize) < Size + 2 ->
            {more, undefined};
        _ ->
            {error, bad_chunk}
    end.

-spec parse_chunk_size_line(binary()) ->
    {ok, non_neg_integer(), binary()}
    | {more, undefined}
    | {error, bad_chunk_size | bad_chunk}.
parse_chunk_size_line(Bin) ->
    case binary:match(Bin, ~"\r\n") of
        nomatch when byte_size(Bin) > ?MAX_CHUNK_HEADER ->
            {error, bad_chunk};
        nomatch ->
            {more, undefined};
        {Pos, 2} when Pos > ?MAX_CHUNK_HEADER ->
            {error, bad_chunk};
        {Pos, 2} ->
            <<Line:Pos/binary, "\r\n", Rest/binary>> = Bin,
            parse_size_line(Line, Rest)
    end.

-spec parse_size_line(binary(), binary()) ->
    {ok, non_neg_integer(), binary()} | {error, bad_chunk_size}.
parse_size_line(Line, Rest) ->
    SizePart =
        case binary:split(Line, ~";") of
            [S] -> S;
            [S, _Ext] -> S
        end,
    %% Per RFC 9112 §7.1: chunk-size = 1*HEXDIG. BWS is allowed before
    %% `;` (chunk-ext separator) but NOT before the chunk-size itself —
    %% so trim only trailing OWS, never leading. ` 5\r\n` is malformed;
    %% `5 ;ext\r\n` is fine.
    case parse_hex(trim_trailing_ows(SizePart)) of
        {ok, N} -> {ok, N, Rest};
        error -> {error, bad_chunk_size}
    end.

-spec parse_hex(binary()) -> {ok, non_neg_integer()} | error.
parse_hex(<<>>) -> error;
parse_hex(B) -> parse_hex_chars(B, 0).

-spec parse_hex_chars(binary(), non_neg_integer()) -> {ok, non_neg_integer()} | error.
parse_hex_chars(<<>>, Acc) ->
    {ok, Acc};
parse_hex_chars(<<C, R/binary>>, Acc) when C >= $0, C =< $9 ->
    parse_hex_chars(R, Acc * 16 + (C - $0));
parse_hex_chars(<<C, R/binary>>, Acc) when C >= $a, C =< $f ->
    parse_hex_chars(R, Acc * 16 + (C - $a + 10));
parse_hex_chars(<<C, R/binary>>, Acc) when C >= $A, C =< $F ->
    parse_hex_chars(R, Acc * 16 + (C - $A + 10));
parse_hex_chars(_, _) ->
    error.

-doc """
Build a complete HTTP/1.1 response message.

Returns iodata — caller is free to write directly to a socket without a
flatten step. The caller is responsible for content framing: this
function does **not** auto-inject `Content-Length` or `Transfer-Encoding`
headers, nor a `Server` token (a higher-level builder will do that).

Status reason phrases are looked up for the common HTTP codes; unknown
codes get an empty reason (RFC 9112 §4.1 makes the phrase optional).
""".
-spec response(StatusCode :: status(), headers(), iodata()) -> iodata().
response(Status, Headers, Body) when is_integer(Status, 100, 599) ->
    [status_line(Status), encode_headers(Headers), ~"\r\n", Body].

-doc """
Format the current UTC time as an IMF-fixdate per RFC 9110 §5.6.7
— the canonical HTTP `Date` header format, e.g.
`Sun, 06 Nov 1994 08:49:37 GMT`. Used by the dispatch layer to
auto-inject the `Date` response header per RFC 9110 §6.6.1.
""".
-define(DAY_NAMES, {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}).
-define(MONTH_NAMES,
    {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
).

-spec http_date_now() -> binary().
http_date_now() ->
    {{Y, M, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(
        erlang:system_time(second), second
    ),
    DayName = element(calendar:day_of_the_week(Y, M, D), ?DAY_NAMES),
    MonthName = element(M, ?MONTH_NAMES),
    iolist_to_binary(
        io_lib:format(
            "~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B GMT",
            [DayName, D, MonthName, Y, H, Mi, S]
        )
    ).

%% Common status codes get a precomputed `HTTP/1.1 NNN Reason\r\n`
%% binary — one binary literal vs the five-element iolist build
%% (`integer_to_binary(Status)` + `reason/1` + spacers) the slow
%% path allocates per response. Wire bytes match the slow-path
%% output exactly: only codes covered by `reason/1` appear here,
%% with their reason phrase verbatim. Less common codes fall
%% through to the original construction.
-spec status_line(status()) -> binary() | iodata().
status_line(200) -> ~"HTTP/1.1 200 OK\r\n";
status_line(201) -> ~"HTTP/1.1 201 Created\r\n";
status_line(204) -> ~"HTTP/1.1 204 No Content\r\n";
status_line(301) -> ~"HTTP/1.1 301 Moved Permanently\r\n";
status_line(302) -> ~"HTTP/1.1 302 Found\r\n";
status_line(304) -> ~"HTTP/1.1 304 Not Modified\r\n";
status_line(400) -> ~"HTTP/1.1 400 Bad Request\r\n";
status_line(401) -> ~"HTTP/1.1 401 Unauthorized\r\n";
status_line(403) -> ~"HTTP/1.1 403 Forbidden\r\n";
status_line(404) -> ~"HTTP/1.1 404 Not Found\r\n";
status_line(500) -> ~"HTTP/1.1 500 Internal Server Error\r\n";
status_line(503) -> ~"HTTP/1.1 503 Service Unavailable\r\n";
%% Uncommon status codes — emit `HTTP/1.1 NNN \r\n` with an empty
%% reason phrase. RFC 9112 §4.1 explicitly allows the phrase to be
%% absent. Listeners that want a custom reason for an uncommon code
%% can return the response head themselves via the `{stream, ...}`
%% or `{sendfile, ...}` shapes.
status_line(Status) -> [~"HTTP/1.1 ", integer_to_binary(Status), ~" \r\n"].

-spec encode_headers(headers()) -> iodata().
encode_headers(Headers) ->
    %% Fetch the unsafe-bytes pattern ONCE here and thread it through
    %% the per-header injection check. Saves a `persistent_term:get/1`
    %% per header (was 2 per header for name + value).
    UnsafeCp = persistent_term:get(?UNSAFE_BYTES_KEY),
    encode_headers_loop(Headers, UnsafeCp).

-spec encode_headers_loop(headers(), binary:cp()) -> iodata().
encode_headers_loop([], _UnsafeCp) ->
    [];
encode_headers_loop([{Name, Value} | Rest], UnsafeCp) ->
    %% Defend against HTTP response splitting / header injection: any
    %% CR, LF, or NUL in a header name or value would let an attacker
    %% who controls part of either inject an entirely new header (or
    %% terminate the header block early). Crash hard so a programmer
    %% bug — usually echoing user input into a header without
    %% validation — turns into a 500, not a wire-level vulnerability.
    ok = check_header_safe(Name, name, UnsafeCp),
    ok = check_header_safe(Value, value, UnsafeCp),
    [Name, ~": ", Value, ~"\r\n" | encode_headers_loop(Rest, UnsafeCp)].

-doc """
Validate that a header name or value contains no CR, LF, or NUL —
the bytes that would let an attacker who controls the value inject
new headers (or terminate the header block early). Crashes with
`{header_injection, Kind, Bin}` when an unsafe byte is present.

Public so other modules emitting headers (e.g. `roadrunner_conn` for
chunked-response trailers) can run the same check before writing
to the wire.
""".
-spec check_header_safe(binary(), name | value) -> ok.
check_header_safe(Bin, Kind) when is_binary(Bin) ->
    check_header_safe(Bin, Kind, persistent_term:get(?UNSAFE_BYTES_KEY)).

%% Internal entry that accepts a pre-fetched pattern. Used by
%% `encode_headers/1` to avoid a `persistent_term:get/1` per
%% (name, value) pair on the response hot path.
-spec check_header_safe(binary(), name | value, binary:cp()) -> ok.
check_header_safe(Bin, Kind, UnsafeCp) when is_binary(Bin) ->
    case binary:match(Bin, UnsafeCp) of
        nomatch -> ok;
        _ -> error({header_injection, Kind, Bin})
    end.

%% `-on_load` callback. Returns `ok` so module load succeeds; if the
%% compile fails (it shouldn't — the pattern is a literal), the module
%% won't load and we'll see it loudly.
-spec init_patterns() -> ok.
init_patterns() ->
    persistent_term:put(
        ?UNSAFE_BYTES_KEY,
        binary:compile_pattern([~"\r", ~"\n", ~"\0"])
    ),
    persistent_term:put(?LF_KEY, binary:compile_pattern(~"\n")),
    ok.
