-module(roadrunner_bench_memprofile).
-moduledoc """
Run inside a server peer BEAM (called via `peer:call/4`) to capture a
per-`initial_call` memory breakdown across all live processes.

Use case: answer "which process type is holding the heap?" when
`erlang:memory/0` shows the `processes` bucket dominating, e.g. for
HTTP/2 stream workers vs conn loops vs ssl gen_statems.

For `proc_lib`-spawned processes (gen_server, gen_statem, supervisor,
proc_lib:spawn_link/3), the bare `initial_call` is uninformatively
`{proc_lib, init_p, _}`. This module resolves the real entry by
reading the process dictionary's `$initial_call` (set by proc_lib),
matching how observer reports it.
""".

-export([snapshot/0]).

-doc """
Return `{TotalProcs, Groups}` where `Groups` is a list of
`{InitialCall, Stats}` tuples sorted by total memory descending.

`Stats` is `#{count, total_bytes, avg_bytes, max_bytes,
top_current_funcs}` where `top_current_funcs` is the top-5
`current_function` values by occurrence count within the group.
""".
-spec snapshot() ->
    {non_neg_integer(), [{term(), map()}]}.
snapshot() ->
    Procs = erlang:processes(),
    Acc = lists:foldl(fun fold_proc/2, #{}, Procs),
    Groups = lists:sort(
        fun({_, #{total_bytes := A}}, {_, #{total_bytes := B}}) -> A >= B end,
        [{IC, finalize(Stats)} || {IC, Stats} <- maps:to_list(Acc)]
    ),
    {length(Procs), Groups}.

fold_proc(Pid, Acc) ->
    case
        erlang:process_info(Pid, [
            initial_call, dictionary, memory, current_function
        ])
    of
        undefined ->
            Acc;
        Info ->
            InitialCall = resolve_initial_call(Info),
            Memory = proplists:get_value(memory, Info, 0),
            CurrentFun = proplists:get_value(current_function, Info, undefined),
            update_group(InitialCall, Memory, CurrentFun, Acc)
    end.

%% proc_lib stashes the real MFA under `$initial_call` so observer can
%% report it; mirror that here so gen_servers / gen_statems don't all
%% collapse into `{proc_lib, init_p, _}`.
resolve_initial_call(Info) ->
    case proplists:get_value(initial_call, Info) of
        {proc_lib, init_p, _} ->
            Dict = proplists:get_value(dictionary, Info, []),
            case lists:keyfind('$initial_call', 1, Dict) of
                {_, {M, F, A}} -> {M, F, A};
                _ -> {proc_lib, init_p, '_'}
            end;
        Other ->
            Other
    end.

update_group(InitialCall, Memory, CurrentFun, Acc) ->
    Prior = maps:get(InitialCall, Acc, #{
        count => 0, total_bytes => 0, max_bytes => 0, current_funs => #{}
    }),
    #{
        count := C, total_bytes := T, max_bytes := M, current_funs := CFs
    } = Prior,
    Acc#{
        InitialCall => #{
            count => C + 1,
            total_bytes => T + Memory,
            max_bytes => max(M, Memory),
            current_funs => maps:update_with(CurrentFun, fun(X) -> X + 1 end, 1, CFs)
        }
    }.

finalize(#{count := C, total_bytes := T, max_bytes := M, current_funs := CFs}) ->
    Top = lists:sublist(
        lists:sort(fun({_, A}, {_, B}) -> A >= B end, maps:to_list(CFs)),
        5
    ),
    #{
        count => C,
        total_bytes => T,
        avg_bytes => T div max(C, 1),
        max_bytes => M,
        top_current_funcs => Top
    }.
