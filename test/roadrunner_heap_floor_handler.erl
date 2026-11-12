-module(roadrunner_heap_floor_handler).
-moduledoc """
Test fixture for `roadrunner_heap_floor_SUITE`. The route state picks what
it does: `{alloc, Report}` builds a large live term before it answers (so
the connection's heap grows) and tells `Report` the connection pid;
`report` answers with the connection's `min_heap_size`; `{ws, Report}`
upgrades and tells `Report` the session's `min_heap_size`.
""".

-behaviour(roadrunner_handler).
-behaviour(roadrunner_ws_handler).

-export([handle/1]).
-export([init/1, handle_frame/2]).

handle(Req) ->
    handle(roadrunner_req:state(Req), Req).

handle({alloc, Report}, Req) ->
    Report ! {conn, self()},
    %% About 40,000 words kept live until the handler returns.
    Live = lists:seq(1, 20000),
    {roadrunner_resp:text(200, integer_to_binary(length(Live))), Req};
handle(report, Req) ->
    {roadrunner_resp:text(200, integer_to_binary(min_heap_size())), Req};
handle({ws, Report}, Req) ->
    {{websocket, ?MODULE, Report}, Req}.

init(Report) ->
    Report ! {ws_min_heap_size, min_heap_size()},
    {ok, Report}.

handle_frame(_Frame, Report) ->
    {ok, Report}.

min_heap_size() ->
    {min_heap_size, Words} = process_info(self(), min_heap_size),
    Words.
