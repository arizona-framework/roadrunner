-module(cactus_router_props).
-moduledoc """
Property-based tests for `cactus_router`.

Headline property: **parameter bindings round-trip.** Given a
randomly-generated route pattern (a mix of literal and `:param`
segments) and randomly-generated values for each `:param`, the
constructed path must match the route and `cactus_router:match/2`
must reproduce the param map verbatim.

This catches off-by-one bugs in segment parsing, encoding mismatches,
and any future regression that decodes `:param` captures (we want raw
binary segments preserved).
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

%% A route shape: list of `{literal, Bin}` or `{param, Name}` segments.
prop_param_bindings_round_trip() ->
    ?FORALL(
        {Pattern, Values},
        pattern_with_values(),
        begin
            PathBin = build_path(Pattern, Values),
            RouteBin = build_route(Pattern),
            Compiled = cactus_router:compile([{RouteBin, my_handler, undefined}]),
            case cactus_router:match(PathBin, Compiled) of
                {ok, my_handler, Bindings, undefined} ->
                    %% Every `:Name` in the pattern must show up in
                    %% Bindings under that exact binary name and value.
                    Expected = expected_bindings(Pattern, Values),
                    Bindings =:= Expected;
                not_found ->
                    %% Empty path / empty literal segments collapse to
                    %% the same as `/`. Tolerate by short-circuiting on
                    %% the degenerate input.
                    Pattern =:= []
            end
        end
    ).

%% Generator: a pattern + a value for each param segment.
pattern_with_values() ->
    ?LET(Pattern, pattern(), {Pattern, params_values(Pattern)}).

pattern() ->
    non_empty(list(segment_def())).

segment_def() ->
    oneof([
        {literal, segment_token()},
        {param, segment_token()}
    ]).

%% Segment tokens kept simple — letters and digits, no `/`, no `:`,
%% and not empty. Avoids percent-encoding interference.
segment_token() ->
    ?LET(
        Bin,
        non_empty(list(oneof([range($a, $z), range($A, $Z), range($0, $9)]))),
        list_to_binary(Bin)
    ).

params_values(Pattern) ->
    [
        {Name, segment_token()}
     || {param, Name} <- Pattern
    ].

build_path(Pattern, Values) ->
    Segs = [path_seg(S, Values) || S <- Pattern],
    iolist_to_binary([<<"/">>, lists:join(<<"/">>, Segs)]).

path_seg({literal, L}, _) ->
    L;
path_seg({param, Name}, Values) ->
    proplists:get_value(Name, Values).

build_route(Pattern) ->
    Segs = [route_seg(S) || S <- Pattern],
    iolist_to_binary([<<"/">>, lists:join(<<"/">>, Segs)]).

route_seg({literal, L}) ->
    L;
route_seg({param, Name}) ->
    <<":", Name/binary>>.

expected_bindings(Pattern, Values) ->
    maps:from_list([
        {Name, proplists:get_value(Name, Values)}
     || {param, Name} <- Pattern
    ]).
