-module(roadrunner_grpc_test_service).
-moduledoc false.

-behaviour(roadrunner_grpc_service).

-export([name/0, rpcs/0]).
-export([unary/2, count/2, sum/1, chat/1, fail/2, crash/2, crash_after/2, meta/2, deadline/2, bad/2]).
-export([stop/2, bad_trailer/2, late_headers/2, stale_send/2, bad_name/2]).
-export([unsafe_header/2, unsafe_fail/2, busy/2, squeezed/2, late_compression/2]).
-export([stale_compression/2]).

name() -> ~"test.Echo".

rpcs() ->
    #{
        ~"Unary" => rpc(unary, unary),
        ~"Count" => rpc(count, server_stream),
        ~"Sum" => rpc(sum, client_stream),
        ~"Chat" => rpc(chat, bidi_stream),
        ~"Fail" => rpc(fail, unary),
        ~"Crash" => rpc(crash, unary),
        ~"CrashAfter" => rpc(crash_after, server_stream),
        ~"Meta" => rpc(meta, unary),
        ~"Deadline" => rpc(deadline, unary),
        ~"Bad" => rpc(bad, unary),
        ~"Stop" => rpc(stop, unary),
        ~"BadTrailer" => rpc(bad_trailer, unary),
        ~"LateHeaders" => rpc(late_headers, server_stream),
        ~"StaleSend" => rpc(stale_send, server_stream),
        ~"BadName" => rpc(bad_name, unary),
        ~"UnsafeHeader" => rpc(unsafe_header, server_stream),
        ~"UnsafeFail" => rpc(unsafe_fail, unary),
        ~"Busy" => rpc(busy, unary),
        ~"Squeezed" => rpc(squeezed, server_stream),
        ~"LateCompression" => rpc(late_compression, server_stream),
        ~"StaleCompression" => rpc(stale_compression, server_stream)
    }.

rpc(Function, Kind) ->
    #{function => Function, kind => Kind, input => in, output => out}.

unary(Request, Stream) ->
    {reply, Request, Stream}.

count(N, Stream) ->
    {ok,
        lists:foldl(
            fun(I, S) -> roadrunner_grpc:send(integer_to_binary(I), S) end,
            Stream,
            lists:seq(1, binary_to_integer(N))
        )}.

sum(Stream) ->
    sum(Stream, <<>>).

sum(Stream, Acc) ->
    case roadrunner_grpc:recv(Stream) of
        {ok, M, Stream1} -> sum(Stream1, <<Acc/binary, M/binary>>);
        {eof, Stream1} -> {reply, Acc, Stream1}
    end.

chat(Stream) ->
    case roadrunner_grpc:recv(Stream) of
        {ok, M, Stream1} -> chat(roadrunner_grpc:send(M, Stream1));
        {eof, Stream1} -> {ok, Stream1}
    end.

fail(_Request, Stream) ->
    {error, not_found, ~"no such thing: café 100%", Stream}.

crash(_Request, _Stream) ->
    error(boom).

crash_after(_Request, Stream) ->
    _ = roadrunner_grpc:send(~"first", Stream),
    error(boom).

meta(_Request, Stream0) ->
    Stream1 = roadrunner_grpc:set_headers(
        [{~"x-head", ~"h"}, {~"x-raw-bin", <<0, 1, 2>>}], Stream0
    ),
    Stream = roadrunner_grpc:set_trailers([{~"x-tail", ~"t"}], Stream1),
    {reply, term_to_binary({roadrunner_grpc:metadata(Stream), roadrunner_grpc:peer(Stream)}),
        Stream}.

deadline(_Request, Stream) ->
    {reply, term_to_binary(roadrunner_grpc:deadline(Stream)), Stream}.

bad(_Request, Stream) ->
    {wat, Stream}.

stop(_Request, _Stream) ->
    exit({shutdown, stopped}).

bad_trailer(Request, Stream) ->
    {reply, Request, roadrunner_grpc:set_trailers([{~"x-bad", <<"a\r\nb">>}], Stream)}.

late_headers(_Request, Stream) ->
    Stream1 = roadrunner_grpc:send(~"one", Stream),
    {ok, roadrunner_grpc:set_headers([{~"x-late", ~"1"}], Stream1)}.

%% Sends from the same, older copy of the stream each time.
stale_send(_Request, Stream) ->
    lists:foreach(fun(M) -> roadrunner_grpc:send(M, Stream) end, [~"a", ~"b"]),
    {ok, Stream}.

%% Metadata the call may not set: which one, the request says.
bad_name(~"upper", Stream) ->
    {reply, ~"", roadrunner_grpc:set_headers([{~"X-Up", ~"v"}], Stream)};
bad_name(~"reserved", Stream) ->
    {reply, ~"", roadrunner_grpc:set_headers([{~"grpc-status", ~"0"}], Stream)};
bad_name(~"pseudo", Stream) ->
    {reply, ~"", roadrunner_grpc:set_headers([{~":path", ~"/"}], Stream)};
bad_name(~"trailer", Stream) ->
    {reply, ~"", roadrunner_grpc:set_trailers([{~"content-type", ~"x"}], Stream)}.

%% A header value the connection will not send, ahead of a response...
unsafe_header(_Request, Stream) ->
    Stream1 = roadrunner_grpc:set_headers([{~"x-a", <<"a\r\nb">>}], Stream),
    {ok, roadrunner_grpc:send(~"one", Stream1)}.

%% ...or of an error status.
unsafe_fail(_Request, Stream) ->
    {error, not_found, ~"gone", roadrunner_grpc:set_headers([{~"x-a", <<"a\r\nb">>}], Stream)}.

%% Works on and on, past any deadline, without writing.
busy(_Request, Stream) ->
    receive
        never_sent -> ok
    after 5000 -> {reply, ~"late", Stream}
    end.

%% Compresses its answer as the request names, the second message sent
%% uncompressed whatever the call's compression.
squeezed(Name, Stream0) ->
    Encoding = maps:get(Name, #{~"gzip" => gzip, ~"deflate" => deflate, ~"identity" => identity}),
    Stream1 = roadrunner_grpc:set_send_compression(Encoding, Stream0),
    Payload = binary:copy(~"squeeze me ", 20),
    Stream2 = roadrunner_grpc:send(Payload, Stream1),
    {ok, roadrunner_grpc:send(Payload, Stream2, #{compress => false})}.

late_compression(_Request, Stream0) ->
    Stream1 = roadrunner_grpc:send(~"one", Stream0),
    {ok, roadrunner_grpc:set_send_compression(gzip, Stream1)}.

%% Sends first from the copy before its compression was set, then from the
%% copy after: the headers went out uncompressed, so both messages do.
stale_compression(_Request, Stream0) ->
    Plain = roadrunner_grpc:set_send_compression(identity, Stream0),
    Gzip = roadrunner_grpc:set_send_compression(gzip, Stream0),
    _ = roadrunner_grpc:send(~"one", Plain),
    {ok, roadrunner_grpc:send(~"two", Gzip)}.
