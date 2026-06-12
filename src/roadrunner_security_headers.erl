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

-export([call/3]).

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

-spec call(roadrunner_req:request(), roadrunner_middleware:next(), roadrunner_middleware:state()) ->
    roadrunner_handler:result().
call(Req, Next, State) ->
    {Response, Req2} = Next(Req),
    {transform(Req, config(State), Response), Req2}.

%% A bare-callable entry hands `undefined` as the state, meaning "all defaults".
-spec config(roadrunner_middleware:state()) -> config().
config(undefined) -> #{};
config(Config) when is_map(Config) -> Config.

%% Decorate every header-bearing response shape; pass a `{websocket, _, _}`
%% upgrade (no response headers) through. The `is_integer(Status)` guard on
%% the buffered clause is load-bearing: it rejects the `{websocket, Mod, State}`
%% triple, which shares the 3-tuple shape but carries an atom where the status
%% would be.
-spec transform(roadrunner_req:request(), config(), roadrunner_handler:response()) ->
    roadrunner_handler:response().
transform(Req, Config, {Status, Headers, Body}) when
    is_integer(Status), Status >= 100, Status =< 599
->
    {Status, inject(Req, Config, Headers), Body};
transform(Req, Config, {stream, Status, Headers, Fun}) when
    is_integer(Status), Status >= 100, Status =< 599, is_function(Fun, 1)
->
    {stream, Status, inject(Req, Config, Headers), Fun};
transform(Req, Config, {sendfile, Status, Headers, Spec}) when
    is_integer(Status), Status >= 100, Status =< 599
->
    {sendfile, Status, inject(Req, Config, Headers), Spec};
transform(Req, Config, {loop, Status, Headers, LoopState}) when
    is_integer(Status), Status >= 100, Status =< 599
->
    {loop, Status, inject(Req, Config, Headers), LoopState};
transform(_Req, _Config, Other) ->
    Other.

%% Prepend each enabled default the handler didn't already set. The full set
%% is built once in emit order; `add_defaults/2` skips any whose value resolved
%% to `false` (disabled by config, or HSTS off / over plain HTTP).
-spec inject(roadrunner_req:request(), config(), roadrunner_http:headers()) ->
    roadrunner_http:headers().
inject(Req, Config, Headers) ->
    Scheme = roadrunner_req:scheme(Req),
    add_defaults(
        [
            {~"x-content-type-options", opt(content_type_options, Config, ~"nosniff")},
            {~"x-frame-options", opt(frame_options, Config, ~"SAMEORIGIN")},
            {~"referrer-policy", opt(referrer_policy, Config, ~"strict-origin-when-cross-origin")},
            {~"strict-transport-security", hsts(Scheme, Config)},
            {~"content-security-policy", opt(content_security_policy, Config, false)}
        ],
        Headers
    ).

-spec add_defaults([{binary(), binary() | false}], roadrunner_http:headers()) ->
    roadrunner_http:headers().
add_defaults([], Headers) ->
    Headers;
add_defaults([{_Name, false} | Rest], Headers) ->
    add_defaults(Rest, Headers);
add_defaults([{Name, Value} | Rest], Headers) ->
    case has_header(Name, Headers) of
        true -> add_defaults(Rest, Headers);
        false -> [{Name, Value} | add_defaults(Rest, Headers)]
    end.

%% `strict-transport-security` is opt-in (its commitment outlives the header,
%% see the moduledoc) and meaningful only over HTTPS (RFC 6797 §8.1: a browser
%% ignores it on a plain-HTTP response), so it resolves to `false` (skipped)
%% on a plain-HTTP connection, when unset, or when `hsts => false`. `true`
%% emits the recommended settings; a map tunes them.
-spec hsts(http | https, config()) -> binary() | false.
hsts(https, Config) ->
    case opt(hsts, Config, false) of
        false -> false;
        true -> hsts_value(#{});
        HstsConfig when is_map(HstsConfig) -> hsts_value(HstsConfig)
    end;
hsts(http, _Config) ->
    false.

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

-spec has_header(binary(), roadrunner_http:headers()) -> boolean().
has_header(Name, Headers) ->
    lists:keymember(Name, 1, Headers).
