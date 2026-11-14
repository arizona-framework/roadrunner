-module(roadrunner_grpc_test_client).
-moduledoc false.

%% A gRPC client over hand-written HTTP/2 frames, enough to drive
%% `roadrunner_grpc` in tests: one connection, calls on chosen streams.

-export([
    open/1,
    start/4,
    send/3,
    finish/2,
    response/2,
    trailers/2,
    call/4, call/5,
    next_frame/1,
    messages/1,
    reset/2
]).

open(Port) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    ok = gen_tcp:send(Sock, [
        ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",
        %% Windows wide open (SETTINGS_INITIAL_WINDOW_SIZE, id 4, and the
        %% connection's), so responses never wait on a WINDOW_UPDATE this
        %% client does not send.
        roadrunner_http2_frame:encode({settings, 0, [{4, 16#7FFFFFFF}]}),
        roadrunner_http2_frame:encode({window_update, 0, 16#7FFFFFFF - 65535})
    ]),
    #{
        sock => Sock,
        buf => <<>>,
        enc => roadrunner_http2_hpack:new_encoder(4096),
        dec => roadrunner_http2_hpack:new_decoder(4096)
    }.

%% Open a call on `StreamId` to `Path`, with `Extra` headers after the
%% gRPC ones (a header given there replaces the default of that name).
start(#{sock := Sock, enc := Enc} = C, StreamId, Path, Extra) ->
    Defaults = [{~"content-type", ~"application/grpc"}, {~"te", ~"trailers"}],
    Fields =
        [
            {~":method", proplists:get_value(~":method", Extra, ~"POST")},
            {~":scheme", ~"http"},
            {~":authority", ~"x"},
            {~":path", Path}
        ] ++
            [{N, V} || {N, V} <- Defaults, not lists:keymember(N, 1, Extra)] ++
            [{N, V} || {N, V} <- Extra, N =/= ~":method", V =/= omit],
    {Block, Enc1} = roadrunner_http2_hpack:encode(Fields, Enc),
    ok = gen_tcp:send(
        Sock, roadrunner_http2_frame:encode({headers, StreamId, 16#04, undefined, Block})
    ),
    C#{enc := Enc1}.

%% Send raw body bytes (framed messages, or anything) on the call.
send(#{sock := Sock} = C, StreamId, Bytes) ->
    ok = gen_tcp:send(Sock, data_frames(StreamId, Bytes)),
    C.

%% DATA frames of at most the default 16384-byte frame size.
data_frames(StreamId, <<Chunk:16384/binary, Rest/binary>>) when Rest =/= <<>> ->
    [roadrunner_http2_frame:encode({data, StreamId, 0, Chunk}) | data_frames(StreamId, Rest)];
data_frames(StreamId, Bytes) ->
    [roadrunner_http2_frame:encode({data, StreamId, 0, Bytes})].

reset(#{sock := Sock} = C, StreamId) ->
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({rst_stream, StreamId, cancel})),
    C.

finish(#{sock := Sock} = C, StreamId) ->
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({data, StreamId, 16#01, <<>>})),
    C.

%% A whole call: framed `Messages` (binaries) then the end of the requests.
call(C, StreamId, Path, Messages) ->
    call(C, StreamId, Path, [], Messages).

call(C0, StreamId, Path, Extra, Messages) ->
    C1 = start(C0, StreamId, Path, Extra),
    C2 = send(
        C1, StreamId, iolist_to_binary([roadrunner_grpc_frame:encode(false, M) || M <- Messages])
    ),
    response(finish(C2, StreamId), StreamId).

%% The call's response: `{Headers, Messages, Trailers, C}`, Trailers being
%% `trailers_only` when the status came in the headers, or `{rst, Code}`.
response(C, StreamId) ->
    response(C, StreamId, undefined, <<>>).

response(C, StreamId, Headers, Body) ->
    case next_frame(C) of
        {{headers, StreamId, Flags, Fields}, C1} when
            Headers =:= undefined, Flags band 16#01 =/= 0
        ->
            {Fields, [], trailers_only, C1};
        {{headers, StreamId, _Flags, Fields}, C1} when Headers =:= undefined ->
            response(C1, StreamId, Fields, Body);
        {{headers, StreamId, _Flags, Fields}, C1} ->
            {Headers, messages(Body), Fields, C1};
        {{data, StreamId, Flags, Data, _}, C1} when Flags band 16#01 =/= 0 ->
            %% Not a gRPC answer: an HTTP response that ends with its body.
            {Headers, {body, <<Body/binary, Data/binary>>}, no_trailers, C1};
        {{data, StreamId, _Flags, Data, _}, C1} ->
            response(C1, StreamId, Headers, <<Body/binary, Data/binary>>);
        {{rst_stream, StreamId, Code}, C1} ->
            {Headers, messages(Body), {rst, Code}, C1};
        {_Other, C1} ->
            response(C1, StreamId, Headers, Body)
    end.

%% The trailers that end a call whose response headers were read already.
trailers(C, StreamId) ->
    case next_frame(C) of
        {{headers, StreamId, _Flags, Fields}, C1} -> {Fields, C1};
        {_Other, C1} -> trailers(C1, StreamId)
    end.

messages(Body) ->
    case roadrunner_grpc_frame:decode(Body, 16#FFFFFFFF) of
        {ok, false, M, Rest} -> [M | messages(Rest)];
        {ok, true, M, Rest} -> [{compressed, M} | messages(Rest)];
        more -> []
    end.

next_frame(#{sock := Sock, buf := Buf, dec := Dec} = C) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {ok, {headers, StreamId, Flags, _Priority, Block}, Rest} ->
            {ok, Fields, Dec1} = roadrunner_http2_hpack:decode(Block, Dec),
            {{headers, StreamId, Flags, Fields}, C#{buf := Rest, dec := Dec1}};
        {ok, Frame, Rest} ->
            {Frame, C#{buf := Rest}};
        _More ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            next_frame(C#{buf := <<Buf/binary, Data/binary>>})
    end.
