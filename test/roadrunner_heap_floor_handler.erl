-module(roadrunner_heap_floor_handler).
-moduledoc """
Test fixture for `roadrunner_heap_floor_SUITE` and
`roadrunner_stream_heap_floor_SUITE`. The route state picks what it does:
`{alloc, Report}` builds a large live term before it answers (so the
heap of the process running it grows) and tells `Report` that pid;
`{send_alloc, Report}` does the same in a `{send, ...}` fun;
`{gated_alloc, Report}` tells `Report` its pid, waits for `go`, then
builds a smaller one; `{garbage, Report}` tells `Report` its pid and
makes a lot of short-lived garbage while keeping little live;
`{stream_garbage, Report}` and `{send_stream_garbage, Report}` tell
`Report` their pid and stream a body, making that garbage between its
chunks, as a `stream` response and from a `{send, ...}` fun;
`{send_stream_alloc, Report}` tells `Report` its pid, starts a stream
from a `{send, ...}` fun and builds a live term before it ends it;
`{min_heap, Report}` tells `Report` its pid and answers with its
`min_heap_size`; `report` answers with the running process's
`min_heap_size`; `{heap, Report}` tells `Report` its pid and answers with
its heap's size; `{ws, Report}` (or `{ws, Report, Opts}`, with upgrade
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
handle({send_alloc, Report}, Req) ->
    {
        {send, [], fun(R) ->
            Report ! {conn, self()},
            %% About 40,000 words kept live until the fun has answered.
            Live = lists:seq(1, 20000),
            ok = roadrunner_send:reply(200, [], integer_to_binary(length(Live)), R),
            R
        end},
        Req
    };
handle({gated_alloc, Report}, Req) ->
    Report ! {gated, self()},
    receive
        go -> ok
    end,
    Live = lists:seq(1, 2000),
    {roadrunner_resp:text(200, integer_to_binary(length(Live))), Req};
handle({garbage, Report}, Req) ->
    Report ! {conn, self()},
    %% About 40,000 words of garbage, at most 100 of them live at once.
    ok = garbage(400),
    {roadrunner_resp:text(200, ~"ok"), Req};
handle({stream_garbage, Report}, Req) ->
    Report ! {conn, self()},
    {{stream, 200, [], fun stream_garbage/1}, Req};
handle({send_stream_garbage, Report}, Req) ->
    {
        {send, [], fun(R) ->
            Report ! {conn, self()},
            {ok, Send} = roadrunner_send:stream(200, [], R),
            ok = stream_garbage(Send),
            R
        end},
        Req
    };
handle({send_stream_alloc, Report}, Req) ->
    {
        {send, [], fun(R) ->
            Report ! {conn, self()},
            {ok, Send} = roadrunner_send:stream(200, [], R),
            %% About 5,000 words kept live until the stream ends, in a few
            %% reductions (collecting a much larger heap would itself take
            %% more than the short body the floor learns from).
            Live = erlang:make_tuple(5000, 0),
            ok = Send(integer_to_binary(tuple_size(Live)), fin),
            R
        end},
        Req
    };
handle({min_heap, Report}, Req) ->
    Report ! {conn, self()},
    {roadrunner_resp:text(200, integer_to_binary(min_heap_size())), Req};
handle({heap, Report}, Req) ->
    Report ! {conn, self()},
    {heap_size, Words} = process_info(self(), heap_size),
    {roadrunner_resp:text(200, integer_to_binary(Words)), Req};
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

%% Four chunks with about 40,000 words of garbage before each.
stream_garbage(Send) ->
    ok = lists:foreach(
        fun(_) ->
            ok = garbage(400),
            ok = Send(~"chunk", nofin)
        end,
        lists:seq(1, 4)
    ),
    Send(<<>>, fin).

garbage(0) ->
    ok;
garbage(N) ->
    50 = length(lists:seq(1, 50)),
    garbage(N - 1).

min_heap_size() ->
    {min_heap_size, Words} = process_info(self(), min_heap_size),
    Words.
