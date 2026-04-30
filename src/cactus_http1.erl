-module(cactus_http1).
-moduledoc """
HTTP/1.1 wire codec — pure binary parsers and encoders.

All functions are pure and incremental: parsers accept partial inputs
and return `{more, _}` until a complete unit can be decoded. They never
raise on hostile input — malformed bytes from the wire become
tagged `{error, _}` results, leaving the caller in control of the
response (`400`, `414`, `431`, etc.).
""".

-export([parse_request_line/1, parse_header/1]).

-export_type([version/0]).

-define(MAX_REQUEST_LINE, 8192).
-define(MAX_HEADER_LINE, 8192).

-type version() :: {1, 0} | {1, 1}.

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
parse_request_line(Bin) when is_binary(Bin) ->
    case binary:match(Bin, ~"\n") of
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
%% (uppercase ASCII letters only) still parse via the fallback; full RFC 7230
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
(continuation lines starting with whitespace, RFC 7230 §3.2.4), and
lines exceeding 8192 bytes are rejected with `bad_header` /
`header_too_long`. Header names follow the RFC 7230 token grammar.
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
    case binary:match(Bin, ~"\n") of
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
    %% Obs-fold continuation — RFC 7230 §3.2.4 says reject.
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
                ok -> {ok, string:lowercase(NameRaw), Value, Rest};
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

%% RFC 7230 token character — ALPHA / DIGIT / one of the listed marks.
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
