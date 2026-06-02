-module(roadrunner_loop_sys).
-moduledoc false.

%% Shared OTP `sys` / `gen` message handling for the hand-written
%% `{loop, ...}` streaming-response loops: h1 `roadrunner_loop_response`,
%% h2 `roadrunner_http2_loop_response`, h3 `roadrunner_http3_stream_worker`.
%% Those are plain `receive` loops, not `gen_*` behaviours, so they do not
%% speak the OTP system protocol on their own. Each routes the OTP message
%% shapes here so `sys:get_state/1`, `sys:replace_state/2`,
%% `sys:get_status/1` and `sys:terminate/2` work, and a stray
%% `gen_server:call/2,3` fails fast instead of hanging.
%%
%% The state ops (get_state, replace_state, get_status, terminate) work.
%% `self()` is passed as the sys Parent: these loops are top-level processes
%% with no OTP supervisor driving them over the sys protocol, and no
%% supported op calls or links the Parent. Live tracing (`sys:trace` /
%% `sys:log`) installs but emits no events, because the loops do not thread
%% `sys:handle_debug/4` per message.

-export([handle_system/4, gen_call_unsupported/1]).
%% `sys` callbacks — invoked by `sys:handle_system_msg/6`, not called directly.
-export([system_continue/3, system_terminate/4, system_get_state/1, system_replace_state/2]).

%% Closure that re-enters the calling loop with a (possibly replaced)
%% handler state. The loops return ok when the handler stops.
-type resume() :: fun((State :: term()) -> ok).
%% sys Misc payload: the loop resume closure paired with the handler state
%% exposed via system_get_state/1.
-type misc() :: {resume(), State :: term()}.

%% Hand a received `{system, From, Req}` to the OTP system-message handler.
%% This runs inline in the loop `receive`, so `self()` is the loop process
%% and is used as the sys Parent (sound: no supported op calls or links it).
%% On a state op `sys` calls `system_continue/3` (which resumes the loop via
%% `Resume`); on terminate it calls `system_terminate/4`. The spec is
%% `no_return()` to match `sys:handle_system_msg/6`; at runtime it returns
%% `ok` once the resumed loop stops.
-doc false.
-spec handle_system(Req :: term(), From :: {pid(), term()}, State :: term(), resume()) ->
    no_return().
handle_system(Req, From, State, Resume) ->
    sys:handle_system_msg(Req, From, self(), ?MODULE, [], {Resume, State}).

%% Reply to a gen-call request so the caller fails fast rather than timing
%% out: these loops implement no gen call protocol.
-doc false.
-spec gen_call_unsupported(From :: {pid(), term()}) -> ok.
gen_call_unsupported(From) ->
    gen:reply(From, {error, not_supported}).

%% Resume the loop. Spec is `ok` (the loop returns when the handler stops),
%% though the sys behaviour declares `no_return()` for gen_* loops that never
%% return normally; we are not a `-behaviour(sys)`, so the narrower type holds.
-doc false.
-spec system_continue(pid(), [sys:dbg_opt()], misc()) -> ok.
system_continue(_Parent, _Debug, {Resume, State}) ->
    Resume(State).

-doc false.
-spec system_terminate(term(), pid(), [sys:dbg_opt()], misc()) -> no_return().
system_terminate(Reason, _Parent, _Debug, _Misc) ->
    exit(Reason).

-doc false.
-spec system_get_state(misc()) -> {ok, State :: term()}.
system_get_state({_Resume, State}) ->
    {ok, State}.

-doc false.
-spec system_replace_state(fun((term()) -> term()), misc()) -> {ok, term(), misc()}.
system_replace_state(StateFun, {Resume, State}) ->
    NState = StateFun(State),
    {ok, NState, {Resume, NState}}.
