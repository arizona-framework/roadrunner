-module(roadrunner_rate_limit).
-moduledoc false.

%% Pure token-bucket math for the per-peer request-rate guard (the
%% `roadrunner_listener` `rate_limit` opt). The bucket is accounted in integer
%% "units" so the arithmetic stays exact at any period: one request costs
%% `Cost = Period * 1000` units, and the bucket accrues `Rate` units per
%% millisecond, so a limit of `Rate` requests per `Period` seconds refills
%% exactly one request's worth of units every `Period / Rate` seconds. Capacity
%% is `Burst` requests, i.e. `Burst * Cost` units. The caller (the per-listener
%% ETS bucket store in `roadrunner_conn`) derives `Cost` and the cap; this
%% module is socket- and state-free so the bucket math is exhaustively testable.

-export([refill/5, spend/2, retry_after_secs/3]).

-define(MILLI, 1000).

%% Refill a bucket holding `Units`, last touched at `LastMs`, to its level at
%% `NowMs`: add `Elapsed * Rate` units (the refill rate is `Rate` units/ms),
%% capped at `Cap` units. A monotonic clock can read backwards across
%% schedulers, so the elapsed delta clamps to 0.
-doc false.
-spec refill(integer(), integer(), integer(), pos_integer(), pos_integer()) -> integer().
refill(Units, LastMs, NowMs, Rate, Cap) ->
    Elapsed = max(0, NowMs - LastMs),
    min(Cap, Units + Elapsed * Rate).

%% Spend one request (`Cost` units). `{ok, Remaining}` when the bucket can cover
%% it, else `denied`.
-doc false.
-spec spend(integer(), pos_integer()) -> {ok, integer()} | denied.
spend(Units, Cost) when Units >= Cost -> {ok, Units - Cost};
spend(_Units, _Cost) -> denied.

%% Seconds until a depleted bucket can cover one request again, rounded up,
%% never below 1 so a throttled caller always gets a positive `Retry-After`.
-doc false.
-spec retry_after_secs(integer(), pos_integer(), pos_integer()) -> pos_integer().
retry_after_secs(Units, Rate, Cost) ->
    DeficitMs = ceil_div(Cost - Units, Rate),
    max(1, ceil_div(DeficitMs, ?MILLI)).

%% Integer ceiling division (non-negative numerator, positive divisor).
-spec ceil_div(non_neg_integer(), pos_integer()) -> non_neg_integer().
ceil_div(A, B) -> (A + B - 1) div B.
