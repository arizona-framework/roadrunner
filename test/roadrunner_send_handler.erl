-module(roadrunner_send_handler).
-moduledoc false.

%% Test handler for `roadrunner_send_SUITE`: answers with a
%% `{send, Headers, Fun}` response, the route's state picking what the
%% fun does. `{report, Pid, Case}` states send the test what the calls
%% returned.

-behaviour(roadrunner_handler).

-export([handle/1]).

handle(Req) ->
    {
        {send, [{~"x-tuple", ~"tuple"}, {~"x-both", ~"tuple"}],
            send_fun(roadrunner_req:state(Req))},
        Req
    }.

send_fun(reply) ->
    fun(Req) ->
        ok = roadrunner_send:reply(
            200, [{~"content-type", ~"text/plain"}, {~"x-both", ~"call"}], ~"replied", Req
        ),
        Req
    end;
send_fun(inform) ->
    fun(Req) ->
        ok = roadrunner_send:inform(103, [{~"link", ~"</a.css>; rel=preload"}], Req),
        ok = roadrunner_send:inform(103, [{~"link", ~"</b.js>; rel=preload"}], Req),
        ok = roadrunner_send:reply(200, [], ~"after hints", Req),
        Req
    end;
send_fun(echo) ->
    fun(Req0) ->
        {ok, Body, Req} = roadrunner_req:read_body(Req0),
        ok = roadrunner_send:reply(roadrunner_resp:text(200, Body), Req),
        Req
    end;
send_fun(stream) ->
    fun(Req) ->
        {ok, Send} = roadrunner_send:stream(200, [{~"content-type", ~"text/plain"}], Req),
        ok = Send(~"chunk1-", nofin),
        ok = Send(~"chunk2", fin),
        Req
    end;
send_fun(stream_left_open) ->
    fun(Req) ->
        {ok, Send} = roadrunner_send:stream(200, [], Req),
        ok = Send(~"open", nofin),
        Req
    end;
send_fun(stream_trailers) ->
    fun(Req) ->
        {ok, Send} = roadrunner_send:stream(200, [{~"trailer", ~"x-sum"}], Req),
        ok = Send(~"body", {fin, [{~"x-sum", ~"1"}]}),
        Req
    end;
send_fun({sendfile, File}) ->
    fun(Req) ->
        Headers = [{~"content-type", ~"text/plain"}, {~"content-length", ~"4"}],
        ok = roadrunner_send:file(200, Headers, {File, 2, 4}, Req),
        Req
    end;
send_fun(nothing) ->
    fun(Req) -> Req end;
send_fun(crash_before) ->
    fun(_Req) -> error(boom) end;
send_fun(crash_after) ->
    fun(Req) ->
        ok = roadrunner_send:reply(200, [], ~"sent", Req),
        error(boom)
    end;
send_fun(crash_open) ->
    fun(Req) ->
        {ok, Send} = roadrunner_send:stream(200, [], Req),
        ok = Send(~"partial", nofin),
        error(boom)
    end;
send_fun({report, Pid, twice}) ->
    fun(Req) ->
        ok = roadrunner_send:reply(200, [], ~"first", Req),
        Pid ! {send_result, raised(fun() -> roadrunner_send:reply(200, [], ~"x", Req) end)},
        Pid ! {send_result, raised(fun() -> roadrunner_send:inform(103, [], Req) end)},
        Req
    end;
send_fun({report, Pid, unsafe_inform}) ->
    fun(Req) ->
        Pid ! {send_result, roadrunner_send:inform(103, [{~"x-bad", ~"a\r\nb"}], Req)},
        ok = roadrunner_send:reply(200, [], ~"ok", Req),
        Req
    end;
send_fun({report, Pid, unsafe_reply}) ->
    fun(Req) ->
        Pid ! {send_result, roadrunner_send:reply(200, [{~"x-bad", ~"a\r\nb"}], ~"", Req)},
        Req
    end;
send_fun({report, Pid, big_inform}) ->
    fun(Req) ->
        Pid ! {send_result, roadrunner_send:inform(103, big_header(), Req)},
        ok = roadrunner_send:reply(200, [], ~"ok", Req),
        Req
    end;
send_fun({report, Pid, until_reset}) ->
    fun(Req) ->
        {ok, Send} = roadrunner_send:stream(200, [], Req),
        ok = Send(~"first", nofin),
        Pid ! {send_result, streaming},
        ok = send_until_error(Send),
        Req
    end;
send_fun({report, Pid, upgrade}) ->
    fun(Req) ->
        Pid !
            {send_result,
                roadrunner_send:websocket(roadrunner_ws_echo_handler, no_state, #{}, Req)},
        Req
    end;
send_fun({report, Pid, {file, Spec}}) ->
    fun(Req) ->
        Headers = [{~"content-type", ~"text/plain"}, {~"content-length", ~"4"}],
        Pid ! {send_result, roadrunner_send:file(200, Headers, Spec, Req)},
        Req
    end;
send_fun({report, Pid, reply_then_read}) ->
    fun(Req0) ->
        ok = roadrunner_send:reply(200, [], ~"early", Req0),
        {ok, Body, Req} = roadrunner_req:read_body(Req0),
        Pid ! {send_result, Body},
        Req
    end;
send_fun({report, Pid, read_then_reply}) ->
    %% The reply takes the request from before the read, whose continue is
    %% already sent.
    fun(Req0) ->
        {ok, Body, Req} = roadrunner_req:read_body(Req0),
        Pid ! {send_result, Body},
        ok = roadrunner_send:reply(200, [], ~"late", Req0),
        Req
    end;
send_fun({report, Pid, big_reply}) ->
    fun(Req) ->
        Pid ! {send_result, roadrunner_send:reply(200, big_header(), ~"ok", Req)},
        Req
    end;
send_fun({report, Pid, {big_file, File}}) ->
    fun(Req) ->
        Headers = [{~"content-length", ~"4"} | big_header()],
        Pid ! {send_result, roadrunner_send:file(200, Headers, {File, 2, 4}, Req)},
        Req
    end;
send_fun({report, Pid, big_stream}) ->
    fun(Req) ->
        Pid ! {send_result, roadrunner_send:stream(200, big_header(), Req)},
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
