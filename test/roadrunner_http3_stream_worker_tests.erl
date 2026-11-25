-module(roadrunner_http3_stream_worker_tests).

-include_lib("eunit/include/eunit.hrl").

%% sendfile_loop stops reading and sending the moment a chunk fails (the stream
%% was reset / the connection closed), rather than looping over the rest of the
%% file — which, on a dead stream under backpressure, would buffer the whole file
%% onto a send buffer that can never drain.
sendfile_loop_stops_on_send_error_test() ->
    Path = "/tmp/rr_sendfile_loop_stop_test.bin",
    %% Larger than ?SENDFILE_CHUNK_SIZE (64 KiB) so the loop takes the multi-chunk
    %% (nofin) path where the stop-on-error branch lives.
    ok = file:write_file(Path, binary:copy(~"x", 200000)),
    {ok, IoDev} = file:open(Path, [read, raw, binary]),
    Self = self(),
    Tag = make_ref(),
    Send = fun(Data, nofin) ->
        Self ! {sent, Tag, byte_size(Data)},
        {error, closed}
    end,
    try
        ?assertEqual(ok, roadrunner_http3_stream_worker:sendfile_loop(IoDev, 200000, Send))
    after
        _ = file:close(IoDev),
        _ = file:delete(Path)
    end,
    %% Exactly one chunk was attempted; the {error, closed} stopped the loop
    %% before reading or sending the rest of the file.
    ?assertEqual(1, count_sent(Tag, 0)).

%% A successful loop sends every chunk and finishes with the FIN.
sendfile_loop_sends_all_chunks_on_success_test() ->
    Path = "/tmp/rr_sendfile_loop_ok_test.bin",
    ok = file:write_file(Path, binary:copy(~"x", 200000)),
    {ok, IoDev} = file:open(Path, [read, raw, binary]),
    Self = self(),
    Tag = make_ref(),
    Send = fun(Data, Flag) ->
        Self ! {sent, Tag, byte_size(Data), Flag},
        ok
    end,
    try
        ?assertEqual(ok, roadrunner_http3_stream_worker:sendfile_loop(IoDev, 200000, Send))
    after
        _ = file:close(IoDev),
        _ = file:delete(Path)
    end,
    Sends = collect_sends(Tag, []),
    %% 200000 / 65536 = 3 full chunks + a 3392-byte remainder carrying the FIN.
    ?assertEqual(200000, lists:sum([Size || {Size, _Flag} <- Sends])),
    ?assertEqual([fin], [Flag || {_Size, Flag} <- Sends, Flag =:= fin]).

%% Each test tags its sends with its own reference, so a `sent` message left
%% in the test process's mailbox by another eunit module is never counted.
count_sent(Tag, N) ->
    receive
        {sent, Tag, _} -> count_sent(Tag, N + 1)
    after 0 -> N
    end.

collect_sends(Tag, Acc) ->
    receive
        {sent, Tag, Size, Flag} -> collect_sends(Tag, [{Size, Flag} | Acc])
    after 0 -> lists:reverse(Acc)
    end.
