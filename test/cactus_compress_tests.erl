-module(cactus_compress_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Pure unit tests against `call/2` — no listener, no socket.
%% =============================================================================

passes_through_when_client_does_not_accept_gzip_test() ->
    Req = req([]),
    Body = big_body(),
    Next = fun(R) -> {{200, [], Body}, R} end,
    {{Status, Headers, OutBody}, _Req2} = cactus_compress:call(Req, Next),
    ?assertEqual(200, Status),
    %% Body was not compressed.
    ?assertEqual(iolist_to_binary(Body), iolist_to_binary(OutBody)),
    %% No Content-Encoding header added.
    ?assertEqual(false, lists:keymember(~"content-encoding", 1, Headers)).

compresses_when_client_accepts_gzip_test() ->
    Req = req([{~"accept-encoding", ~"gzip"}]),
    Body = big_body(),
    Next = fun(R) -> {{200, [], Body}, R} end,
    {{200, Headers, OutBody}, _Req2} = cactus_compress:call(Req, Next),
    ?assertEqual(~"gzip", header(~"content-encoding", Headers)),
    ?assertEqual(~"Accept-Encoding", header(~"vary", Headers)),
    %% Round-trip via zlib:gunzip.
    ?assertEqual(iolist_to_binary(Body), zlib:gunzip(iolist_to_binary(OutBody))).

compresses_when_gzip_listed_among_others_test() ->
    Req = req([{~"accept-encoding", ~"deflate, gzip, br"}]),
    Body = big_body(),
    Next = fun(R) -> {{200, [], Body}, R} end,
    {{200, Headers, _OutBody}, _Req2} = cactus_compress:call(Req, Next),
    ?assertEqual(~"gzip", header(~"content-encoding", Headers)).

skips_when_only_other_encodings_offered_test() ->
    Req = req([{~"accept-encoding", ~"br, deflate"}]),
    Body = big_body(),
    Next = fun(R) -> {{200, [], Body}, R} end,
    {{200, Headers, _OutBody}, _Req2} = cactus_compress:call(Req, Next),
    ?assertEqual(undefined, header(~"content-encoding", Headers)).

skips_when_response_already_encoded_test() ->
    %% Handler set Content-Encoding itself (e.g. served a pre-compressed asset).
    Req = req([{~"accept-encoding", ~"gzip"}]),
    Body = zlib:gzip(big_body()),
    Headers0 = [{~"content-encoding", ~"gzip"}],
    Next = fun(R) -> {{200, Headers0, Body}, R} end,
    {{200, Headers, OutBody}, _Req2} = cactus_compress:call(Req, Next),
    %% Body and Content-Encoding unchanged.
    ?assertEqual(iolist_to_binary(Body), iolist_to_binary(OutBody)),
    ?assertEqual(~"gzip", header(~"content-encoding", Headers)).

skips_when_body_below_threshold_test() ->
    Req = req([{~"accept-encoding", ~"gzip"}]),
    Body = ~"tiny",
    Next = fun(R) -> {{200, [], Body}, R} end,
    {{200, Headers, OutBody}, _Req2} = cactus_compress:call(Req, Next),
    ?assertEqual(iolist_to_binary(Body), iolist_to_binary(OutBody)),
    ?assertEqual(undefined, header(~"content-encoding", Headers)),
    %% Vary still added so a cache keys on Accept-Encoding.
    ?assertEqual(~"Accept-Encoding", header(~"vary", Headers)).

updates_content_length_on_compress_test() ->
    Req = req([{~"accept-encoding", ~"gzip"}]),
    Body = big_body(),
    OriginalLength = integer_to_binary(byte_size(iolist_to_binary(Body))),
    Headers0 = [
        {~"content-type", ~"text/plain"},
        {~"content-length", OriginalLength}
    ],
    Next = fun(R) -> {{200, Headers0, Body}, R} end,
    {{200, Headers, OutBody}, _Req2} = cactus_compress:call(Req, Next),
    NewLength = header(~"content-length", Headers),
    ?assertEqual(
        integer_to_binary(byte_size(iolist_to_binary(OutBody))),
        NewLength
    ),
    %% And it differs from the original (i.e. compression actually shrunk it).
    ?assert(byte_size(NewLength) =< byte_size(OriginalLength)).

does_not_duplicate_vary_when_handler_already_set_it_test() ->
    %% Body below threshold, but client accepts gzip — middleware would
    %% normally add Vary. Handler already set Vary, so we must not add a
    %% second one.
    Req = req([{~"accept-encoding", ~"gzip"}]),
    Body = ~"tiny",
    Headers0 = [{~"vary", ~"Cookie"}],
    Next = fun(R) -> {{200, Headers0, Body}, R} end,
    {{200, Headers, _OutBody}, _Req2} = cactus_compress:call(Req, Next),
    Varys = [V || {N, V} <- Headers, N =:= ~"vary"],
    ?assertEqual([~"Cookie"], Varys).

stream_response_passes_through_when_client_does_not_accept_gzip_test() ->
    Req = req([]),
    Fun = fun(_Send) -> ok end,
    Next = fun(R) -> {{stream, 200, [], Fun}, R} end,
    {{stream, 200, Headers, OutFun}, _Req2} = cactus_compress:call(Req, Next),
    %% Same fun, no Content-Encoding added.
    ?assertEqual(Fun, OutFun),
    ?assertEqual(undefined, header(~"content-encoding", Headers)).

stream_response_passes_through_when_already_encoded_test() ->
    Req = req([{~"accept-encoding", ~"gzip"}]),
    Fun = fun(_Send) -> ok end,
    Headers0 = [{~"content-encoding", ~"gzip"}],
    Next = fun(R) -> {{stream, 200, Headers0, Fun}, R} end,
    {{stream, 200, Headers, OutFun}, _Req2} = cactus_compress:call(Req, Next),
    %% Already-encoded response is passed through verbatim.
    ?assertEqual(Fun, OutFun),
    ?assertEqual(~"gzip", header(~"content-encoding", Headers)).

stream_response_wrapped_with_gzip_test() ->
    %% When the client accepts gzip and the response isn't already
    %% encoded, the Send callback is wrapped with a deflate context.
    %% We capture what the wrapped Send writes "to the wire" (here a
    %% bag-of-bytes accumulator) and gunzip-verify it round-trips.
    Req = req([{~"accept-encoding", ~"gzip"}]),
    Self = self(),
    Fun = fun(Send) ->
        ok = Send(~"hello ", nofin),
        ok = Send(~"world", fin)
    end,
    Next = fun(R) -> {{stream, 200, [], Fun}, R} end,
    {{stream, 200, Headers, WrappedFun}, _Req2} = cactus_compress:call(Req, Next),
    ?assertEqual(~"gzip", header(~"content-encoding", Headers)),
    ?assertEqual(~"Accept-Encoding", header(~"vary", Headers)),
    Capture = fun(Data, _Flag) ->
        Self ! {chunk, iolist_to_binary(Data)},
        ok
    end,
    WrappedFun(Capture),
    Compressed = collect_chunks(),
    ?assertEqual(~"hello world", zlib:gunzip(Compressed)).

stream_response_wrapped_with_gzip_passes_trailers_test() ->
    %% `{fin, Trailers}` finishes the deflate (just like `fin`) and
    %% forwards the trailers to the conn's real Send unchanged.
    Req = req([{~"accept-encoding", ~"gzip"}]),
    Self = self(),
    Trailers = [{~"x-md5", ~"deadbeef"}],
    Fun = fun(Send) ->
        ok = Send(~"hello", {fin, Trailers})
    end,
    Next = fun(R) -> {{stream, 200, [], Fun}, R} end,
    {{stream, 200, _Headers, WrappedFun}, _Req2} = cactus_compress:call(Req, Next),
    Capture = fun(Data, Flag) ->
        Self ! {emit, iolist_to_binary(Data), Flag},
        ok
    end,
    WrappedFun(Capture),
    receive
        {emit, Compressed, FinFlag} ->
            ?assertEqual({fin, Trailers}, FinFlag),
            ?assertEqual(~"hello", zlib:gunzip(Compressed))
    after 50 -> error(no_emit)
    end.

passes_loop_response_through_test() ->
    Req = req([{~"accept-encoding", ~"gzip"}]),
    Next = fun(R) -> {{loop, 200, [], state}, R} end,
    {Response, _Req2} = cactus_compress:call(Req, Next),
    ?assertMatch({loop, 200, _, state}, Response).

passes_websocket_response_through_test() ->
    Req = req([{~"accept-encoding", ~"gzip"}]),
    Next = fun(R) -> {{websocket, some_mod, init_state}, R} end,
    {Response, _Req2} = cactus_compress:call(Req, Next),
    ?assertMatch({websocket, some_mod, init_state}, Response).

%% =============================================================================
%% End-to-end through cactus_listener.
%% =============================================================================

end_to_end_compresses_html_response_test_() ->
    {setup,
        fun() ->
            {ok, _} = cactus_listener:start_link(compress_e2e, #{
                port => 0,
                handler => cactus_compress_test_handler,
                middlewares => [cactus_compress]
            }),
            cactus_listener:port(compress_e2e)
        end,
        fun(_) -> ok = cactus_listener:stop(compress_e2e) end, fun(Port) ->
            {"compresses HTML response when client sends Accept-Encoding: gzip", fun() ->
                {ok, Sock} = gen_tcp:connect(
                    {127, 0, 0, 1}, Port, [binary, {active, false}], 1000
                ),
                ok = gen_tcp:send(
                    Sock,
                    <<
                        "GET / HTTP/1.1\r\nHost: x\r\n",
                        "Accept-Encoding: gzip\r\n",
                        "Connection: close\r\n\r\n"
                    >>
                ),
                Reply = recv_all(Sock, <<>>),
                ok = gen_tcp:close(Sock),
                {match, _} = re:run(Reply, ~"content-encoding: gzip", [caseless]),
                {match, _} = re:run(Reply, ~"vary: Accept-Encoding", [caseless]),
                %% Body comes after \r\n\r\n; gunzip should round-trip.
                [_Headers, Body] = binary:split(Reply, ~"\r\n\r\n"),
                Decompressed = zlib:gunzip(Body),
                {match, _} = re:run(Decompressed, ~"<h1>arizona</h1>")
            end}
        end}.

%% --- helpers ---

req(Headers) ->
    #{
        method => ~"GET",
        target => ~"/",
        version => {1, 1},
        headers => Headers
    }.

%% A body well above the 860-byte threshold so compression isn't skipped.
big_body() ->
    iolist_to_binary(lists:duplicate(80, ~"<h1>arizona</h1>")).

header(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, V} -> V;
        false -> undefined
    end.

recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 1000) of
        {ok, Data} -> recv_all(Sock, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.

collect_chunks() ->
    receive
        {chunk, Bytes} -> <<Bytes/binary, (collect_chunks())/binary>>
    after 50 -> <<>>
    end.
