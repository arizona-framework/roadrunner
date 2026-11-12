-module(roadrunner_heap_floor_handler).
-moduledoc """
Test fixture for `roadrunner_heap_floor_SUITE` and
`roadrunner_stream_heap_floor_SUITE`. The route state picks what it does:
`{alloc, Report}` builds a large live term before it answers (so the
heap of the process running it grows) and tells `Report` that pid;
`{gated_alloc, Report}` tells `Report` its pid, waits for `go`, then
builds a smaller one; `report` answers with the running process's
`min_heap_size`; `{ws, Report}` (or `{ws, Report, Opts}`, with upgrade
options) upgrades, tells `Report` the session's pid and `min_heap_size`,
and takes messages: `alloc` builds a large live term, `small_alloc` a
small one, `report` tells
`Report` the session's `min_heap_size` and `hibernate` hibernates.
""".

-behaviour(roadrunner_handler).
-behaviour(roadrunner_ws_handler).

-export([handle/1]).
-export([init/1, handle_frame/2, handle_info/2]).

handle(Req) ->
    handle(roadrunner_req:state(Req), Req).

handle({alloc, Report}, Req) ->
    Report ! {conn, self()},
    %% About 40,000 words kept live until the handler returns.
    Live = lists:seq(1, 20000),
    {roadrunner_resp:text(200, integer_to_binary(length(Live))), Req};
handle({gated_alloc, Report}, Req) ->
    Report ! {gated, self()},
    receive
        go -> ok
    end,
    Live = lists:seq(1, 2000),
    {roadrunner_resp:text(200, integer_to_binary(length(Live))), Req};
handle(report, Req) ->
    {roadrunner_resp:text(200, integer_to_binary(min_heap_size())), Req};
handle({ws, Report}, Req) ->
    {{websocket, ?MODULE, Report}, Req};
handle({ws, Report, Opts}, Req) ->
    {{websocket, ?MODULE, Report, Opts}, Req}.

init(Report) ->
    Report ! {ws_session, self()},
    Report ! {ws_min_heap_size, min_heap_size()},
    {ok, Report}.

handle_frame(_Frame, Report) ->
    {ok, Report}.

handle_info(alloc, Report) ->
    %% About 40,000 words kept live until the callback returns.
    Live = lists:seq(1, 20000),
    Report ! {ws_alloc, length(Live)},
    {ok, Report};
handle_info(small_alloc, Report) ->
    %% About 1,000 words: under the default `ws.heap_floor` `min`.
    Live = lists:seq(1, 500),
    Report ! {ws_alloc, length(Live)},
    {ok, Report};
handle_info(report, Report) ->
    Report ! {ws_min_heap_size, min_heap_size()},
    {ok, Report};
handle_info(hibernate, Report) ->
    Report ! ws_hibernating,
    {ok, Report, [hibernate]}.

min_heap_size() ->
    {min_heap_size, Words} = process_info(self(), min_heap_size),
    Words.
