-module(roadrunner_cookie).
-moduledoc """
HTTP cookie codec (RFC 6265).

Currently provides `parse/1` for the request-side `Cookie` header.
The response-side `Set-Cookie` builder will arrive in a later feature.
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
            case trim_ows(RawName) of
                <<>> ->
                    parse_pairs(Rest, EqCp);
                Name ->
                    [{Name, trim_ows(RawValue)} | parse_pairs(Rest, EqCp)]
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
`strict`, `lax`, or `none`. Caller is responsible for any encoding
or quoting of `Value`.
""".
-spec serialize(Name :: binary(), Value :: binary(), serialize_opts()) -> iodata().
serialize(Name, Value, Opts) when is_binary(Name), is_binary(Value), is_map(Opts) ->
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
attr_domain(#{domain := D}) -> [~"; Domain=", D];
attr_domain(_) -> [].

-spec attr_path(serialize_opts()) -> iodata().
attr_path(#{path := P}) -> [~"; Path=", P];
attr_path(_) -> [].

-spec attr_max_age(serialize_opts()) -> iodata().
attr_max_age(#{max_age := N}) when is_integer(N), N >= 0 ->
    [~"; Max-Age=", integer_to_binary(N)];
attr_max_age(_) ->
    [].

-spec attr_expires(serialize_opts()) -> iodata().
attr_expires(#{expires := E}) -> [~"; Expires=", E];
attr_expires(_) -> [].

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

%% Duplicated from roadrunner_http1 — both modules need OWS trimming. Extract
%% to a util module if a third caller appears.
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

%% `-on_load` callback. See `feedback_compile_pattern_convention` —
%% binary:match/split patterns belong in `persistent_term` so the
%% per-cookie hot path doesn't recompile on every call.
-spec init_patterns() -> ok.
init_patterns() ->
    persistent_term:put(?SEMI_CP_KEY, binary:compile_pattern(~";")),
    persistent_term:put(?EQ_CP_KEY, binary:compile_pattern(~"=")),
    ok.
