-module(roadrunner_respond_handler).
-moduledoc false.

%% Test handler for `roadrunner_respond_SUITE`: answers with a
%% `{respond, Headers, Fun}` response, the route's state picking what the
%% fun does. `{report, Pid, Case}` states send the test what the calls
%% returned.

-behaviour(roadrunner_handler).

-export([handle/1]).

handle(Req) ->
    {
        {respond, [{~"x-tuple", ~"tuple"}, {~"x-both", ~"tuple"}],
            respond_fun(roadrunner_req:state(Req))},
        Req
    }.

respond_fun(reply) ->
    fun(Req) ->
        ok = roadrunner_respond:reply(
            200, [{~"content-type", ~"text/plain"}, {~"x-both", ~"call"}], ~"replied", Req
        ),
        Req
    end;
respond_fun(inform) ->
    fun(Req) ->
        ok = roadrunner_respond:inform(103, [{~"link", ~"</a.css>; rel=preload"}], Req),
        ok = roadrunner_respond:inform(103, [{~"link", ~"</b.js>; rel=preload"}], Req),
        ok = roadrunner_respond:reply(200, [], ~"after hints", Req),
        Req
    end;
respond_fun(echo) ->
    fun(Req0) ->
        {ok, Body, Req} = roadrunner_req:read_body(Req0),
        ok = roadrunner_respond:reply(200, [], Body, Req),
        Req
    end;
respond_fun(stream) ->
    fun(Req) ->
        {ok, Send} = roadrunner_respond:stream(200, [{~"content-type", ~"text/plain"}], Req),
        ok = Send(~"chunk1-", nofin),
        ok = Send(~"chunk2", fin),
        Req
    end;
respond_fun(stream_left_open) ->
    fun(Req) ->
        {ok, Send} = roadrunner_respond:stream(200, [], Req),
        ok = Send(~"open", nofin),
        Req
    end;
respond_fun(stream_trailers) ->
    fun(Req) ->
        {ok, Send} = roadrunner_respond:stream(200, [{~"trailer", ~"x-sum"}], Req),
        ok = Send(~"body", {fin, [{~"x-sum", ~"1"}]}),
        Req
    end;
respond_fun({sendfile, File}) ->
    fun(Req) ->
        Headers = [{~"content-type", ~"text/plain"}, {~"content-length", ~"4"}],
        ok = roadrunner_respond:sendfile(200, Headers, {File, 2, 4}, Req),
        Req
    end;
respond_fun(nothing) ->
    fun(Req) -> Req end;
respond_fun(crash_before) ->
    fun(_Req) -> error(boom) end;
respond_fun(crash_after) ->
    fun(Req) ->
        ok = roadrunner_respond:reply(200, [], ~"sent", Req),
        error(boom)
    end;
respond_fun(crash_open) ->
    fun(Req) ->
        {ok, Send} = roadrunner_respond:stream(200, [], Req),
        ok = Send(~"partial", nofin),
        error(boom)
    end;
respond_fun({report, Pid, twice}) ->
    fun(Req) ->
        ok = roadrunner_respond:reply(200, [], ~"first", Req),
        Pid ! {respond_result, raised(fun() -> roadrunner_respond:reply(200, [], ~"x", Req) end)},
        Pid ! {respond_result, raised(fun() -> roadrunner_respond:inform(103, [], Req) end)},
        Req
    end;
respond_fun({report, Pid, unsafe_inform}) ->
    fun(Req) ->
        Pid ! {respond_result, roadrunner_respond:inform(103, [{~"x-bad", ~"a\r\nb"}], Req)},
        ok = roadrunner_respond:reply(200, [], ~"ok", Req),
        Req
    end;
respond_fun({report, Pid, unsafe_reply}) ->
    fun(Req) ->
        Pid ! {respond_result, roadrunner_respond:reply(200, [{~"x-bad", ~"a\r\nb"}], ~"", Req)},
        Req
    end;
respond_fun({report, Pid, big_inform}) ->
    fun(Req) ->
        Pid ! {respond_result, roadrunner_respond:inform(103, big_header(), Req)},
        ok = roadrunner_respond:reply(200, [], ~"ok", Req),
        Req
    end;
respond_fun({report, Pid, until_reset}) ->
    fun(Req) ->
        {ok, Send} = roadrunner_respond:stream(200, [], Req),
        ok = Send(~"first", nofin),
        Pid ! {respond_result, streaming},
        ok = send_until_error(Send),
        Req
    end;
respond_fun({report, Pid, big_stream}) ->
    fun(Req) ->
        Pid ! {respond_result, roadrunner_respond:stream(200, big_header(), Req)},
        Req
    end.

raised(Fun) ->
    try Fun() of
        Result -> {returned, Result}
    catch
        error:Reason -> {raised, Reason}
    end.

send_until_error(Send) ->
    case Send(~"x", nofin) of
        ok -> send_until_error(Send);
        {error, _} -> ok
    end.

big_header() ->
    [{~"x-big", binary:copy(~"v", 1000)}].
