-module(roadrunner_cookie).
-moduledoc """
HTTP cookie codec (RFC 6265).

Provides `parse/1` for the request-side `Cookie` header and
`serialize/3` for the response-side `Set-Cookie` header.
""".

-on_load(init_patterns/0).

-define(SEMI_CP_KEY, {?MODULE, semi_cp}).
-define(EQ_CP_KEY, {?MODULE, eq_cp}).

-export([parse/1, serialize/3]).

-export_type([serialize_opts/0]).

-type serialize_opts() :: #{
    domain => binary(),
    path => binary(),
    max_age => non_neg_integer(),
    expires => binary(),
    secure => boolean(),
    http_only => boolean(),
    same_site => strict | lax | none
}.

-doc """
Parse a `Cookie` header value into a list of `{Name, Value}` pairs in
the order they appear on the wire.

OWS (SP and HTAB) around each pair is trimmed. Pairs missing `=` or
with an empty name are silently skipped (cowboy parity); empty values
are accepted. Only the first `=` in a pair separates name from value,
so a cookie like `sid=a=b=c` parses as a single pair with value `a=b=c`.
""".
-spec parse(binary()) -> [{binary(), binary()}].
parse(<<>>) ->
    [];
parse(Bin) when is_binary(Bin) ->
    EqCp = persistent_term:get(?EQ_CP_KEY),
    parse_pairs(binary:split(Bin, persistent_term:get(?SEMI_CP_KEY), [global]), EqCp).

-spec parse_pairs([binary()], binary:cp()) -> [{binary(), binary()}].
parse_pairs([], _EqCp) ->
    [];
parse_pairs([Pair | Rest], EqCp) ->
    %% RFC 6265 §5.2: trim name and value of leading/trailing OWS
    %% **separately** — `<<"  a  =b">>` should yield Name = `<<"a">>`,
    %% not `<<"a  ">>`. Trimming the whole pair first would miss the
    %% spaces around `=`.
    case binary:split(Pair, EqCp) of
        [RawName, RawValue] ->
            case roadrunner_bin:trim_ows(RawName) of
                <<>> ->
                    parse_pairs(Rest, EqCp);
                Name ->
                    [{Name, roadrunner_bin:trim_ows(RawValue)} | parse_pairs(Rest, EqCp)]
            end;
        _ ->
            parse_pairs(Rest, EqCp)
    end.

-doc """
Build a `Set-Cookie` header value as iodata.

Attributes are appended in this fixed order: `Domain`, `Path`,
`Max-Age`, `Expires`, `Secure`, `HttpOnly`, `SameSite`. Boolean flags
(`secure`, `http_only`) appear only when set to `true`; setting them
to `false` is equivalent to omitting them. `same_site` accepts
`strict`, `lax`, or `none`.

Each user-supplied binary is validated against the RFC 6265 §4.1.1
grammar before any iodata is produced; on a violation the call crashes
with one of:

- `{invalid_cookie_name, Bin}` — `Name` is empty or has a byte outside
  RFC 7230 §3.2.6 `token`
- `{invalid_cookie_value, Bin}` — `Value` has a byte outside
  `cookie-octet` (CTL, SP, DQUOTE, `,`, `;`, `\\`)
- `{invalid_cookie_attr, AttrName, Bin}` — `Domain`, `Path`, or
  `Expires` contains a CTL or `;` (the bytes that would let a
  malicious caller smuggle attributes or split the header line)

Crashing matches the discipline applied elsewhere in the framework:
a programmer bug echoing user input into a cookie turns into a 500, not
a wire-level vulnerability.
""".
-spec serialize(Name :: binary(), Value :: binary(), serialize_opts()) -> iodata().
serialize(Name, Value, Opts) when is_binary(Name), is_binary(Value), is_map(Opts) ->
    ok = valid_name(Name),
    ok = valid_value(Value, Value),
    [
        Name,
        $=,
        Value,
        attr_domain(Opts),
        attr_path(Opts),
        attr_max_age(Opts),
        attr_expires(Opts),
        attr_secure(Opts),
        attr_http_only(Opts),
        attr_same_site(Opts)
    ].

-spec attr_domain(serialize_opts()) -> iodata().
attr_domain(#{domain := D}) when is_binary(D) ->
    ok = valid_attr_domain(D, D),
    [~"; Domain=", D];
attr_domain(_) ->
    [].

-spec attr_path(serialize_opts()) -> iodata().
attr_path(#{path := P}) when is_binary(P) ->
    ok = valid_attr_path(P, P),
    [~"; Path=", P];
attr_path(_) ->
    [].

-spec attr_max_age(serialize_opts()) -> iodata().
attr_max_age(#{max_age := N}) when is_integer(N), N >= 0 ->
    [~"; Max-Age=", integer_to_binary(N)];
attr_max_age(_) ->
    [].

-spec attr_expires(serialize_opts()) -> iodata().
attr_expires(#{expires := E}) when is_binary(E) ->
    ok = valid_attr_expires(E, E),
    [~"; Expires=", E];
attr_expires(_) ->
    [].

-spec attr_secure(serialize_opts()) -> binary() | [].
attr_secure(#{secure := true}) -> ~"; Secure";
attr_secure(_) -> [].

-spec attr_http_only(serialize_opts()) -> binary() | [].
attr_http_only(#{http_only := true}) -> ~"; HttpOnly";
attr_http_only(_) -> [].

-spec attr_same_site(serialize_opts()) -> binary() | [].
attr_same_site(#{same_site := strict}) -> ~"; SameSite=Strict";
attr_same_site(#{same_site := lax}) -> ~"; SameSite=Lax";
attr_same_site(#{same_site := none}) -> ~"; SameSite=None";
attr_same_site(_) -> [].

%% RFC 6265 §4.1.1: cookie-name = token (RFC 7230 §3.2.6). Empty
%% rejected. The recursion splits into a separate "tail" walker so
%% the bottoming-out `<<>>` clause means "consumed every byte" rather
%% than "empty input".
-spec valid_name(binary()) -> ok.
valid_name(<<>>) ->
    error({invalid_cookie_name, <<>>});
valid_name(Bin) ->
    valid_name_chars(Bin, Bin).

-spec valid_name_chars(binary(), binary()) -> ok.
valid_name_chars(<<>>, _Orig) ->
    ok;
valid_name_chars(<<C, R/binary>>, Orig) when C >= $a, C =< $z ->
    valid_name_chars(R, Orig);
valid_name_chars(<<C, R/binary>>, Orig) when C >= $A, C =< $Z ->
    valid_name_chars(R, Orig);
valid_name_chars(<<C, R/binary>>, Orig) when C >= $0, C =< $9 ->
    valid_name_chars(R, Orig);
valid_name_chars(<<C, R/binary>>, Orig) when
    %% Token punctuation (RFC 7230 §3.2.6): `!#$%&'*+-.^_`|~`
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
    valid_name_chars(R, Orig);
valid_name_chars(<<_, _/binary>>, Orig) ->
    error({invalid_cookie_name, Orig}).

%% RFC 6265 §4.1.1: cookie-octet = %x21 / %x23-2B / %x2D-3A / %x3C-5B /
%% %x5D-7E. Excludes CTL (0-31, 127), SP (32), DQUOTE (34), `,` (44),
%% `;` (59), `\` (92). Empty value is allowed (cookie-value = *cookie-octet).
-spec valid_value(binary(), binary()) -> ok.
valid_value(<<>>, _Orig) ->
    ok;
valid_value(<<C, R/binary>>, Orig) when
    C > 32, C < 127, C =/= $", C =/= $,, C =/= $;, C =/= $\\
->
    valid_value(R, Orig);
valid_value(<<_, _/binary>>, Orig) ->
    error({invalid_cookie_value, Orig}).

%% RFC 6265 §5.1.3 — domain-value is a `<subdomain>` per RFC 1034
%% §3.5. For header-injection defence we reject CTLs, SP, and `;`;
%% strict hostname-grammar enforcement is deferred (see
%% `docs/roadmap.md`).
-spec valid_attr_domain(binary(), binary()) -> ok.
valid_attr_domain(<<>>, _Orig) ->
    ok;
valid_attr_domain(<<C, R/binary>>, Orig) when C > 32, C < 127, C =/= $; ->
    valid_attr_domain(R, Orig);
valid_attr_domain(<<_, _/binary>>, Orig) ->
    error({invalid_cookie_attr, domain, Orig}).

%% RFC 6265 §4.1.1: path-value = <any CHAR except CTLs or ";">.
-spec valid_attr_path(binary(), binary()) -> ok.
valid_attr_path(<<>>, _Orig) ->
    ok;
valid_attr_path(<<C, R/binary>>, Orig) when C > 31, C =/= 127, C =/= $; ->
    valid_attr_path(R, Orig);
valid_attr_path(<<_, _/binary>>, Orig) ->
    error({invalid_cookie_attr, path, Orig}).

%% RFC 6265 §5.1.1 expects an IMF-fixdate; we only enforce header-injection
%% safety (no CR/LF/NUL/`;`) and leave date-grammar validation to the caller.
-spec valid_attr_expires(binary(), binary()) -> ok.
valid_attr_expires(<<>>, _Orig) ->
    ok;
valid_attr_expires(<<C, R/binary>>, Orig) when
    C =/= $\r, C =/= $\n, C =/= 0, C =/= $;
->
    valid_attr_expires(R, Orig);
valid_attr_expires(<<_, _/binary>>, Orig) ->
    error({invalid_cookie_attr, expires, Orig}).

%% `-on_load` callback. See `feedback_compile_pattern_convention` —
%% binary:match/split patterns belong in `persistent_term` so the
%% per-cookie hot path doesn't recompile on every call.
-spec init_patterns() -> ok.
init_patterns() ->
    persistent_term:put(?SEMI_CP_KEY, binary:compile_pattern(~";")),
    persistent_term:put(?EQ_CP_KEY, binary:compile_pattern(~"=")),
    ok.
