-module(roadrunner_ws_opts_handler).
-moduledoc """
Test fixture for `roadrunner_ws_opts_SUITE`: upgrades with the route
state's `opts` as the upgrade options, echoes text frames, and tells the
state's `report` pid its session pid (`{session, Pid}`) and why it ended
(`{terminated, Reason}`).
""".

-behaviour(roadrunner_handler).
-behaviour(roadrunner_ws_handler).

-export([handle/1]).
-export([init/1, handle_frame/2, terminate/2]).

handle(Req) ->
    #{report := Report, opts := Opts} = roadrunner_req:state(Req),
    {{websocket, ?MODULE, Report, Opts}, Req}.

init(Report) ->
    Report ! {session, self()},
    {ok, Report}.

handle_frame(#{opcode := text, payload := Payload}, Report) ->
    {reply, [{text, Payload}], Report};
handle_frame(_Frame, Report) ->
    {ok, Report}.

terminate(Reason, Report) ->
    Report ! {terminated, Reason}.
