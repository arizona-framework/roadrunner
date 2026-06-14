-module(roadrunner_test_middlewares).
-moduledoc """
Test fixtures for the middleware feature.

`tag_request/3` and `wrap_response/3` are fun-form middlewares — they
demonstrate request-side and response-side composition. `halt_401/3`
short-circuits without calling `Next`. `crash/3` exists to exercise the
conn's crash-to-500 path. `call/3` is the module-form callback required
by the `roadrunner_middleware` behaviour.

Every entry takes the uniform `(Req, Next, State)` shape. The fun-form
helpers ignore `State`; `call/3` stamps it into the request so tests can
verify both behaviour dispatch and per-entry state threading. This module
has **no** `init/1`, so it exercises the optional-init path: the entry's
config reaches `call/3` verbatim.
""".

-behaviour(roadrunner_middleware).

-export([
    call/3,
    tag_request/3,
    wrap_response/3,
    halt_401/3,
    crash/3
]).

%% Module-form `call/3` callback. Stamps this entry's `State` as the
%% `x-mw-mod` request header, so tests can assert the state threaded
%% through behaviour dispatch (and, with the same module listed twice,
%% that each entry carries its own state).
call(Req, Next, State) ->
    H = maps:get(headers, Req),
    Next(Req#{headers := [{~"x-mw-mod", State} | H]}).

%% Fun-form: add a header to the request map; handler/next sees it.
tag_request(Req, Next, _State) ->
    H = maps:get(headers, Req),
    Next(Req#{headers := [{~"x-mw-fun", ~"yes"} | H]}).

%% Fun-form: call Next, then wrap the response. Demonstrates that the
%% middleware sees the handler's output, which simple cowboy-style
%% middlewares could not.
wrap_response(Req, Next, _State) ->
    {{Status, Headers, Body}, Req2} = Next(Req),
    Wrapped = iolist_to_binary([~"[wrapped] ", Body]),
    {{Status, [{~"x-wrapped", ~"yes"} | Headers], Wrapped}, Req2}.

%% Fun-form: short-circuit without calling Next.
halt_401(Req, _Next, _State) ->
    {{401, [{~"content-length", ~"0"}], ~""}, Req}.

%% Fun-form: crash deliberately to exercise the 500 path.
crash(_Req, _Next, _State) ->
    error(boom).
