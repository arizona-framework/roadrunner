-module(roadrunner_route_pause).
-moduledoc """
Stops a process at a named point of `roadrunner_route_keeper` (a
`?PAUSE(Point)` there, compiled only into Common Test builds) until the test lets
it go on, so a test can run what races that process between two of its
steps: a request between its insert and its check, the keeper between
closing its gate and parking a request, and so on.

A test arms a point with `arm/1,2` (once: the first process to reach it
stops, any other goes on), waits for the stop with `await/1`, does what it
wants to race, then lets the process go on with `resume/2`. Nothing stops
while nothing is armed, so the points cost a test build one
`persistent_term` read.
""".

-export([here/1, arm/1, arm/2, await/1, resume/2]).

%% Called by `roadrunner_route_keeper` at each point.
-spec here(atom()) -> ok.
here(Point) ->
    case persistent_term:get(?MODULE, false) of
        false -> ok;
        true -> here(Point, ets:whereis(?MODULE))
    end.

here(_Point, undefined) ->
    ok;
here(Point, Table) ->
    Self = self(),
    case ets:lookup(Table, Point) of
        [{Point, Test, Who}] when Who =:= any; Who =:= Self ->
            %% Taken once: two processes reaching the point at once both
            %% see the row, only one deletes it.
            case ets:select_delete(Table, [{{Point, Test, Who}, [], [true]}]) of
                1 ->
                    Test ! {paused, Point, Self},
                    receive
                        {resume, Point} -> ok
                    end;
                0 ->
                    ok
            end;
        _ ->
            ok
    end.

%% Stop the first process to reach `Point`.
-spec arm(atom()) -> ok.
arm(Point) ->
    arm(Point, any).

%% Stop `Who` when it reaches `Point`.
-spec arm(atom(), pid() | any) -> ok.
arm(Point, Who) ->
    _ =
        case ets:whereis(?MODULE) of
            undefined -> ets:new(?MODULE, [named_table, public, set]);
            Table -> Table
        end,
    true = ets:insert(?MODULE, {Point, self(), Who}),
    case persistent_term:get(?MODULE, false) of
        true -> ok;
        false -> persistent_term:put(?MODULE, true)
    end.

%% The process stopped at `Point`.
-spec await(atom()) -> pid().
await(Point) ->
    receive
        {paused, Point, Pid} -> Pid
    after 5000 -> error({never_paused, Point})
    end.

%% Let a stopped process go on.
-spec resume(pid(), atom()) -> ok.
resume(Pid, Point) ->
    Pid ! {resume, Point},
    ok.
