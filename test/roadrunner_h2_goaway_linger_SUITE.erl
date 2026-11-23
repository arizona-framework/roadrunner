-module(roadrunner_h2_goaway_linger_SUITE).
-moduledoc """
An HTTP/2 connection closed by a GOAWAY lingers over what the client is
still sending, driven by a hand-written client over plain TCP: closing
with input unread makes the kernel reset the connection, and a client
that reads the GOAWAY then gets the reset instead of a clean close.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([handle/1]).
-export([
    oversized_data_goaway_then_clean_close/1,
    oversized_headers_goaway_then_clean_close/1,
    no_linger_resets/1,
    streaming_worker_ends_before_the_linger/1
]).

-define(PREFACE, ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").
%% What the client still sends after its oversized frame: far more than
%% one read of the socket takes, so the conn closes with input unread.
-define(TRAILING_BYTES, 262144).
%% The name the streaming case registers for its handler to find it.
-define(CASE, roadrunner_h2_goaway_linger_case).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        oversized_data_goaway_then_clean_close,
        oversized_headers_goaway_then_clean_close,
        no_linger_resets,
        streaming_worker_ends_before_the_linger
    ].

init_per_testcase(Case, Config) ->
    {ok, _} = roadrunner_listener:start_link(?MODULE, #{
        port => 0,
        protocols => [{http2, http2_opts(Case)}],
        routes => [{~"/stream", ?MODULE}, {~"/", roadrunner_hello_handler}]
    }),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_listener:stop(?MODULE).

http2_opts(no_linger_resets) -> #{linger_timeout => 0};
%% Far longer than the case waits for the worker to end.
http2_opts(streaming_worker_ends_before_the_linger) -> #{linger_timeout => 60_000};
http2_opts(_Case) -> #{}.

oversized_data_goaway_then_clean_close(Config) ->
    %% RFC 9113 §4.2: a DATA frame over SETTINGS_MAX_FRAME_SIZE (16384).
    Sock = oversized_frame(Config, 0),
    ?assertEqual(frame_size_error, goaway_code(Sock, <<>>)),
    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 5000)).

oversized_headers_goaway_then_clean_close(Config) ->
    Sock = oversized_frame(Config, 1),
    ?assertEqual(frame_size_error, goaway_code(Sock, <<>>)),
    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 5000)).

no_linger_resets(Config) ->
    %% The failure the linger fixes: the GOAWAY arrives, then the reset.
    Sock = oversized_frame(Config, 0),
    ?assertEqual(frame_size_error, goaway_code(Sock, <<>>)),
    ?assertEqual({error, econnreset}, gen_tcp:recv(Sock, 0, 5000)).

streaming_worker_ends_before_the_linger(Config) ->
    %% A worker streaming its response when a connection error closes the
    %% conn is told its stream is reset before the conn lingers: it ends
    %% now, not when the linger does.
    true = register(?CASE, self()),
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}, {show_econnreset, true}]
    ),
    Settings = roadrunner_http2_frame:encode({settings, 0, []}),
    {Block, _Enc} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"GET"},
            {~":scheme", ~"http"},
            {~":authority", ~"x"},
            {~":path", ~"/stream"}
        ],
        roadrunner_http2_hpack:new_encoder(4096)
    ),
    ok = gen_tcp:send(Sock, [
        ?PREFACE, Settings, roadrunner_http2_frame:encode({headers, 1, 16#05, undefined, Block})
    ]),
    Worker =
        receive
            {streaming, Pid} -> Pid
        end,
    MonRef = monitor(process, Worker),
    %% A DATA frame over the limit: GOAWAY(FRAME_SIZE_ERROR), then the linger.
    ok = gen_tcp:send(Sock, <<16385:24, 0, 0, 1:32>>),
    ?assertEqual(frame_size_error, goaway_code(Sock, <<>>)),
    receive
        {'DOWN', MonRef, process, Worker, _} -> ok
    after 5_000 -> error(worker_waited_for_the_linger)
    end,
    ok = gen_tcp:close(Sock).

%% Streams its response until the conn stops taking it, announcing its pid
%% to the case first.
-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    {
        {stream, 200, [], fun(Send) ->
            ?CASE ! {streaming, self()},
            stream(Send)
        end},
        Req
    }.

-spec stream(roadrunner_handler:send_fun()) -> no_return().
stream(Send) ->
    ok = Send(binary:copy(~"x", 1024), nofin),
    stream(Send).

%% =============================================================================
%% Helpers
%% =============================================================================

%% Connect, send the preface, then a frame of `Type` on stream 1 one byte
%% over the limit, followed by more bytes than one read takes.
-spec oversized_frame(ct_suite:ct_config(), non_neg_integer()) -> gen_tcp:socket().
oversized_frame(Config, Type) ->
    %% `show_econnreset`: a reset reads as `econnreset`, not `closed`.
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}, {show_econnreset, true}]
    ),
    Settings = roadrunner_http2_frame:encode({settings, 0, []}),
    ok = gen_tcp:send(Sock, [?PREFACE, Settings]),
    Frame = [<<16385:24, Type, 0, 1:32>>, binary:copy(<<0>>, ?TRAILING_BYTES)],
    %% From another process: the send can block on a conn that stops
    %% reading, and fails once it resets.
    _ = spawn(fun() -> _ = gen_tcp:send(Sock, Frame) end),
    Sock.

%% Read frames up to the GOAWAY and return its error code.
-spec goaway_code(gen_tcp:socket(), binary()) -> roadrunner_http2_frame:error_code().
goaway_code(Sock, Buf) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {ok, {goaway, _LastStreamId, Code, _Debug}, _Rest} ->
            Code;
        {ok, _Frame, Rest} ->
            goaway_code(Sock, Rest);
        {more, _} ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            goaway_code(Sock, <<Buf/binary, Data/binary>>)
    end.
