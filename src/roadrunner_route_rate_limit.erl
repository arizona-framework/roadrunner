-module(roadrunner_route_rate_limit).
-moduledoc false.

%% A route's own `rate_limit` (`roadrunner_router:rate_limit()`), as a
%% middleware `roadrunner_router` puts first among the route's own
%% middlewares, after the listener's: a route that sets no limit has no check
%% at all, and a refusal is a response from the route like any other, on every
%% protocol. Its buckets live in the listener's route bucket store, published
%% under `{roadrunner_route_rate_limit, ListenerName}` before any route that
%% uses it, with the same rows and token-bucket check as the listener's own
%% `rate_limit` (`roadrunner_conn:rate_limit_check/6`), keyed on the route and
%% the client.

-behaviour(roadrunner_middleware).

-export([init/1, call/3, evict_full/2]).

%% Rate, bucket capacity and cost of one request, in token-bucket units, and
%% the key of the route buckets.
-type state() ::
    {pos_integer(), pos_integer(), pos_integer(), route_key()}.

%% Path, sorted methods, rate, period and burst of the route.
-type route_key() ::
    {binary(), [binary()] | undefined, pos_integer(), pos_integer(), pos_integer()}.

%% The route's bucket terms, as the listener's are resolved
%% (`roadrunner_conn:resolve_rate_limit/2`): one request costs `Period * 1000`
%% units, the bucket holds `Burst` requests' worth and refills `Rate` units a
%% millisecond. Derived once, so the per-request check does no arithmetic.
%% The bucket key holds the route's path and methods (two routes a request
%% could reach never share both) and its settings, so `reload_routes/2` keeps
%% the buckets of a route whose limit is unchanged and starts new ones when it
%% changes; `evict_full/2` reads the rate and capacity back from it.
-doc false.
-spec init(#{
    rate_limit := roadrunner_router:rate_limit(),
    path := binary(),
    methods := [binary()] | undefined
}) -> state().
init(#{rate_limit := #{rate := Rate} = RateLimit, path := Path, methods := Methods}) ->
    Period = maps:get(period, RateLimit, 1),
    Burst = maps:get(burst, RateLimit, Rate),
    Cost = Period * 1000,
    {Rate, Burst * Cost, Cost, {Path, Methods, Rate, Period, Burst}}.

%% A client over the route's rate gets `429 Too Many Requests` with
%% `Retry-After`, counted and reported like the listener's refusals. Being a
%% buffered response, it carries its own `content-length: 0`, so an HTTP/1.1
%% connection can go on after it. The
%% client is `roadrunner_req:client_ip/1` (the peer unless `real_ip` resolved
%% one); a request without one is not limited, as with the listener's limit.
-doc false.
-spec call(roadrunner_req:request(), roadrunner_middleware:next(), state()) ->
    roadrunner_handler:result().
call(#{listener_name := Name} = Req, Next, State) ->
    case check(roadrunner_req:client_ip(Req), Name, State) of
        allow ->
            Next(Req);
        {deny, RetryAfter} ->
            Headers = [{~"content-length", ~"0"}, {~"retry-after", integer_to_binary(RetryAfter)}],
            {{429, Headers, ~""}, Req}
    end.

-spec check(inet:ip_address() | undefined, atom(), state()) -> allow | {deny, pos_integer()}.
check(undefined, _Name, _State) ->
    allow;
check(IP, Name, {Rate, Cap, Cost, RouteKey}) ->
    {Table, Counter} = persistent_term:get({roadrunner_route_rate_limit, Name}),
    NowMs = erlang:monotonic_time(millisecond),
    Key = {RouteKey, IP},
    maybe
        {deny, _} = Deny ?= roadrunner_conn:rate_limit_check(Table, Key, Rate, Cap, Cost, NowMs),
        ok = roadrunner_conn:throttled_telemetry(Name, Counter, rate_limit),
        Deny
    end.

%% Drop every route bucket full again by `NowMs`, in one `select_delete`
%% pass, returning the number dropped, as the listener's own store is swept
%% (`roadrunner_conn:rate_limit_evict_full/4`). Each route has its own rate,
%% so the match spec reads it, and the capacity, from the bucket key. Run by
%% the listener on a timer, off the request path.
-doc false.
-spec evict_full(ets:table(), integer()) -> non_neg_integer().
evict_full(Table, NowMs) ->
    %% Row is `{{{Path, Methods, Rate, Period, Burst}, IP}, Units, LastMs}`; it
    %% is full once `Units` plus the refill since `LastMs` reaches
    %% `Burst * Period * 1000`.
    Spec = [
        {
            {{{'_', '_', '$3', '$4', '$5'}, '_'}, '$1', '$2'},
            [{'>=', {'+', '$1', {'*', {'-', NowMs, '$2'}, '$3'}}, {'*', {'*', '$5', '$4'}, 1000}}],
            [true]
        }
    ],
    ets:select_delete(Table, Spec).
