-module(roadrunner_route_rate_limit).
-moduledoc false.

%% A route's own `rate_limit` (`roadrunner_router:rate_limit()`), as a
%% middleware `roadrunner_router` puts first among the route's own
%% middlewares, after the listener's: a route that sets no limit has no check
%% at all, and a refusal is a response from the route like any other, on every
%% protocol. Its buckets live in the listener's route bucket store, published
%% under `{roadrunner_route_rate_limit, ListenerName}` before any route that
%% uses it, with the same rows and token-bucket spend as the listener's own
%% `rate_limit` (`roadrunner_conn:rate_limit_spend/7`), keyed on the route and
%% the client.

-behaviour(roadrunner_middleware).

-export([init/1, call/3, evict_full/2]).

%% The key of the route buckets: path, sorted methods, and the rate, bucket
%% capacity and cost of one request, in token-bucket units.
-type state() ::
    {binary(), [binary()] | undefined, {pos_integer(), pos_integer(), pos_integer()}}.

%% The route's bucket key, its terms derived as the listener's are
%% (`roadrunner_rate_limit:bucket/1`), once, so the per-request check does no
%% arithmetic. The key holds the route's path and methods (two routes a
%% request could reach never share both) and its bucket terms, so
%% `reload_routes/2` keeps the buckets of a route whose limit is unchanged
%% and starts new ones when it changes; `evict_full/2` reads the rate and
%% capacity back from it.
-doc false.
-spec init(#{
    rate_limit := roadrunner_router:rate_limit(),
    path := binary(),
    methods := [binary()] | undefined
}) -> state().
init(#{rate_limit := RateLimit, path := Path, methods := Methods}) ->
    {Path, Methods, roadrunner_rate_limit:bucket(RateLimit)}.

%% A client over the route's rate gets `429 Too Many Requests` with
%% `Retry-After`, counted and reported like the listener's refusals. Being a
%% buffered response, it carries its own `content-length: 0`, so an HTTP/1.1
%% connection can go on after it. The
%% client is `roadrunner_req:client_ip/1` (the peer unless `real_ip` resolved
%% one), keyed as the listener's are (`roadrunner_rate_limit:client_key/1`); a
%% request without one is not limited, as with the listener's limit.
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
check(IP, Name, {_Path, _Methods, {Rate, Cap, Cost}} = RouteKey) ->
    {Table, Counter} = persistent_term:get({roadrunner_route_rate_limit, Name}),
    Key = {RouteKey, roadrunner_rate_limit:client_key(IP)},
    roadrunner_conn:rate_limit_spend(Table, Key, Rate, Cap, Cost, Counter, Name).

%% Drop every route bucket full again by `NowMs`, in one `select_delete`
%% pass, returning the number dropped, as the listener's own store is swept
%% (`roadrunner_conn:rate_limit_evict_full/4`). Each route has its own rate,
%% so the match spec reads it, and the capacity, from the bucket key. Run by
%% the listener on a timer, off the request path.
-doc false.
-spec evict_full(ets:table(), integer()) -> non_neg_integer().
evict_full(Table, NowMs) ->
    %% Row is `{{{Path, Methods, {Rate, Cap, Cost}}, IP}, Units, LastMs}`.
    Spec = [
        {
            {{{'_', '_', {'$3', '$4', '_'}}, '_'}, '$1', '$2'},
            [roadrunner_rate_limit:full_guard(NowMs, '$3', '$4')],
            [true]
        }
    ],
    ets:select_delete(Table, Spec).
