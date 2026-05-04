-module(roadrunner_h2_test_handler).
-moduledoc """
Test fixture for `roadrunner_conn_loop_http2_tests` — dispatches
based on `:path` so a single h2 listener can drive every response
shape.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) ->
    {roadrunner_handler:response(), roadrunner_http1:request()}.
handle(#{target := ~"/empty"} = Req) ->
    {{200, [], ~""}, Req};
handle(#{target := ~"/stream"} = Req) ->
    {
        {stream, 200, [{~"content-type", ~"text/plain"}], fun(Send) ->
            Send(~"hello ", nofin),
            Send(~"world", fin)
        end},
        Req
    };
handle(#{target := ~"/stream/empty"} = Req) ->
    {{stream, 200, [], fun(_Send) -> ok end}, Req};
handle(#{target := ~"/stream/empty-fin"} = Req) ->
    {{stream, 200, [], fun(Send) -> Send(~"", fin) end}, Req};
handle(#{target := ~"/stream/trailers"} = Req) ->
    {
        {stream, 200, [{~"trailer", ~"x-checksum"}], fun(Send) ->
            Send(~"hi", {fin, [{~"x-checksum", ~"deadbeef"}]})
        end},
        Req
    };
handle(#{target := ~"/stream/trailers-only"} = Req) ->
    {
        {stream, 200, [{~"trailer", ~"x-checksum"}], fun(Send) ->
            Send(~"", {fin, [{~"x-checksum", ~"none"}]})
        end},
        Req
    };
handle(#{target := ~"/stream/many"} = Req) ->
    {
        {stream, 200, [], fun(Send) ->
            Send(~"a", nofin),
            Send(~"", nofin),
            Send(~"b", nofin),
            Send(~"c", fin)
        end},
        Req
    };
handle(#{target := ~"/stream/slow"} = Req) ->
    %% Pauses between emissions so a test can race a peer RST in.
    %% The Send call after the sleep should return via
    %% `{h2_stream_reset, _}` (worker's `sync/2` exit branch).
    {
        {stream, 200, [], fun(Send) ->
            Send(~"a", nofin),
            timer:sleep(200),
            Send(~"b", fin)
        end},
        Req
    };
handle(#{target := ~"/stream/large"} = Req) ->
    %% 100 KiB across two emissions — triggers flow-control
    %% blocking when send window is artificially shrunk.
    {
        {stream, 200, [], fun(Send) ->
            Send(binary:copy(<<"x">>, 60_000), nofin),
            Send(binary:copy(<<"x">>, 40_000), fin)
        end},
        Req
    };
handle(#{target := ~"/loop"} = Req) ->
    {{loop, 200, [], state}, Req};
handle(#{target := ~"/sendfile"} = Req) ->
    {{sendfile, 200, [], {"/dev/null", 0, 0}}, Req};
handle(#{target := ~"/websocket"} = Req) ->
    {{websocket, some_module, state}, Req};
handle(#{target := ~"/crash"} = _Req) ->
    error(boom);
handle(#{target := ~"/badshape"} = Req) ->
    %% Returns a malformed `{stream, ...}` response — the worker's
    %% `emit_handler_response/3` clauses won't match (the trailing
    %% element isn't a function), so the worker exits with a
    %% function_clause error and the conn aborts the stream with
    %% RST_STREAM(INTERNAL_ERROR).
    {{stream, 200, [], not_a_function}, Req};
handle(#{target := ~"/large50k"} = Req) ->
    {{200, [], binary:copy(<<"x">>, 50_000)}, Req};
handle(#{target := ~"/large100k"} = Req) ->
    {{200, [], binary:copy(<<"x">>, 100_000)}, Req};
handle(Req) ->
    {{200, [{~"content-type", ~"text/plain"}], ~"ok"}, Req}.
