-module(roadrunner_cors).
-moduledoc """
Cross-Origin Resource Sharing (CORS) middleware.

Answers the browser's preflight `OPTIONS` request and decorates cross-origin
responses with the right `Access-Control-*` headers, driven by a per-instance
policy. Deny-by-default: a request whose `Origin` is not allowed gets no
`Access-Control-Allow-Origin`, so the browser blocks it.

Wire it with its config (there is no useful bare form, `origins` is required):

```erlang
middlewares => [
    {roadrunner_cors, #{
        origins => [~"https://app.example.com"],
        methods => [~"GET", ~"POST"],
        credentials => true
    }}
]
```

## Config

| Key | Default | Meaning |
|-----|---------|---------|
| `origins` | (required) | `[binary()]` allowlist, `fun((binary()) -> boolean())` predicate, or `any` |
| `methods` | `[~"GET", ~"HEAD", ~"POST"]` | methods echoed in a preflight's `Access-Control-Allow-Methods` |
| `headers` | `[]` | `[binary()]` echoed in `Access-Control-Allow-Headers`, or `reflect` to mirror the request's `Access-Control-Request-Headers` |
| `expose` | `[]` | `[binary()]` for `Access-Control-Expose-Headers` |
| `credentials` | `false` | when `true`, emit `Access-Control-Allow-Credentials: true` |
| `max_age` | (omitted) | preflight cache lifetime in seconds (`Access-Control-Max-Age`) |

A bad value crashes the request with `{invalid_cors_opt, Key, Value}` rather
than failing silently.

## Behaviour

- **No `Origin` header**: not a CORS request, passed through untouched.
- **Preflight** (`OPTIONS` with `Access-Control-Request-Method`): short-circuited
  with a `204` carrying the `Access-Control-*` set, without calling the handler.
- **Simple / actual request**: the handler runs, then `Access-Control-Allow-Origin`
  (plus credentials / exposed headers when configured) is added to its response.

`Vary: Origin` is added to every CORS response, allowed or not, so a shared
cache never serves one origin's response to another; an existing `Vary` (e.g.
`Accept-Encoding` from `roadrunner_compress`) is appended to rather than
replaced.

## Credentials and the wildcard

With `credentials => true` the response echoes the concrete request `Origin`
rather than `*`, because a browser rejects `Access-Control-Allow-Origin: *`
together with `Access-Control-Allow-Credentials: true`. `origins => any`
without credentials emits the literal `*`.
""".

-behaviour(roadrunner_middleware).

-export([call/3]).

-type origins() :: any | [binary()] | fun((binary()) -> boolean()).
-type config() :: #{
    origins := origins(),
    methods => [binary()],
    headers => [binary()] | reflect,
    expose => [binary()],
    credentials => boolean(),
    max_age => non_neg_integer()
}.

-spec call(roadrunner_req:request(), roadrunner_middleware:next(), roadrunner_middleware:state()) ->
    roadrunner_handler:result().
call(Req, Next, Config) ->
    case roadrunner_req:header(~"origin", Req) of
        undefined ->
            %% Not a CORS request — nothing to do.
            Next(Req);
        Origin ->
            case is_preflight(Req) of
                true ->
                    %% Preflight: answer 204 ourselves, never reaching the handler.
                    {preflight_response(Config, Origin, Req), Req};
                false ->
                    {Response, Req2} = Next(Req),
                    {add_actual_headers(Response, Config, Origin), Req2}
            end
    end.

%% A preflight is an `OPTIONS` carrying `Access-Control-Request-Method`. The
%% header lookup is inlined so it only runs once the method check passes.
-spec is_preflight(roadrunner_req:request()) -> boolean().
is_preflight(Req) ->
    roadrunner_req:method(Req) =:= ~"OPTIONS" andalso
        roadrunner_req:header(~"access-control-request-method", Req) =/= undefined.

%% =============================================================================
%% Preflight (204)
%% =============================================================================

-spec preflight_response(config(), binary(), roadrunner_req:request()) ->
    roadrunner_handler:response().
preflight_response(Config, Origin, Req) ->
    %% Vary: Origin even on a disallowed preflight, so a cache keys correctly.
    Base = add_vary_origin([]),
    Origins = origins(Config),
    case allowed(Origin, Origins) of
        false ->
            {204, Base, ~""};
        true ->
            Creds = credentials(Config),
            ok = roadrunner_http:check_header_safe(Origin, value),
            Headers = add_cors(
                [
                    {~"access-control-allow-origin", allow_origin_value(Origin, Origins, Creds)},
                    {~"access-control-allow-methods", join(methods(Config))},
                    {~"access-control-allow-headers", allow_headers_value(Config, Req)},
                    {~"access-control-allow-credentials", credentials_value(Creds)},
                    {~"access-control-max-age", max_age_value(Config)}
                ],
                Base
            ),
            {204, Headers, ~""}
    end.

%% The `Access-Control-Allow-Headers` value: mirror the request's requested
%% headers (`reflect`), join a configured list, or omit when neither applies.
-spec allow_headers_value(config(), roadrunner_req:request()) -> binary() | false.
allow_headers_value(Config, Req) ->
    case headers(Config) of
        reflect ->
            case roadrunner_req:header(~"access-control-request-headers", Req) of
                undefined ->
                    false;
                Requested ->
                    ok = roadrunner_http:check_header_safe(Requested, value),
                    Requested
            end;
        [] ->
            false;
        List ->
            join(List)
    end.

-spec max_age_value(config()) -> binary() | false.
max_age_value(Config) ->
    case max_age(Config) of
        undefined -> false;
        Seconds -> integer_to_binary(Seconds)
    end.

%% =============================================================================
%% Simple / actual request
%% =============================================================================

%% Decorate every header-bearing response shape; a `{websocket, _, _}` upgrade
%% (no response headers) passes through. The `is_integer(Status)` guard on the
%% buffered clause keeps the websocket triple out of it.
-spec add_actual_headers(roadrunner_handler:response(), config(), binary()) ->
    roadrunner_handler:response().
add_actual_headers({Status, Headers, Body}, Config, Origin) when
    is_integer(Status), Status >= 100, Status =< 599
->
    {Status, actual_headers(Headers, Config, Origin), Body};
add_actual_headers({stream, Status, Headers, Fun}, Config, Origin) when
    is_integer(Status), Status >= 100, Status =< 599, is_function(Fun, 1)
->
    {stream, Status, actual_headers(Headers, Config, Origin), Fun};
add_actual_headers({sendfile, Status, Headers, Spec}, Config, Origin) when
    is_integer(Status), Status >= 100, Status =< 599
->
    {sendfile, Status, actual_headers(Headers, Config, Origin), Spec};
add_actual_headers({loop, Status, Headers, LoopState}, Config, Origin) when
    is_integer(Status), Status >= 100, Status =< 599
->
    {loop, Status, actual_headers(Headers, Config, Origin), LoopState};
add_actual_headers(Other, _Config, _Origin) ->
    Other.

-spec actual_headers(roadrunner_http:headers(), config(), binary()) ->
    roadrunner_http:headers().
actual_headers(Headers, Config, Origin) ->
    WithVary = add_vary_origin(Headers),
    Origins = origins(Config),
    case allowed(Origin, Origins) of
        false ->
            %% Disallowed: only Vary: Origin, no Access-Control-Allow-Origin.
            WithVary;
        true ->
            Creds = credentials(Config),
            ok = roadrunner_http:check_header_safe(Origin, value),
            add_cors(
                [
                    {~"access-control-allow-origin", allow_origin_value(Origin, Origins, Creds)},
                    {~"access-control-allow-credentials", credentials_value(Creds)},
                    {~"access-control-expose-headers", expose_value(Config)}
                ],
                WithVary
            )
    end.

-spec expose_value(config()) -> binary() | false.
expose_value(Config) ->
    case expose(Config) of
        [] -> false;
        List -> join(List)
    end.

%% =============================================================================
%% Shared header building
%% =============================================================================

%% Whether the request `Origin` is allowed by the policy.
-spec allowed(binary(), origins()) -> boolean().
allowed(_Origin, any) -> true;
allowed(Origin, List) when is_list(List) -> lists:member(Origin, List);
allowed(Origin, Fun) when is_function(Fun, 1) -> Fun(Origin) =:= true.

%% The `Access-Control-Allow-Origin` value: the literal `*` only for the public
%% `origins => any` case without credentials; otherwise the concrete origin (a
%% browser rejects `*` with credentials, and an allowlist always echoes).
-spec allow_origin_value(binary(), origins(), boolean()) -> binary().
allow_origin_value(_Origin, any, false) -> ~"*";
allow_origin_value(Origin, _Origins, _Creds) -> Origin.

-spec credentials_value(boolean()) -> binary() | false.
credentials_value(true) -> ~"true";
credentials_value(false) -> false.

%% Add `Vary: Origin`, appending to an existing `Vary` rather than replacing it
%% (e.g. `Accept-Encoding` set by `roadrunner_compress`).
-spec add_vary_origin(roadrunner_http:headers()) -> roadrunner_http:headers().
add_vary_origin(Headers) ->
    case lists:keyfind(~"vary", 1, Headers) of
        false ->
            [{~"vary", ~"Origin"} | Headers];
        {_, Existing} ->
            lists:keystore(~"vary", 1, Headers, {~"vary", <<Existing/binary, ", Origin">>})
    end.

%% Prepend each candidate the handler didn't already set, skipping any whose
%% value resolved to `false` (the header doesn't apply under this policy).
-spec add_cors([{binary(), binary() | false}], roadrunner_http:headers()) ->
    roadrunner_http:headers().
add_cors([], Headers) ->
    Headers;
add_cors([{_Name, false} | Rest], Headers) ->
    add_cors(Rest, Headers);
add_cors([{Name, Value} | Rest], Headers) ->
    case lists:keymember(Name, 1, Headers) of
        true -> add_cors(Rest, Headers);
        false -> [{Name, Value} | add_cors(Rest, Headers)]
    end.

%% Join binaries with ", " into one binary (header values must be binary).
-spec join([binary()]) -> binary().
join([]) -> ~"";
join([Value]) -> Value;
join([Value | Rest]) -> <<Value/binary, ", ", (join(Rest))/binary>>.

%% =============================================================================
%% Config readers (validated lazily; a bad value crashes the request with a
%% clear `{invalid_cors_opt, Key, Value}` rather than denying silently)
%% =============================================================================

-spec origins(map()) -> origins().
origins(#{origins := Origins}) ->
    case Origins of
        any -> any;
        Fun when is_function(Fun, 1) -> Fun;
        List when is_list(List) -> require_binaries(origins, List);
        _ -> error({invalid_cors_opt, origins, Origins})
    end;
origins(_Config) ->
    error({invalid_cors_opt, origins, undefined}).

-spec methods(map()) -> [binary()].
methods(Config) ->
    case Config of
        #{methods := Methods} when is_list(Methods) -> require_binaries(methods, Methods);
        #{methods := Methods} -> error({invalid_cors_opt, methods, Methods});
        #{} -> [~"GET", ~"HEAD", ~"POST"]
    end.

-spec headers(map()) -> [binary()] | reflect.
headers(Config) ->
    case Config of
        #{headers := reflect} -> reflect;
        #{headers := Headers} when is_list(Headers) -> require_binaries(headers, Headers);
        #{headers := Headers} -> error({invalid_cors_opt, headers, Headers});
        #{} -> []
    end.

-spec expose(map()) -> [binary()].
expose(Config) ->
    case Config of
        #{expose := Expose} when is_list(Expose) -> require_binaries(expose, Expose);
        #{expose := Expose} -> error({invalid_cors_opt, expose, Expose});
        #{} -> []
    end.

-spec credentials(map()) -> boolean().
credentials(Config) ->
    case Config of
        #{credentials := Creds} when is_boolean(Creds) -> Creds;
        #{credentials := Creds} -> error({invalid_cors_opt, credentials, Creds});
        #{} -> false
    end.

-spec max_age(map()) -> non_neg_integer() | undefined.
max_age(Config) ->
    case Config of
        #{max_age := Age} when is_integer(Age), Age >= 0 -> Age;
        #{max_age := Age} -> error({invalid_cors_opt, max_age, Age});
        #{} -> undefined
    end.

%% Every element of a configured list must be a binary header/method/origin
%% name; a charlist (`"x"`, a common slip for `[~"x"]`) is rejected loudly
%% rather than silently matching nothing.
-spec require_binaries(atom(), [term()]) -> [binary()].
require_binaries(Key, List) ->
    case lists:all(fun is_binary/1, List) of
        true -> List;
        false -> error({invalid_cors_opt, Key, List})
    end.
