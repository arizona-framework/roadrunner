-module(roadrunner_grpc_test_client).
-moduledoc false.

%% A gRPC client over hand-written HTTP/2 frames, enough to drive
%% `roadrunner_grpc` in tests: one connection, calls on chosen streams.
%%
%% It keeps to the server's flow control (RFC 9113 §6.9): DATA goes out
%% only within the stream's and the connection's send windows, and a send
%% that runs out waits for a WINDOW_UPDATE or SETTINGS. Frames read while
%% it waits are kept, in order, for `next_frame/1` to hand back.

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

%% RFC 9113 §6.5.2 defaults: the initial window (for each stream and for
%% the connection) and the largest DATA frame.
-define(INITIAL_WINDOW, 65535).
-define(MAX_FRAME, 16384).

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
        dec => roadrunner_http2_hpack:new_decoder(4096),
        %% The server's SETTINGS_INITIAL_WINDOW_SIZE, the connection's send
        %% window, each stream's send window (`closed` once the server
        %% ended or reset it) and the frames read while a send waited.
        initial_window => ?INITIAL_WINDOW,
        conn_window => ?INITIAL_WINDOW,
        windows => #{},
        pending => queue:new()
    }.

%% Open a call on `StreamId` to `Path`, with `Extra` headers after the
%% gRPC ones (a header given there replaces the default of that name).
start(
    #{sock := Sock, enc := Enc, initial_window := Initial, windows := Windows} = C,
    StreamId,
    Path,
    Extra
) ->
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
    C#{enc := Enc1, windows := Windows#{StreamId => Initial}}.

%% Send raw body bytes (framed messages, or anything) on the call, in
%% DATA frames that fit the send windows, waiting for more window when
%% they run out. Bytes left when the server ends or resets the stream are
%% dropped.
send(C, StreamId, Bytes) ->
    case send_window(C, StreamId) of
        closed ->
            C;
        _Window when Bytes =:= <<>> ->
            send_data(C, StreamId, Bytes);
        Window when byte_size(Bytes) =< min(Window, ?MAX_FRAME) ->
            send_data(C, StreamId, Bytes);
        Window when Window > 0 ->
            Size = min(Window, ?MAX_FRAME),
            <<Chunk:Size/binary, Rest/binary>> = Bytes,
            send(send_data(C, StreamId, Chunk), StreamId, Rest);
        _Spent ->
            send(await_window(C), StreamId, Bytes)
    end.

%% What the stream may send now: the smaller of its window and the
%% connection's.
send_window(#{conn_window := ConnWindow, windows := Windows}, StreamId) ->
    case Windows of
        #{StreamId := closed} -> closed;
        #{StreamId := Window} -> min(Window, ConnWindow)
    end.

send_data(#{sock := Sock, conn_window := ConnWindow, windows := Windows} = C, StreamId, Chunk) ->
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({data, StreamId, 0, Chunk})),
    #{StreamId := Window} = Windows,
    Size = byte_size(Chunk),
    C#{conn_window := ConnWindow - Size, windows := Windows#{StreamId := Window - Size}}.

%% Read one frame (which may grow a window) and keep it for `next_frame/1`.
await_window(C) ->
    {Frame, #{pending := Pending} = C1} = read_frame(C),
    C1#{pending := queue:in(Frame, Pending)}.

reset(#{sock := Sock} = C, StreamId) ->
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({rst_stream, StreamId, cancel})),
    C.

%% A zero-length DATA frame, needing no window, ends the requests.
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

%% The next frame from the server: one kept while a send waited first.
next_frame(#{pending := Pending} = C) ->
    case queue:out(Pending) of
        {{value, Frame}, Rest} -> {Frame, C#{pending := Rest}};
        {empty, _} -> read_frame(C)
    end.

read_frame(#{sock := Sock, buf := Buf, dec := Dec} = C) ->
    case roadrunner_http2_frame:parse(Buf, ?MAX_FRAME) of
        {ok, {headers, StreamId, Flags, _Priority, Block}, Rest} ->
            {ok, Fields, Dec1} = roadrunner_http2_hpack:decode(Block, Dec),
            Frame = {headers, StreamId, Flags, Fields},
            {Frame, flow(Frame, C#{buf := Rest, dec := Dec1})};
        {ok, Frame, Rest} ->
            {Frame, flow(Frame, C#{buf := Rest})};
        _More ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            read_frame(C#{buf := <<Buf/binary, Data/binary>>})
    end.

%% What a frame from the server does to the send windows (RFC 9113 §6.9).
flow({settings, 0, Params}, #{sock := Sock} = C) ->
    %% RFC 9113 §6.5.3: every SETTINGS frame is acknowledged.
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({settings, 1, []})),
    lists:foldl(fun apply_setting/2, C, Params);
flow({window_update, 0, Increment}, #{conn_window := ConnWindow} = C) ->
    C#{conn_window := ConnWindow + Increment};
flow({window_update, StreamId, Increment}, #{windows := Windows} = C) ->
    case Windows of
        #{StreamId := Window} when is_integer(Window) ->
            C#{windows := Windows#{StreamId := Window + Increment}};
        #{} ->
            C
    end;
flow({rst_stream, StreamId, _Code}, C) ->
    close(C, StreamId);
flow({headers, StreamId, Flags, _Fields}, C) when Flags band 16#01 =/= 0 ->
    close(C, StreamId);
flow({data, StreamId, Flags, _Data, _FlowLen}, C) when Flags band 16#01 =/= 0 ->
    close(C, StreamId);
flow(_Frame, C) ->
    C.

%% A new SETTINGS_INITIAL_WINDOW_SIZE (id 4) moves every open stream's
%% window by the change (RFC 9113 §6.9.2).
apply_setting({4, Initial}, #{initial_window := Old, windows := Windows} = C) ->
    Delta = Initial - Old,
    C#{
        initial_window := Initial,
        windows := maps:map(
            fun
                (_StreamId, closed) -> closed;
                (_StreamId, Window) -> Window + Delta
            end,
            Windows
        )
    };
apply_setting(_Param, C) ->
    C.

%% The server ended or reset the stream: nothing more is sent on it.
close(#{windows := Windows} = C, StreamId) ->
    C#{windows := Windows#{StreamId => closed}}.
