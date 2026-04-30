-module(cactus_router).
-moduledoc """
Path → handler dispatch with parameterized segments.

Routes are written as `/users/:id/posts/:post_id`. Segments starting
with `:` capture into bindings keyed by the **binary** name that
follows the colon — we deliberately avoid `binary_to_atom/1` on the
parsed name to keep the "everything is binary on the wire" rule we
already use for header names. Literal segments must match byte-exactly;
comparison is case-sensitive per RFC 3986.

Routes are tried in declaration order — earlier entries win. The
opaque `compiled()` shape is a list of pre-parsed segment patterns;
swapping to a trie/DAG later is a non-breaking change for callers.
""".

-export([compile/1, match/2]).

-export_type([route/0, routes/0, compiled/0, bindings/0]).

-type route() :: {Path :: binary(), Handler :: module()}.
-type routes() :: [route()].
-type bindings() :: #{binary() => binary()}.

-type segment() :: {literal, binary()} | {param, binary()}.
-opaque compiled() :: [{[segment()], module()}].

-doc """
Compile a list of routes into the lookup form `match/2` expects.

Each path is split on `/` (empty leading/trailing segments dropped),
and segments starting with `:` are recorded as named captures.
""".
-spec compile(routes()) -> compiled().
compile(Routes) when is_list(Routes) ->
    [{compile_path(Path), Handler} || {Path, Handler} <- Routes].

-spec compile_path(binary()) -> [segment()].
compile_path(Path) ->
    [compile_segment(S) || S <- path_segments(Path)].

-spec compile_segment(binary()) -> segment().
compile_segment(<<":", Name/binary>>) -> {param, Name};
compile_segment(Lit) -> {literal, Lit}.

-doc """
Look up the handler for a given request path.

Returns `{ok, Handler, Bindings}` on a match — `Bindings` is a map
populated with captures from `:param` segments (empty for purely
literal routes). Returns `not_found` when no compiled route matches.
""".
-spec match(Path :: binary(), compiled()) ->
    {ok, module(), bindings()} | not_found.
match(Path, Compiled) when is_binary(Path), is_list(Compiled) ->
    Segments = path_segments(Path),
    match_first(Segments, Compiled).

-spec match_first([binary()], compiled()) -> {ok, module(), bindings()} | not_found.
match_first(_Segments, []) ->
    not_found;
match_first(Segments, [{Pattern, Handler} | Rest]) ->
    case match_pattern(Pattern, Segments, #{}) of
        {ok, Bindings} -> {ok, Handler, Bindings};
        no_match -> match_first(Segments, Rest)
    end.

-spec match_pattern([segment()], [binary()], bindings()) ->
    {ok, bindings()} | no_match.
match_pattern([], [], Bindings) ->
    {ok, Bindings};
match_pattern([{literal, S} | P], [S | Segs], Bindings) ->
    match_pattern(P, Segs, Bindings);
match_pattern([{param, Name} | P], [Value | Segs], Bindings) ->
    match_pattern(P, Segs, Bindings#{Name => Value});
match_pattern(_, _, _) ->
    no_match.

-spec path_segments(binary()) -> [binary()].
path_segments(Path) ->
    binary:split(Path, ~"/", [global, trim_all]).
