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
    %% Empty-length: file is opened but never read. Exercises the
    %% sendfile_loop/3 base case (`Send(<<>>, fin)`).
    {{sendfile, 200, [], {"/dev/null", 0, 0}}, Req};
handle(#{target := ~"/sendfile/small"} = Req) ->
    %% 100-byte body, single DATA frame with END_STREAM.
    {{sendfile, 200, [], {"/tmp/rr_h2_sf_small.bin", 0, 100}}, Req};
handle(#{target := ~"/sendfile/multi"} = Req) ->
    %% 40000-byte body, splits into 3 DATA frames (16384 + 16384 + 7232).
    {{sendfile, 200, [], {"/tmp/rr_h2_sf_multi.bin", 0, 40000}}, Req};
handle(#{target := ~"/sendfile/window"} = Req) ->
    %% Offset + Length: serve bytes [200, 700) from a 1000-byte file.
    {{sendfile, 200, [], {"/tmp/rr_h2_sf_window.bin", 200, 500}}, Req};
handle(#{target := ~"/sendfile/missing"} = Req) ->
    %% File-open failure: worker crashes, conn RST_STREAMs.
    {{sendfile, 200, [], {"/tmp/rr_h2_sf_does_not_exist.bin", 0, 100}}, Req};
handle(#{target := ~"/sendfile/large"} = Req) ->
    %% 100 KB body via sendfile — exceeds the default 65535-byte
    %% conn-level window, so the server stalls and resumes after
    %% WINDOW_UPDATE. Used by the flow-control SUITE to verify
    %% sendfile-over-h2 reuses the streaming backpressure path.
    {{sendfile, 200, [], {"/tmp/rr_h2_sf_large.bin", 0, 100_000}}, Req};
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
handle(#{target := ~"/compressible"} = Req) ->
    %% A response large enough to clear the compress threshold and
    %% with an obvious repeating pattern so a gzip-compressed body
    %% is significantly smaller than the original.
    Body = binary:copy(<<"hello world! ">>, 1000),
    {{200, [{~"content-type", ~"text/plain"}], Body}, Req};
handle(#{target := ~"/large50k"} = Req) ->
    {{200, [], binary:copy(<<"x">>, 50_000)}, Req};
handle(#{target := ~"/large100k"} = Req) ->
    {{200, [], binary:copy(<<"x">>, 100_000)}, Req};
handle(Req) ->
    {{200, [{~"content-type", ~"text/plain"}], ~"ok"}, Req}.
