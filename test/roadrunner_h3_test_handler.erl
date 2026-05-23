-module(roadrunner_h3_test_handler).
-moduledoc """
Test fixture for `roadrunner_http3_SUITE` — dispatches on `:path` so a
single h3 listener can drive every response shape. Responses carry
only h3-legal headers (no `connection` / `keep-alive`, which RFC 9114
§4.2 forbids and the QUIC client rejects).
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) ->
    {roadrunner_handler:response(), roadrunner_req:request()}.
handle(#{target := ~"/echo"} = Req) ->
    {{200, [{~"content-type", ~"text/plain"}], roadrunner_req:body(Req)}, Req};
handle(#{target := ~"/method"} = Req) ->
    {{200, [{~"content-type", ~"text/plain"}], roadrunner_req:method(Req)}, Req};
handle(#{target := ~"/empty"} = Req) ->
    {{204, [], ~""}, Req};
handle(#{target := ~"/big"} = Req) ->
    {{200, [{~"content-type", ~"application/octet-stream"}], binary:copy(<<"x">>, 100_000)}, Req};
handle(#{target := ~"/slow"} = Req) ->
    %% Sleeps so a test can cancel the stream before the worker sends,
    %% exercising the response path's tolerance of a gone stream.
    timer:sleep(100),
    {{200, [], ~"slow"}, Req};
handle(#{target := <<"/forbidden/", Name/binary>>} = Req) ->
    %% Emits a connection-specific response header (named by the path),
    %% which RFC 9114 §4.2 forbids over h3.
    {{200, [{Name, ~"x"}], ~"x"}, Req};
handle(#{target := ~"/crash"} = _Req) ->
    error(boom);
handle(#{target := ~"/badheaders"} = Req) ->
    %% Headers must be a `[{Name, Value}]` list; a non-list crashes the
    %% worker inside `send_buffered/5` (QPACK encode), so the conn loop
    %% resets the stream on the worker's abnormal `'DOWN'`.
    {{200, not_a_list, ~"x"}, Req};
handle(#{target := ~"/stream"} = Req) ->
    %% Empty `nofin` is a no-op; two real chunks then `fin`.
    {
        {stream, 200, [], fun(Send) ->
            ok = Send(<<>>, nofin),
            ok = Send(~"chunk1-", nofin),
            ok = Send(~"chunk2", fin)
        end},
        Req
    };
handle(#{target := ~"/stream-trailers"} = Req) ->
    {{stream, 200, [], fun(Send) -> ok = Send(~"body", {fin, [{~"x-trailer", ~"v"}]}) end}, Req};
handle(#{target := ~"/stream-noend"} = Req) ->
    %% Returns without a `fin` — the framework auto-closes the stream.
    {{stream, 200, [], fun(Send) -> ok = Send(~"data", nofin) end}, Req};
handle(#{target := ~"/stream-forbidden"} = Req) ->
    %% A connection-specific header on a stream response → 500.
    {{stream, 200, [{~"connection", ~"close"}], fun(Send) -> ok = Send(~"x", fin) end}, Req};
handle(#{target := ~"/loop"} = Req) ->
    {{loop, 200, [], 0}, Req};
handle(#{target := ~"/sendfile"} = Req) ->
    {{sendfile, 200, [], {"/dev/null", 0, 0}}, Req};
handle(#{target := ~"/websocket"} = Req) ->
    {{websocket, some_module, state}, Req};
handle(Req) ->
    {{200, [{~"content-type", ~"text/plain"}], ~"ok"}, Req}.
