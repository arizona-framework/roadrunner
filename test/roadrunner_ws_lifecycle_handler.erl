-module(roadrunner_ws_lifecycle_handler).
-moduledoc """
Test fixture — exports all three callbacks (`init/1`, `handle_frame/2`,
`handle_info/2`) and dispatches each to the return shape encoded in
the state map. Lets a single handler module drive every optional-
callback path in `roadrunner_ws_session_tests` without N tiny fixture
modules.

Usage: pass a state map of the form

    #{
        on_init  => Action,  % optional, defaults to `ok`
        on_frame => Action,  % optional, defaults to `ok`
        on_info  => Action,  % optional, defaults to `ok`
        sink     => SinkPid  % optional — receives `{event, init|frame|info}`
                             % so tests can confirm a callback ran
    }

…where `Action` is one of:

    ok                              -> {ok, State}
    ok_hibernate                    -> {ok, State, [hibernate]}
    {reply, [{Op, Bin}, ...]}        -> {reply, Frames, State}
    {reply_hibernate, [{Op, Bin}]}   -> {reply, Frames, State, [hibernate]}
    close                            -> {close, State}
    {close, Code, Reason}            -> {close, Code, Reason, State}
""".

-behaviour(roadrunner_ws_handler).

-export([init/1, handle_frame/2, handle_info/2]).

-spec init(map()) -> roadrunner_ws_handler:result().
init(#{on_init := Action} = State) ->
    notify(State, init),
    resolve(Action, State);
init(State) ->
    notify(State, init),
    {ok, State}.

-spec handle_frame(roadrunner_ws:frame(), map()) -> roadrunner_ws_handler:result().
handle_frame(_Frame, #{on_frame := Action} = State) ->
    notify(State, frame),
    resolve(Action, State);
handle_frame(_Frame, State) ->
    notify(State, frame),
    {ok, State}.

-spec handle_info(term(), map()) -> roadrunner_ws_handler:result().
handle_info(_Msg, #{on_info := Action} = State) ->
    notify(State, info),
    resolve(Action, State);
handle_info(_Msg, State) ->
    notify(State, info),
    {ok, State}.

%% --- helpers ---

resolve(ok, State) -> {ok, State};
resolve(ok_hibernate, State) -> {ok, State, [hibernate]};
resolve({reply, Frames}, State) -> {reply, Frames, State};
resolve({reply_hibernate, Frames}, State) -> {reply, Frames, State, [hibernate]};
resolve(close, State) -> {close, State};
resolve({close, Code, Reason}, State) -> {close, Code, Reason, State}.

notify(#{sink := Pid}, Tag) when is_pid(Pid) -> Pid ! {event, Tag};
notify(_, _) -> ok.
