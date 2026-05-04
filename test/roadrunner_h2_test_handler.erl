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
    {{stream, 200, [], fun(_Send) -> ok end}, Req};
handle(#{target := ~"/loop"} = Req) ->
    {{loop, 200, [], state}, Req};
handle(#{target := ~"/sendfile"} = Req) ->
    {{sendfile, 200, [], {"/dev/null", 0, 0}}, Req};
handle(#{target := ~"/websocket"} = Req) ->
    {{websocket, some_module, state}, Req};
handle(#{target := ~"/crash"} = _Req) ->
    error(boom);
handle(#{target := ~"/large50k"} = Req) ->
    {{200, [], binary:copy(<<"x">>, 50_000)}, Req};
handle(#{target := ~"/large100k"} = Req) ->
    {{200, [], binary:copy(<<"x">>, 100_000)}, Req};
handle(Req) ->
    {{200, [{~"content-type", ~"text/plain"}], ~"ok"}, Req}.
