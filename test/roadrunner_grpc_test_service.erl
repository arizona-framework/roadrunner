-module(roadrunner_grpc_test_service).
-moduledoc false.

-behaviour(roadrunner_grpc_service).

-export([name/0, rpcs/0, files/0]).
-export([unary/2, count/2, sum/1, chat/1, fail/2, crash/2, crash_after/2, meta/2, deadline/2, bad/2]).
-export([stop/2, bad_trailer/2, late_headers/2, stale_send/2, bad_name/2, big_header/2]).
-export([unsafe_header/2, unsafe_fail/2, busy/2, squeezed/2, late_compression/2]).
-export([stale_compression/2, held/1, was_compressed/2, flood/2, big_trailer/2]).
-export([hold/2, watch/2, stop_after/2, reset_at/2, watch_late/2, keys/2]).
-export([active_sum/1, active_chat/1, mixed_sum/1, notify/2]).
-export([request/2]).

name() -> ~"test.Echo".

%% `base.proto`, which declares `test.Echo`, and its import.
files() -> roadrunner_grpc_reflection_test_files:files().

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
        ~"BadTrailer" => rpc(bad_trailer, server_stream),
        ~"LateHeaders" => rpc(late_headers, server_stream),
        ~"StaleSend" => rpc(stale_send, server_stream),
        ~"BadName" => rpc(bad_name, unary),
        ~"BigHeader" => rpc(big_header, unary),
        ~"UnsafeHeader" => rpc(unsafe_header, server_stream),
        ~"UnsafeFail" => rpc(unsafe_fail, unary),
        ~"Busy" => rpc(busy, unary),
        ~"Squeezed" => rpc(squeezed, server_stream),
        ~"LateCompression" => rpc(late_compression, server_stream),
        ~"StaleCompression" => rpc(stale_compression, server_stream),
        ~"Held" => rpc(held, client_stream),
        ~"WasCompressed" => rpc(was_compressed, unary),
        ~"Flood" => rpc(flood, server_stream),
        ~"BigTrailer" => rpc(big_trailer, unary),
        ~"Hold" => rpc(hold, unary),
        ~"Watch" => rpc(watch, server_stream),
        ~"StopAfter" => rpc(stop_after, server_stream),
        ~"ResetAt" => rpc(reset_at, unary),
        ~"WatchLate" => rpc(watch_late, server_stream),
        ~"Keys" => rpc(keys, unary),
        ~"ActiveSum" => rpc(active_sum, client_stream),
        ~"ActiveChat" => rpc(active_chat, bidi_stream),
        ~"MixedSum" => rpc(mixed_sum, client_stream),
        ~"Notify" => rpc(notify, server_stream),
        ~"Request" => rpc(request, unary)
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

was_compressed(_Request, Stream) ->
    {reply, atom_to_binary(roadrunner_grpc:recv_compressed(Stream)), Stream}.

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

%% A trailer value with a CR LF, after the response started.
bad_trailer(Request, Stream) ->
    Stream1 = roadrunner_grpc:send(Request, Stream),
    {ok, roadrunner_grpc:set_trailers([{~"x-bad", ~"a\r\nb"}], Stream1)}.

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
bad_name(~"message-type", Stream) ->
    {reply, ~"", roadrunner_grpc:set_headers([{~"grpc-message-type", ~"x"}], Stream)};
bad_name(~"newline", Stream) ->
    {reply, ~"", roadrunner_grpc:set_headers([{~"x-a\r\nb", ~"v"}], Stream)};
bad_name(~"nul", Stream) ->
    {reply, ~"", roadrunner_grpc:set_trailers([{~"x-a", <<"a", 0, "b">>}], Stream)};
bad_name(~"pseudo", Stream) ->
    {reply, ~"", roadrunner_grpc:set_headers([{~":path", ~"/"}], Stream)};
bad_name(~"trailer", Stream) ->
    {reply, ~"", roadrunner_grpc:set_trailers([{~"content-type", ~"x"}], Stream)};
bad_name(~"space", Stream) ->
    {reply, ~"", roadrunner_grpc:set_headers([{~"x a", ~"v"}], Stream)};
bad_name(~"colon", Stream) ->
    {reply, ~"", roadrunner_grpc:set_headers([{~"x:a", ~"v"}], Stream)};
bad_name(~"empty", Stream) ->
    {reply, ~"", roadrunner_grpc:set_headers([{~"", ~"v"}], Stream)};
bad_name(~"leading-space", Stream) ->
    {reply, ~"", roadrunner_grpc:set_trailers([{~"x-a", ~" v"}], Stream)};
bad_name(~"trailing-space", Stream) ->
    {reply, ~"", roadrunner_grpc:set_trailers([{~"x-a", ~"v "}], Stream)};
bad_name(~"tab", Stream) ->
    {reply, ~"", roadrunner_grpc:set_headers([{~"x-a", ~"a\tb"}], Stream)};
bad_name(~"non-ascii", Stream) ->
    {reply, ~"", roadrunner_grpc:set_headers([{~"x-a", <<"caf", 16#C3, 16#A9>>}], Stream)};
bad_name(~"good", Stream) ->
    Stream1 = roadrunner_grpc:set_headers([{~"x.a_b-9", ~"a b ~"}, {~"x-e", ~""}], Stream),
    {reply, ~"", Stream1}.

%% A header too big for a client that limits its header lists.
big_header(_Request, Stream) ->
    {reply, ~"", roadrunner_grpc:set_headers([{~"x-big", binary:copy(~"a", 500)}], Stream)}.

%% A trailer too big for a client that limits its header lists.
big_trailer(_Request, Stream) ->
    {reply, ~"", roadrunner_grpc:set_trailers([{~"x-big", binary:copy(~"a", 500)}], Stream)}.

%% A header value with a CR LF, ahead of a response...
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

%% Reads nothing until the process registered as `roadrunner_grpc_held`
%% lets it, then sums like `Sum`.
held(Stream) ->
    roadrunner_grpc_held ! {held, self()},
    receive
        go -> sum(Stream)
    end.

%% Sends until a write fails: the client cancelled, went away, or the
%% call's deadline cancelled it.
flood(Request, Stream) ->
    flood(Request, roadrunner_grpc:send(Request, Stream)).

%% Works without reading or writing until the process registered as
%% `roadrunner_grpc_held` lets it go, then fails.
hold(_Request, Stream) ->
    roadrunner_grpc_held ! {held, self()},
    receive
        go -> {error, not_found, ~"gone", Stream}
    end.

%% Waits on messages of its own until `cancelled/2` says the call is over.
watch(_Request, Stream) ->
    receive
        Message ->
            case roadrunner_grpc:cancelled(Message, Stream) of
                true -> {ok, Stream};
                false -> watch(~"", Stream)
            end
    end.

%% Stops on purpose after a response started.
stop_after(Request, Stream) ->
    _ = roadrunner_grpc:send(Request, Stream),
    exit({shutdown, stopped}).

%% `Hold`, asking for the reset the request's number of milliseconds
%% before the call's deadline.
reset_at(Before, Stream) ->
    ok = until(roadrunner_grpc:deadline(Stream) - binary_to_integer(Before)),
    hold(Before, Stream).

%% `Watch`, then working on until the call's deadline before it returns.
watch_late(Request, Stream) ->
    receive
        Message ->
            case roadrunner_grpc:cancelled(Message, Stream) of
                true ->
                    ok = until(roadrunner_grpc:deadline(Stream)),
                    {ok, Stream};
                false ->
                    watch_late(Request, Stream)
            end
    end.

%% The keys the call keeps in its process dictionary, sorted, after
%% `cancelled/2` told it a reset arrived when the request is `cancelled`.
keys(Request, Stream) ->
    _ = Request =:= ~"cancelled" andalso roadrunner_grpc:cancelled({h2_stream_reset, 1}, Stream),
    {reply, term_to_binary(lists:sort([Key || {{roadrunner_grpc, Key}, _} <- get()])), Stream}.

%% `Sum`, reading with `recv_async/1` and `info/2`. Asking twice before a
%% read is taken in asks once.
active_sum(Stream) ->
    active_sum(roadrunner_grpc:recv_async(roadrunner_grpc:recv_async(Stream)), <<>>).

active_sum(Stream, Acc) ->
    receive
        Message ->
            case roadrunner_grpc:info(Message, Stream) of
                {message, M, Stream1} ->
                    active_sum(roadrunner_grpc:recv_async(Stream1), <<Acc/binary, M/binary>>);
                {more, Stream1} ->
                    active_sum(Stream1, Acc);
                {eof, Stream1} ->
                    {reply, Acc, Stream1};
                ignore ->
                    active_sum(Stream, Acc)
            end
    end.

%% `Chat`, also sending what it is told to broadcast between the client's
%% messages: it tells the process registered as `roadrunner_grpc_held`
%% where it runs, then echoes each request and sends each
%% `{broadcast, Text}` it gets, until the requests end, the call is
%% cancelled, or the listener drains.
active_chat(Stream) ->
    roadrunner_grpc_held ! {held, self()},
    chatting(roadrunner_grpc:recv_async(Stream)).

chatting(Stream) ->
    receive
        {broadcast, Text} ->
            chatting(roadrunner_grpc:send(Text, Stream));
        Message ->
            case roadrunner_grpc:info(Message, Stream) of
                {message, M, Stream1} ->
                    chatting(roadrunner_grpc:recv_async(roadrunner_grpc:send(M, Stream1)));
                {more, Stream1} ->
                    chatting(Stream1);
                {eof, Stream1} ->
                    {ok, Stream1};
                cancelled ->
                    {ok, Stream};
                drain ->
                    {error, unavailable, ~"server shutting down", Stream};
                ignore ->
                    chatting(Stream)
            end
    end.

%% Sends each `{notify, Text}` it gets, telling the process registered as
%% `roadrunner_grpc_held` where it runs first, until the call is cancelled
%% or the listener drains.
notify(_Request, Stream) ->
    roadrunner_grpc_held ! {held, self()},
    notifying(Stream).

notifying(Stream) ->
    receive
        {notify, Text} ->
            notifying(roadrunner_grpc:send(Text, Stream));
        Message ->
            case roadrunner_grpc:info(Message, Stream) of
                cancelled -> {ok, Stream};
                drain -> {error, unavailable, ~"server shutting down", Stream};
                ignore -> notifying(Stream)
            end
    end.

%% `Sum`, each `recv/1` after a `recv_async/1`: it waits for the read the
%% latter asked for.
mixed_sum(Stream) ->
    mixed_sum(Stream, <<>>).

mixed_sum(Stream, Acc) ->
    case roadrunner_grpc:recv(roadrunner_grpc:recv_async(Stream)) of
        {ok, M, Stream1} -> mixed_sum(Stream1, <<Acc/binary, M/binary>>);
        {eof, Stream1} -> {reply, Acc, Stream1}
    end.

until(Time) ->
    receive
    after max(0, Time - erlang:monotonic_time(millisecond)) -> ok
    end.

%% What the call's HTTP request tells beyond the metadata.
request(_Request, Stream) ->
    Req = roadrunner_grpc:request(Stream),
    {reply,
        term_to_binary(#{
            peercert => roadrunner_req:peercert(Req),
            private => roadrunner_req:private(roadrunner_grpc_test, Req),
            request_id => roadrunner_req:request_id(Req),
            timeout => roadrunner_req:header(~"grpc-timeout", Req),
            metadata => roadrunner_grpc:metadata(Stream)
        }), Stream}.
