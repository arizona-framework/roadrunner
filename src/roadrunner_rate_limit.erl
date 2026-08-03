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

-export([refill/5, spend/2, retry_after_secs/3, units/2, compile_route_config/1]).

-define(MILLI, 1000).

%% Derive the integer-unit pair the bucket check uses from a `Burst`/`Period`:
%% one request costs `Cost = Period * 1000` units and the bucket holds `Burst`
%% requests, i.e. `Cap = Burst * Cost` units. The single source of this
%% derivation, shared by the listener-global path (`roadrunner_conn`) and the
%% per-route compile path (`compile_route_config/1`).
-doc false.
-spec units(pos_integer(), pos_integer()) -> {pos_integer(), pos_integer()}.
units(Burst, Period) ->
    Cost = Period * ?MILLI,
    {Burst * Cost, Cost}.

%% Validate a per-route `rate_limit` config and derive its `{Rate, Cap, Cost}`
%% triple. Accepts a map with `rate` (required, positive int) and optional
%% `burst` (default `rate`) / `period` (default 1, so `rate` is per-second).
%% Any other key is rejected — the table-global `idle_ttl`/`sweep_interval` are
%% listener policy, not per-bucket. Raises `{invalid_rate_limit, Opts}` on bad
%% input so a bad route config fails loudly at listener init.
-doc false.
-spec compile_route_config(term()) -> {pos_integer(), pos_integer(), pos_integer()}.
compile_route_config(Opts) when is_map(Opts) ->
    Resolved = maps:fold(
        fun(K, V, Acc) ->
            case
                (K =:= rate orelse K =:= burst orelse K =:= period) andalso
                    is_integer(V) andalso V > 0
            of
                true -> Acc#{K => V};
                false -> error({invalid_rate_limit, Opts})
            end
        end,
        #{},
        Opts
    ),
    case Resolved of
        #{rate := Rate} ->
            {Cap, Cost} = units(maps:get(burst, Resolved, Rate), maps:get(period, Resolved, 1)),
            {Rate, Cap, Cost};
        #{} ->
            error({invalid_rate_limit, Opts})
    end;
compile_route_config(Opts) ->
    error({invalid_rate_limit, Opts}).

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

%% Integer ceiling division (non-negative numerator, positive divisor).
-spec ceil_div(non_neg_integer(), pos_integer()) -> non_neg_integer().
ceil_div(A, B) -> (A + B - 1) div B.
