-module(roadrunner_body_drain_tests).
-moduledoc false.

%% Draining an unread HTTP/1.1 body, and reading a chunked one a piece at a
%% time, hold a bounded amount of it whatever its size or cap: each case
%% feeds a body of 2000 pieces of 16 KB (about 32 MB) and, partway through,
%% counts the bytes of the binaries the reading process still references
%% after a collection.

-include_lib("eunit/include/eunit.hrl").

-define(PIECE, 16384).
-define(PIECES, 2000).
-define(CHECK_AT, 1500).
-define(BOUND, 1048576).

drain_sized_body_without_a_cap_test() ->
    Size = ?PIECE * ?PIECES,
    ?assert(held(fun drain/1, {content_length, Size}, infinity, fun(_) -> data() end) < ?BOUND).

drain_sized_body_under_a_cap_test() ->
    Size = ?PIECE * ?PIECES,
    ?assert(held(fun drain/1, {content_length, Size}, Size, fun(_) -> data() end) < ?BOUND).

%% One chunk declared far larger than the body that arrives.
drain_huge_chunk_without_a_cap_test() ->
    ?assert(held(fun drain/1, chunked, infinity, huge_chunk()) < ?BOUND).

drain_chunks_under_a_cap_test() ->
    ?assert(held(fun drain/1, chunked, ?PIECE * ?PIECES, fun(_) -> chunk() end) < ?BOUND).

%% Reading a huge chunk chunk by chunk hands it back as it arrives.
next_chunk_of_a_huge_chunk_test() ->
    ?assert(held(fun next_chunks/1, chunked, infinity, huge_chunk()) < ?BOUND).

%% A length-bounded read of a huge chunk holds no more than it asked for.
length_reads_of_a_huge_chunk_test() ->
    ?assert(held(fun length_reads/1, chunked, infinity, huge_chunk()) < ?BOUND).

%% A chunk over 64 KB is taken in parts as it arrives and still ends on
%% its CRLF, and what follows the body is left for the next request; one
%% up to 64 KB comes whole.
parts_keep_the_framing_test() ->
    A = binary:copy(~"a", 40_000),
    B = binary:copy(~"b", 30_000),
    Pieces = [<<"11170\r\n", A/binary>>, B, ~"\r\n3\r\nab", ~"c\r\n0\r\n\r\nNEXT"],
    Next = fun(N) -> lists:nth(N, Pieces) end,
    {more, A, R1} = roadrunner_conn:consume_body_reader(
        reader(chunked, infinity, Next, 4), next_chunk
    ),
    {more, B, R2} = roadrunner_conn:consume_body_reader(R1, next_chunk),
    {more, ~"abc", R3} = roadrunner_conn:consume_body_reader(R2, next_chunk),
    ?assertMatch(
        {ok, <<>>, #{buffered := ~"NEXT"}}, roadrunner_conn:consume_body_reader(R3, next_chunk)
    ),
    {ok, All, _} = roadrunner_conn:consume_body_reader(reader(chunked, infinity, Next, 4), all),
    ?assertEqual(<<A/binary, B/binary, "abc">>, iolist_to_binary(All)),
    ?assertEqual({ok, ~"NEXT"}, roadrunner_conn:drain_reader(reader(chunked, infinity, Next, 4))),
    %% A part's bytes count against a finite cap like a whole chunk's.
    ?assertEqual(
        {error, content_length_too_large},
        roadrunner_conn:drain_reader(reader(chunked, 70_002, Next, 4))
    ),
    %% A size line with no data yet.
    Late = [~"11170\r\n", <<A/binary, B/binary, "\r\n0\r\n\r\n">>],
    {more, AB, _} = roadrunner_conn:consume_body_reader(
        reader(chunked, infinity, fun(N) -> lists:nth(N, Late) end, 2), next_chunk
    ),
    ?assertEqual(<<A/binary, B/binary>>, AB),
    ?assertEqual(
        {ok, <<>>},
        roadrunner_conn:drain_reader(reader(chunked, infinity, fun(N) -> lists:nth(N, Late) end, 2))
    ),
    %% A large chunk whose data does not end on a CRLF is malformed.
    Bad = [<<"11170\r\n", A/binary>>, <<B/binary, "XY">>],
    ?assertEqual(
        {error, bad_chunk},
        roadrunner_conn:drain_reader(reader(chunked, infinity, fun(N) -> lists:nth(N, Bad) end, 2))
    ).

%% --- helpers ---

drain(Reader) ->
    roadrunner_conn:drain_reader(Reader).

next_chunks(Reader) ->
    case roadrunner_conn:consume_body_reader(Reader, next_chunk) of
        {more, _Data, Reader1} -> next_chunks(Reader1);
        Other -> Other
    end.

length_reads(Reader) ->
    case roadrunner_conn:consume_body_reader(Reader, {length, 65536}) of
        {more, _Data, Reader1} -> length_reads(Reader1);
        Other -> Other
    end.

%% Run `Read` on a reader of `Framing` and `Max` in a process of its own
%% whose recv hands out the body's pieces, and return the most it held.
held(Read, Framing, Max, Piece) ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        _ = Read(reader(Framing, Max, Piece, ?PIECES)),
        Parent ! {self(), get(held)}
    end),
    receive
        {Pid, Held} ->
            receive
                {'DOWN', Ref, process, Pid, _} -> Held
            end;
        {'DOWN', Ref, process, Pid, Reason} ->
            error({reader_died, Reason})
    end.

reader(Framing, Max, Piece, Pieces) ->
    #{
        framing => Framing,
        buffered => <<>>,
        bytes_read => 0,
        pending => <<>>,
        done => false,
        deadline => infinity,
        request_deadline => infinity,
        id => make_ref(),
        recv => recv(Piece, Pieces),
        max => Max,
        trailer_limits => {8192, 10240, 100},
        chunk_left => 0
    }.

%% Piece by piece, a fresh binary each, then the connection closes. At
%% `?CHECK_AT` it counts what the process holds.
recv(Piece, Pieces) ->
    Key = {piece, make_ref()},
    fun(_Deadline) ->
        N =
            case get(Key) of
                undefined -> 1;
                Last -> Last + 1
            end,
        _ = put(Key, N),
        _ =
            case N of
                ?CHECK_AT -> put(held, live_binary());
                _ -> ok
            end,
        case N =< Pieces of
            true -> {ok, Piece(N)};
            false -> {error, closed}
        end
    end.

data() ->
    binary:copy(<<$x>>, ?PIECE).

chunk() ->
    <<"4000\r\n", (binary:copy(<<$x>>, ?PIECE))/binary, "\r\n">>.

huge_chunk() ->
    fun
        (1) -> <<"FFFFFFFFFF\r\n", (data())/binary>>;
        (_) -> data()
    end.

%% The bytes of the off-heap binaries this process still references.
live_binary() ->
    true = erlang:garbage_collect(),
    {binary, Binaries} = process_info(self(), binary),
    lists:sum([Size || {_, Size, _} <- Binaries]).
