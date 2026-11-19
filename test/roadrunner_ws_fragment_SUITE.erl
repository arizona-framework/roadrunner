-module(roadrunner_ws_fragment_SUITE).
-moduledoc """
Fragmented WebSocket messages over a real socket: a message reassembled
from many frames is delivered intact (plain and permessage-deflate), and
a fragment flood that never ends its message is closed with 1009 while
the session holds about as much memory as the bytes it has buffered.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    small_fragments_echo_intact/1,
    large_fragmented_message_echoes_intact/1,
    compressed_fragmented_message_echoes_intact/1,
    large_corrupt_compressed_frame_closes/1,
    fragment_flood_memory_tracks_buffered_bytes/1
]).

-define(H, roadrunner_ws_opts_handler).
-define(MAX_MESSAGE, 8_388_608).
-define(MAX_FRAME, 1_048_576).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        small_fragments_echo_intact,
        large_fragmented_message_echoes_intact,
        compressed_fragmented_message_echoes_intact,
        large_corrupt_compressed_frame_closes,
        fragment_flood_memory_tracks_buffered_bytes
    ].

init_per_testcase(Case, Config) ->
    {ok, _} = roadrunner_listener:start_link(?MODULE, #{
        port => 0,
        ws => maps:merge(
            #{max_message_size => ?MAX_MESSAGE, max_frame_size => ?MAX_FRAME}, ws(Case)
        ),
        routes => [{~"/ws", ?H, #{report => self(), opts => #{}}}]
    }),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_listener:stop(?MODULE).

ws(Case) when
    Case =:= compressed_fragmented_message_echoes_intact;
    Case =:= large_corrupt_compressed_frame_closes
->
    #{compress => true};
ws(_Case) ->
    #{}.

%% =============================================================================
%% Delivery
%% =============================================================================

small_fragments_echo_intact(Config) ->
    %% A multi-byte character split across the fragment boundaries, and a
    %% ping between fragments.
    {Sock, _Pid} = upgrade(Config, []),
    ok = gen_tcp:send(Sock, [
        masked(16#01, ~"héllo "),
        masked(16#00, <<"w", 16#E2, 16#82>>),
        masked(16#89, ~"p"),
        masked(16#00, <<16#AC, "rld">>),
        masked(16#80, ~"!")
    ]),
    ?assertEqual({pong, ~"p"}, recv_message(Sock)),
    ?assertEqual({text, ~"héllo w€rld!"}, recv_message(Sock)).

large_fragmented_message_echoes_intact(Config) ->
    %% Over a megabyte in fragments of uneven sizes, some above and some
    %% far below the reassembly chunk size.
    {Sock, _Pid} = upgrade(Config, []),
    Message = message(1_500_000),
    ok = gen_tcp:send(Sock, fragments(Message, [7, 65_536, 300_000, 1, 4_096, 700_001])),
    ?assertEqual({text, Message}, recv_message(Sock)),
    %% The session takes a second message the same way.
    ok = gen_tcp:send(Sock, fragments(~"again", [2])),
    ?assertEqual({text, ~"again"}, recv_message(Sock)).

compressed_fragmented_message_echoes_intact(Config) ->
    {Sock, _Pid} = upgrade(Config, [~"Sec-WebSocket-Extensions: permessage-deflate\r\n"]),
    Message = message(800_000),
    Z = zlib:open(),
    ok = zlib:deflateInit(Z, default, deflated, -15, 8, default),
    Deflated = iolist_to_binary(zlib:deflate(Z, Message, sync)),
    ok = zlib:close(Z),
    Compressed = binary:part(Deflated, 0, byte_size(Deflated) - 4),
    [First | Rest] = fragments(Compressed, [3, 1_000, 50_000]),
    %% RSV1 on the first frame marks the whole message compressed.
    <<Op, FirstRest/binary>> = iolist_to_binary(First),
    ok = gen_tcp:send(Sock, [<<(Op bor 16#40), FirstRest/binary>> | Rest]),
    ?assertEqual({text, Message}, recv_message(Sock)).

large_corrupt_compressed_frame_closes(Config) ->
    %% One compressed frame over 64 KB whose payload is not a deflate
    %% stream (0xFF opens a block of the reserved type).
    {Sock, _Pid} = upgrade(Config, [~"Sec-WebSocket-Extensions: permessage-deflate\r\n"]),
    <<Op, Rest/binary>> = masked(16#81, binary:copy(<<16#FF>>, 70_000)),
    ok = gen_tcp:send(Sock, <<(Op bor 16#40), Rest/binary>>),
    ?assertEqual({close, <<1002:16>>}, recv_message(Sock)),
    ?assertEqual({terminated, {error, protocol_error}}, terminated()).

%% =============================================================================
%% Fragment flood
%% =============================================================================

fragment_flood_memory_tracks_buffered_bytes(Config) ->
    %% Small fragments that never end the message, filled to just under
    %% `max_message_size`. A ping afterwards marks the point where the
    %% session has taken every fragment: it answers in order.
    {Sock, Pid} = upgrade(Config, []),
    Size = 256,
    Fragment = masked(16#00, binary:copy(~"A", Size)),
    Count = ?MAX_MESSAGE div Size - 1,
    ok = gen_tcp:send(Sock, masked(16#01, binary:copy(~"A", Size))),
    ok = send_times(Sock, Fragment, Count - 1),
    ok = gen_tcp:send(Sock, masked(16#89, ~"p")),
    ?assertEqual({pong, ~"p"}, recv_message(Sock)),
    true = erlang:garbage_collect(Pid),
    [{memory, Heap}, {binary, Bins}] = process_info(Pid, [memory, binary]),
    Held = lists:sum([BinSize || {_, BinSize, _} <- Bins]) + Heap,
    Buffered = Count * Size,
    ct:log("buffered ~b bytes, session holds ~b (~.2fx)", [Buffered, Held, Held / Buffered]),
    ?assert(Held < Buffered * 1.25),
    %% Two more fragments cross the cap.
    ok = send_times(Sock, Fragment, 2),
    ?assertEqual({close, <<1009:16>>}, recv_message(Sock)),
    ?assertEqual({terminated, {error, max_message_size}}, terminated()).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Upgrade and return the socket and the session pid.
upgrade(Config, Extra) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 5000
    ),
    ok = gen_tcp:send(Sock, [
        ~"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
        ~"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n",
        Extra,
        ~"\r\n"
    ]),
    ok = recv_head(Sock, <<>>),
    receive
        {session, Pid} -> {Sock, Pid}
    after 5000 -> ct:fail(no_session)
    end.

recv_head(Sock, Acc) ->
    case binary:split(Acc, ~"\r\n\r\n") of
        [<<"HTTP/1.1 101", _/binary>>, <<>>] ->
            ok;
        [_] ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            recv_head(Sock, <<Acc/binary, Data/binary>>)
    end.

terminated() ->
    receive
        {terminated, _} = Msg -> Msg
    after 5000 -> ct:fail(no_terminate)
    end.

%% Valid UTF-8 text of `Size` bytes or a little more, with multi-byte
%% characters that fragment boundaries cut through.
message(Size) ->
    Pattern = ~"roadrunner é € 𝄞 ",
    binary:part(binary:copy(Pattern, Size div byte_size(Pattern) + 1), 0, Size).

%% Split `Payload` into masked frames of the given sizes, the first a text
%% frame and the last one with FIN; whatever the sizes leave over goes
%% in the last frame.
fragments(Payload, Sizes) ->
    fragments(Payload, Sizes, 16#01).

fragments(Payload, [Size | Sizes], Op) when byte_size(Payload) > Size ->
    <<Part:Size/binary, Rest/binary>> = Payload,
    [masked(Op, Part) | fragments(Rest, Sizes, 16#00)];
fragments(Payload, _Sizes, Op) ->
    [masked(Op bor 16#80, Payload)].

send_times(_Sock, _Frame, 0) ->
    ok;
send_times(Sock, Frame, N) ->
    ok = gen_tcp:send(Sock, Frame),
    send_times(Sock, Frame, N - 1).

masked(OpByte, Payload) ->
    Key = <<1, 2, 3, 4>>,
    Len = byte_size(Payload),
    KeySlice = binary:part(binary:copy(Key, Len div 4 + 1), 0, Len),
    LenBytes =
        if
            Len < 126 -> <<(16#80 bor Len)>>;
            Len < 65536 -> <<(16#80 bor 126), Len:16>>;
            true -> <<(16#80 bor 127), Len:64>>
        end,
    <<OpByte, LenBytes/binary, Key/binary, (crypto:exor(Payload, KeySlice))/binary>>.

%% One server message: its opcode and payload, inflated when RSV1 marks
%% it compressed.
recv_message(Sock) ->
    {ok, <<_Fin:1, Rsv1:1, _:2, Op:4, 0:1, Len7:7>>} = gen_tcp:recv(Sock, 2, 5000),
    Len =
        case Len7 of
            126 ->
                {ok, <<L:16>>} = gen_tcp:recv(Sock, 2, 5000),
                L;
            127 ->
                {ok, <<L:64>>} = gen_tcp:recv(Sock, 8, 5000),
                L;
            _ ->
                Len7
        end,
    {ok, Payload} =
        case Len of
            0 -> {ok, <<>>};
            _ -> gen_tcp:recv(Sock, Len, 10000)
        end,
    {opcode(Op), inflate(Rsv1, Payload)}.

opcode(1) -> text;
opcode(8) -> close;
opcode(10) -> pong.

inflate(0, Payload) ->
    Payload;
inflate(1, Payload) ->
    Z = zlib:open(),
    ok = zlib:inflateInit(Z, -15),
    Inflated = iolist_to_binary(zlib:inflate(Z, [Payload, <<0, 0, 16#FF, 16#FF>>])),
    ok = zlib:close(Z),
    Inflated.
