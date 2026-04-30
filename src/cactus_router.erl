-module(cactus_router).
-moduledoc """
Path → handler dispatch.

Currently supports **literal-path matching only** — `/users` matches
`/users` exactly. Parameterized paths (`/users/:id`), wildcards (`*`),
and host-based routing arrive in later features.

`compile/1` turns a list of `{Path, Handler}` pairs into an opaque
form optimized for `match/2` lookup. Today that's just a map; the
opaque type lets us swap in a trie or DAG later without changing
callers.
""".

-export([compile/1, match/2]).

-export_type([route/0, routes/0, compiled/0]).

-type route() :: {Path :: binary(), Handler :: module()}.
-type routes() :: [route()].
-opaque compiled() :: #{binary() => module()}.

-doc """
Compile a list of routes into the lookup form `match/2` expects.

If two routes share the same path, the **last** one wins (later
entries override earlier ones — `maps:from_list/1` semantics).
""".
-spec compile(routes()) -> compiled().
compile(Routes) when is_list(Routes) ->
    maps:from_list(Routes).

-doc """
Look up the handler module for a given request path. Returns `not_found`
when no route matches.

Path comparison is byte-exact and case-sensitive per RFC 3986.
""".
-spec match(Path :: binary(), compiled()) -> {ok, module()} | not_found.
match(Path, Compiled) when is_binary(Path), is_map(Compiled) ->
    case maps:find(Path, Compiled) of
        {ok, Handler} -> {ok, Handler};
        error -> not_found
    end.
