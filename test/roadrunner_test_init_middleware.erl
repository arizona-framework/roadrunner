-module(roadrunner_test_init_middleware).
-moduledoc """
Test fixture proving the `init/1` compile-time contract.

`init/1` compiles its raw config into a `{compiled, Tag}` state — a shape
distinct from the input — so a test can assert `call/3` sees init's
**output**, not the raw config. When the config carries a `counter`,
`init/1` bumps it once, letting a test assert init ran a single time at
compile, never per request.
""".

-behaviour(roadrunner_middleware).

-export([init/1, call/3]).

%% Runs once when the pipeline is compiled. Bumps the caller's counter
%% (when one is configured) so a test can prove it fires exactly once, and
%% compiles the raw `tag` into a `{compiled, Tag}` state distinct from the
%% input config.
init(Config) ->
    case Config of
        #{counter := Ref} -> ok = counters:add(Ref, 1, 1);
        #{} -> ok
    end,
    Tag =
        case Config of
            #{tag := T} -> T;
            #{} -> ~"default"
        end,
    {compiled, Tag}.

%% Stamps the COMPILED tag as a request header. Reading it back proves
%% init's output (not the raw config map) threaded through to `call/3`.
call(Req, Next, {compiled, Tag}) ->
    H = maps:get(headers, Req),
    Next(Req#{headers := [{~"x-init-tag", Tag} | H]}).
