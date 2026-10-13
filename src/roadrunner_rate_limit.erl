-module(roadrunner_rate_limit).
-moduledoc false.

%% Pure token-bucket math for the per-peer request-rate guard (the
%% `roadrunner_listener` `rate_limit` opt). The bucket is accounted in integer
%% "units" so the arithmetic stays exact at any period: one request costs
%% `Cost = Period * 1000` units, and the bucket accrues `Rate` units per
%% millisecond, so a limit of `Rate` requests per `Period` seconds refills
%% exactly one request's worth of units every `Period / Rate` seconds. Capacity
%% is `Burst` requests, i.e. `Burst * Cost` units, both derived by `bucket/1`
%% for the listener's limit and a route's alike. The buckets themselves live
%% in ETS stores (`roadrunner_conn`); this module is socket- and state-free so
%% the bucket math is exhaustively testable.

-export([valid/2, bucket/1, refill/5, spend/2, retry_after_secs/3, full_guard/3, client_key/1]).

-define(MILLI, 1000).

%% Whether `Opts` is a rate limit taking `Keys`: a map with `rate` set and
%% no key outside `Keys`, each a positive integer. The listener's
%% `rate_limit` and a route's are checked by it, each with its own keys.
-doc false.
-spec valid(term(), [atom()]) -> boolean().
valid(#{rate := _} = Opts, Keys) ->
    lists:all(
        fun({Key, Value}) ->
            lists:member(Key, Keys) andalso is_integer(Value) andalso Value > 0
        end,
        maps:to_list(Opts)
    );
valid(_Opts, _Keys) ->
    false.

%% The bucket of a rate limit: its `Rate`, the bucket capacity `Cap` and the
%% `Cost` of one request, in units, with `period` 1 and `burst` `rate`
%% unless set. Derived once, so the per-request check does no arithmetic.
-doc false.
-spec bucket(#{
    rate := pos_integer(), period => pos_integer(), burst => pos_integer(), atom() => term()
}) ->
    {pos_integer(), pos_integer(), pos_integer()}.
bucket(#{rate := Rate} = Opts) ->
    Cost = maps:get(period, Opts, 1) * ?MILLI,
    {Rate, maps:get(burst, Opts, Rate) * Cost, Cost}.

%% Refill a bucket holding `Units`, last touched at `LastMs`, to its level at
%% `NowMs`: add `Elapsed * Rate` units (the refill rate is `Rate` units/ms),
%% capped at `Cap` units. A monotonic clock can read backwards across
%% schedulers, so the elapsed delta clamps to 0.
-doc false.
-spec refill(integer(), integer(), integer(), pos_integer(), pos_integer()) -> integer().
refill(Units, LastMs, NowMs, Rate, Cap) ->
    Elapsed = max(0, NowMs - LastMs),
    min(Cap, Units + Elapsed * Rate).

%% Spend one request (`Cost` units): the remaining units when the bucket can
%% cover it, else `denied`. Returns the bare integer (not `{ok, _}`) so the
%% per-request allow path allocates nothing — the remaining count is a 64-bit
%% immediate, the `denied` atom needs no heap.
-doc false.
-spec spend(integer(), pos_integer()) -> non_neg_integer() | denied.
spend(Units, Cost) when Units >= Cost -> Units - Cost;
spend(_Units, _Cost) -> denied.

%% Seconds until a depleted bucket can cover one request again, rounded up,
%% never below 1 so a throttled caller always gets a positive `Retry-After`.
-doc false.
-spec retry_after_secs(integer(), pos_integer(), pos_integer()) -> pos_integer().
retry_after_secs(Units, Rate, Cost) ->
    DeficitMs = ceil_div(Cost - Units, Rate),
    max(1, ceil_div(DeficitMs, ?MILLI)).

%% The match-spec guard of a bucket row whose units and last time are `'$1'`
%% and `'$2'`: full again by `NowMs`, its units plus the refill since then
%% reaching `Cap` (`refill/5`). `Rate` and `Cap` are numbers, or match
%% variables when each row carries its own.
-doc false.
-spec full_guard(integer(), pos_integer() | atom(), pos_integer() | atom()) -> tuple().
full_guard(NowMs, Rate, Cap) ->
    {'>=', {'+', '$1', {'*', {'-', NowMs, '$2'}, Rate}}, Cap}.

%% The address a client's bucket is keyed on. An IPv6 client is keyed by its
%% /64, the smallest network a host is given (SLAAC needs one): a host can
%% take any address in its /64, and privacy addresses rotate on their own, so
%% a per-address key would hand each new address a fresh bucket and a row of
%% its own. The /64 is the IPv6 counterpart of one IPv4 address, shared like
%% one behind NAT. An address that carries an IPv4 client, IPv4-mapped (an
%% IPv4 peer of a dual-stack listener) or under the RFC 6052 NAT64 prefix
%% `64:ff9b::/96`, is keyed as that IPv4 address, so IPv4 clients keep a
%% bucket each.
-doc false.
-spec client_key(inet:ip_address()) -> inet:ip_address().
client_key({0, 0, 0, 0, 0, 16#FFFF, AB, CD}) ->
    {AB bsr 8, AB band 16#FF, CD bsr 8, CD band 16#FF};
client_key({16#64, 16#FF9B, 0, 0, 0, 0, AB, CD}) ->
    {AB bsr 8, AB band 16#FF, CD bsr 8, CD band 16#FF};
client_key({A, B, C, D, _, _, _, _}) ->
    {A, B, C, D, 0, 0, 0, 0};
client_key(IPv4) ->
    IPv4.

%% Integer ceiling division (non-negative numerator, positive divisor).
-spec ceil_div(non_neg_integer(), pos_integer()) -> non_neg_integer().
ceil_div(A, B) -> (A + B - 1) div B.
