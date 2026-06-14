-module(roadrunner_security_headers).
-moduledoc """
Security-headers middleware: a default-safe set of response headers, the
same handful every browser-facing service hand-rolls, added to every HTTP
response and leaving any header the handler already set untouched.

Wire it into a listener's (or route's) `middlewares` opt, bare for the
defaults or `{roadrunner_security_headers, Config}` to tune them:

```erlang
roadrunner_listener:start_link(my_app, #{
    port => 8080,
    routes => Routes,
    middlewares => [roadrunner_security_headers]
}).
```

## Default set

| Header | Default value | Config key |
|--------|---------------|------------|
| `x-content-type-options` | `nosniff` | `content_type_options` |
| `x-frame-options` | `SAMEORIGIN` | `frame_options` |
| `referrer-policy` | `strict-origin-when-cross-origin` | `referrer_policy` |

Each key takes a binary to override the value, or `false` to drop the header.

## Opt-in headers

Two headers carry consequences beyond the current response, so they stay off
until enabled explicitly:

- **`content-security-policy`** (`content_security_policy => <<"...">>`): a
  default policy is too application-specific to be safe.
- **`strict-transport-security`** (`hsts => true | Config`): once a browser
  sees HSTS it refuses plain HTTP to the host for the whole `max-age`, even
  after the header stops, and `include_subdomains` extends that to every
  subdomain, so a wrong value is a durable outage rather than a one-response
  mistake. It is emitted only over HTTPS (per `roadrunner_req:scheme/1`); a
  browser ignores HSTS received over plain HTTP (RFC 6797 §8.1).

`hsts => true` emits the recommended `max-age=31536000; includeSubDomains`.
`hsts => Config` tunes it:

- `max_age => non_neg_integer()` (default 31536000, one year)
- `include_subdomains => boolean()` (default `true`)
- `preload => boolean()` (default `false`): opt-in, it commits the host to
  the browser preload lists, which is slow to reverse

## Precedence and scope

A header the handler already set wins: each default is added only when
absent. Unlike `roadrunner_compress`, this middleware adds no `Vary` (its
output conditions on no request header; HSTS keys off the connection scheme,
not a header). It decorates every response shape that carries headers
(buffered, stream, sendfile, and loop), so a file served via `sendfile` gets
`nosniff` too; only a `{websocket, _, _}` upgrade, which has no response
headers, passes through.
""".

-behaviour(roadrunner_middleware).

-export([init/1, call/3]).

-type config() :: #{
    content_type_options => binary() | false,
    frame_options => binary() | false,
    referrer_policy => binary() | false,
    hsts => boolean() | hsts_config(),
    content_security_policy => binary() | false
}.
-type hsts_config() :: #{
    max_age => non_neg_integer(),
    include_subdomains => boolean(),
    preload => boolean()
}.

-export_type([config/0, state/0]).

%% The compiled header set `init/1` produces: `static` is the pre-built,
%% false-filtered list of the scheme-independent defaults, prepended onto the
%% handler's headers as-is per request. `hsts` is the pre-built
%% `strict-transport-security` value (or `false` when off); it still emits only
%% over HTTPS, gated per request on the scheme.
-record(sec, {
    static :: roadrunner_http:headers(),
    hsts :: binary() | false
}).

-doc "The compiled header set produced by `init/1` and consumed by `call/3`.".
-type state() :: #sec{}.

%% Resolve every default and the HSTS value once, at pipeline-compile time, and
%% pre-build the scheme-independent set so a request only prepends HSTS.
-spec init(config()) -> state().
init(Config) ->
    Static = roadrunner_http:drop_unset([
        {~"x-content-type-options", opt(content_type_options, Config, ~"nosniff")},
        {~"x-frame-options", opt(frame_options, Config, ~"SAMEORIGIN")},
        {~"referrer-policy", opt(referrer_policy, Config, ~"strict-origin-when-cross-origin")},
        {~"content-security-policy", opt(content_security_policy, Config, false)}
    ]),
    #sec{static = Static, hsts = compile_hsts(Config)}.

%% Pre-build the `strict-transport-security` value (or `false` when off). It is
%% still emitted only over HTTPS — see `hsts_candidates/3`.
-spec compile_hsts(config()) -> binary() | false.
compile_hsts(Config) ->
    case opt(hsts, Config, false) of
        false -> false;
        true -> hsts_value(#{});
        HstsConfig when is_map(HstsConfig) -> hsts_value(HstsConfig)
    end.

-spec call(roadrunner_req:request(), roadrunner_middleware:next(), state()) ->
    roadrunner_handler:result().
call(Req, Next, #sec{} = State) ->
    {Response, Req2} = Next(Req),
    {transform(Req, State, Response), Req2}.

%% Decorate every header-bearing response shape; pass a `{websocket, _, _}`
%% upgrade (no response headers) through. The `is_integer(Status)` guard on
%% the buffered clause is load-bearing: it rejects the `{websocket, Mod, State}`
%% triple, which shares the 3-tuple shape but carries an atom where the status
%% would be.
-spec transform(roadrunner_req:request(), state(), roadrunner_handler:response()) ->
    roadrunner_handler:response().
transform(Req, State, {Status, Headers, Body}) when
    is_integer(Status), Status >= 100, Status =< 599
->
    {Status, inject(Req, State, Headers), Body};
transform(Req, State, {stream, Status, Headers, Fun}) when
    is_integer(Status), Status >= 100, Status =< 599, is_function(Fun, 1)
->
    {stream, Status, inject(Req, State, Headers), Fun};
transform(Req, State, {sendfile, Status, Headers, Spec}) when
    is_integer(Status), Status >= 100, Status =< 599
->
    {sendfile, Status, inject(Req, State, Headers), Spec};
transform(Req, State, {loop, Status, Headers, LoopState}) when
    is_integer(Status), Status >= 100, Status =< 599
->
    {loop, Status, inject(Req, State, Headers), LoopState};
transform(_Req, _State, Other) ->
    Other.

%% Prepend HSTS (over HTTPS, when configured) onto the pre-built static set,
%% then prepend the lot onto the handler's headers, skipping any the handler
%% already set.
-spec inject(roadrunner_req:request(), state(), roadrunner_http:headers()) ->
    roadrunner_http:headers().
inject(Req, #sec{static = Static} = State, Headers) ->
    roadrunner_http:with_defaults(
        Headers, hsts_candidates(roadrunner_req:scheme(Req), State, Static)
    ).

%% HSTS is meaningful only over HTTPS (RFC 6797 §8.1: a browser ignores it on a
%% plain-HTTP response) and only when configured; the value itself was pre-built
%% by `compile_hsts/1`. On plain HTTP, or when off, nothing is added.
-spec hsts_candidates(http | https, state(), roadrunner_http:headers()) ->
    roadrunner_http:headers().
hsts_candidates(https, #sec{hsts = Hsts}, Static) when is_binary(Hsts) ->
    [{~"strict-transport-security", Hsts} | Static];
hsts_candidates(_Scheme, _State, Static) ->
    Static.

%% Build `max-age=N[; includeSubDomains][; preload]` from the HSTS sub-config.
-spec hsts_value(hsts_config()) -> binary().
hsts_value(Config) ->
    MaxAge = integer_to_binary(opt(max_age, Config, 31536000)),
    Base = <<"max-age=", MaxAge/binary>>,
    WithSubdomains =
        case opt(include_subdomains, Config, true) of
            true -> <<Base/binary, "; includeSubDomains">>;
            false -> Base
        end,
    case opt(preload, Config, false) of
        true -> <<WithSubdomains/binary, "; preload">>;
        false -> WithSubdomains
    end.

%% A config value: the override, or `Default` when the key is unset. A map
%% pattern (not `maps:get`) so a present-but-`false` value still reads through.
-spec opt(atom(), map(), term()) -> term().
opt(Key, Config, Default) ->
    case Config of
        #{Key := Value} -> Value;
        #{} -> Default
    end.
