-module(cactus_test_middlewares).
-moduledoc """
Test fixtures for the middleware feature.

`tag_request/2` and `wrap_response/2` are fun-form middlewares — they
demonstrate request-side and response-side composition. `halt_401/2`
short-circuits without calling `Next`. `crash/2` exists to exercise
the conn's crash-to-500 path. `call/2` is the module-form callback
required by the `cactus_middleware` behaviour, used to verify that
atom-form entries in the chain dispatch through the behaviour.
""".

-behaviour(cactus_middleware).

-export([
    call/2,
    tag_request/2,
    wrap_response/2,
    halt_401/2,
    crash/2
]).

%% Module-form middleware — required `call/2` callback from the
%% behaviour. Stamps a header into the request before continuing.
call(Req, Next) ->
    H = maps:get(headers, Req),
    Next(Req#{headers := [{~"x-mw-mod", ~"yes"} | H]}).

%% Fun-form: add a header to the request map; handler/next sees it.
tag_request(Req, Next) ->
    H = maps:get(headers, Req),
    Next(Req#{headers := [{~"x-mw-fun", ~"yes"} | H]}).

%% Fun-form: call Next, then wrap the response. Demonstrates that the
%% middleware sees the handler's output, which simple cowboy-style
%% middlewares could not.
wrap_response(Req, Next) ->
    {{Status, Headers, Body}, Req2} = Next(Req),
    Wrapped = iolist_to_binary([~"[wrapped] ", Body]),
    {{Status, [{~"x-wrapped", ~"yes"} | Headers], Wrapped}, Req2}.

%% Fun-form: short-circuit without calling Next.
halt_401(Req, _Next) ->
    {{401, [{~"content-length", ~"0"}], ~""}, Req}.

%% Fun-form: crash deliberately to exercise the 500 path.
crash(_Req, _Next) ->
    error(boom).
