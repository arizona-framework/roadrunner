-module(cactus_conn).
-moduledoc """
HTTP/1.1 connection process — one per accepted TCP connection.

Reads bytes from the socket, drives `cactus_http1:parse_request/1`
incrementally, sends a hardcoded `200 Hello, cactus!` response on
success or `400 Bad Request` on parse failure, then closes.

This is the minimum end-to-end pipeline for slice 2; the handler
behaviour and routing arrive in slices 3–4.
""".

-export([start/2, parse_loop/2, read_body/4, peer/1, try_acquire_slot/1, release_slot/1]).

-export_type([proto_opts/0, dispatch/0]).

-type dispatch() ::
    {handler, module()}
    | {router, cactus_router:compiled()}.

-type proto_opts() :: #{
    dispatch := dispatch(),
    max_content_length := non_neg_integer(),
    request_timeout := non_neg_integer(),
    keep_alive_timeout := non_neg_integer(),
    max_keep_alive_request := pos_integer(),
    max_clients := pos_integer(),
    client_counter := atomics:atomics_ref()
}.

-doc """
Spawn an unlinked connection process for the accepted `Socket` and the
shared `ProtoOpts` (handler module, body limits, ...).

The caller (typically `cactus_acceptor`) must transfer socket
ownership via `cactus_transport:controlling_process/2` and then
send the process the atom `shoot` to release it.
""".
-spec start(cactus_transport:socket(), proto_opts()) -> {ok, pid()}.
start(Socket, ProtoOpts) when is_map(ProtoOpts) ->
    Pid = proc_lib:spawn(fun() ->
        proc_lib:set_label(cactus_conn),
        try
            receive
                shoot -> serve(Socket, ProtoOpts)
            end
        after
            release_slot(ProtoOpts)
        end
    end),
    {ok, Pid}.

-doc """
Try to bump the live-connection counter under `max_clients`. Returns
`true` on success (caller may proceed to spawn a conn), `false` if
the cap is already met (caller must close the accepted socket).

The check is racy by a small amount: between increment and rollback
multiple acceptors may briefly observe a count slightly above the
cap, but the count is corrected immediately by the rollback. The
overshoot is at most `num_acceptors - 1` — bounded and harmless.
""".
-spec try_acquire_slot(proto_opts()) -> boolean().
try_acquire_slot(#{client_counter := Ref, max_clients := Max}) ->
    case atomics:add_get(Ref, 1, 1) of
        N when N =< Max ->
            true;
        _ ->
            atomics:sub(Ref, 1, 1),
            false
    end.

-doc "Decrement the live-connection counter — paired with `try_acquire_slot/1`.".
-spec release_slot(proto_opts()) -> ok.
release_slot(#{client_counter := Ref}) ->
    _ = atomics:sub(Ref, 1, 1),
    ok.

-spec serve(cactus_transport:socket(), proto_opts()) -> ok.
serve(Socket, ProtoOpts) ->
    Peer = peer(Socket),
    Scheme = scheme(Socket),
    serve_loop(Socket, Peer, Scheme, ProtoOpts, 0),
    _ = cactus_transport:close(Socket),
    ok.

-spec serve_loop(
    cactus_transport:socket(), term(), http | https, proto_opts(), non_neg_integer()
) -> ok.
serve_loop(_Socket, _Peer, _Scheme, #{max_keep_alive_request := Max}, Count) when Count >= Max ->
    ok;
serve_loop(Socket, Peer, Scheme, ProtoOpts, Count) ->
    %% First request on a fresh connection: bounded by request_timeout, and
    %% a silent client gets a 408. Idle wait between keep-alive requests:
    %% bounded by keep_alive_timeout, and an idle client just gets the
    %% socket closed silently — no 408 to a peer that wasn't going to read it.
    {Timeout, Phase} =
        case Count of
            0 -> {maps:get(request_timeout, ProtoOpts), first};
            _ -> {maps:get(keep_alive_timeout, ProtoOpts), keep_alive}
        end,
    case process_one(Socket, Peer, Scheme, ProtoOpts, Timeout, Phase) of
        keep_alive -> serve_loop(Socket, Peer, Scheme, ProtoOpts, Count + 1);
        close -> ok
    end.

-spec process_one(
    cactus_transport:socket(),
    term(),
    http | https,
    proto_opts(),
    non_neg_integer(),
    first | keep_alive
) -> keep_alive | close.
process_one(
    Socket,
    Peer,
    Scheme,
    #{
        dispatch := Dispatch,
        max_content_length := MaxCL
    },
    Timeout,
    Phase
) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    Recv = make_recv(Socket, Deadline),
    case parse_loop(<<>>, Recv) of
        {ok, Req0, Buffered} ->
            Req = Req0#{peer => Peer, scheme => Scheme},
            ok = maybe_send_continue(Socket, Req, Buffered),
            case read_body(Req, Buffered, Recv, MaxCL) of
                {ok, Body} ->
                    ReqWithBody = Req#{body => Body},
                    case resolve_handler(Dispatch, ReqWithBody) of
                        {ok, Handler, Bindings, RouteOpts} ->
                            FullReq = ReqWithBody#{
                                bindings => Bindings,
                                route_opts => RouteOpts
                            },
                            handle_and_send(Socket, Handler, FullReq);
                        not_found ->
                            _ = send_not_found(Socket),
                            close
                    end;
                {error, content_length_too_large} ->
                    _ = send_payload_too_large(Socket),
                    close;
                {error, request_timeout} ->
                    _ = send_request_timeout(Socket),
                    close;
                {error, _} ->
                    _ = send_bad_request(Socket),
                    close
            end;
        {error, request_timeout} ->
            _ = maybe_send_request_timeout(Socket, Phase),
            close;
        {error, _} ->
            _ = send_bad_request(Socket),
            close
    end.

-spec maybe_send_request_timeout(cactus_transport:socket(), first | keep_alive) ->
    ok | {error, term()}.
maybe_send_request_timeout(Socket, first) -> send_request_timeout(Socket);
maybe_send_request_timeout(_Socket, keep_alive) -> ok.

%% Build a recv closure with a single overall deadline. `gen_tcp:recv`
%% with a negative timeout is undefined, so we cap at 0 — which makes
%% gen_tcp return `{error, timeout}` immediately when the deadline has
%% passed. Any timeout here is, by construction, the request_timeout.
-spec make_recv(cactus_transport:socket(), integer()) ->
    fun(() -> {ok, binary()} | {error, request_timeout | term()}).
make_recv(Socket, Deadline) ->
    fun() ->
        Now = erlang:monotonic_time(millisecond),
        Remaining = max(0, Deadline - Now),
        case cactus_transport:recv(Socket, 0, Remaining) of
            {ok, _} = OK -> OK;
            {error, timeout} -> {error, request_timeout};
            {error, _} = E -> E
        end
    end.

-doc false.
-spec peer(cactus_transport:socket()) -> {inet:ip_address(), inet:port_number()} | undefined.
peer(Socket) ->
    case cactus_transport:peername(Socket) of
        {ok, Peer} -> Peer;
        {error, _} -> undefined
    end.

-spec scheme(cactus_transport:socket()) -> http | https.
scheme({gen_tcp, _}) -> http;
scheme({ssl, _}) -> https.

-spec resolve_handler(dispatch(), cactus_http1:request()) ->
    {ok, module(), cactus_router:bindings(), term()} | not_found.
resolve_handler({handler, Mod}, _Req) ->
    {ok, Mod, #{}, undefined};
resolve_handler({router, Compiled}, Req) ->
    cactus_router:match(cactus_req:path(Req), Compiled).

-doc false.
-spec read_body(
    cactus_http1:request(),
    binary(),
    fun(() -> {ok, binary()} | {error, term()}),
    non_neg_integer()
) ->
    {ok, binary()}
    | {error,
        content_length_too_large
        | bad_content_length
        | bad_transfer_encoding
        | term()}.
read_body(Req, Buffered, RecvFun, MaxCL) ->
    case body_framing(Req) of
        none ->
            {ok, Buffered};
        chunked ->
            read_chunked(Buffered, RecvFun, MaxCL, 0);
        {content_length, N} when N > MaxCL ->
            {error, content_length_too_large};
        {content_length, N} ->
            read_body_until(N, Buffered, RecvFun);
        {error, _} = Err ->
            Err
    end.

%% RFC 9110 §10.1.1: when a request carries `Expect: 100-continue` and
%% we're about to read a body, send `HTTP/1.1 100 Continue` so clients
%% that gate body transmission on this signal don't stall. We only do
%% this if no body bytes have already arrived in the buffer — once we
%% see body data the client clearly didn't wait, and the 100 line is
%% redundant.
-spec maybe_send_continue(cactus_transport:socket(), cactus_http1:request(), binary()) -> ok.
maybe_send_continue(Socket, Req, Buffered) ->
    case Buffered =:= ~"" andalso has_continue_expectation(Req) of
        true ->
            _ = cactus_transport:send(Socket, ~"HTTP/1.1 100 Continue\r\n\r\n"),
            ok;
        false ->
            ok
    end.

-spec has_continue_expectation(cactus_http1:request()) -> boolean().
has_continue_expectation(Req) ->
    case cactus_req:header(~"expect", Req) of
        undefined -> false;
        Value -> string:lowercase(Value) =:= ~"100-continue"
    end.

-spec body_framing(cactus_http1:request()) ->
    none
    | chunked
    | {content_length, non_neg_integer()}
    | {error, bad_content_length | bad_transfer_encoding}.
body_framing(Req) ->
    case cactus_req:header(~"transfer-encoding", Req) of
        undefined ->
            case content_length(Req) of
                none -> none;
                {ok, N} -> {content_length, N};
                {error, _} = Err -> Err
            end;
        ~"chunked" ->
            chunked;
        _ ->
            {error, bad_transfer_encoding}
    end.

-spec read_body_until(
    non_neg_integer(),
    binary(),
    fun(() -> {ok, binary()} | {error, term()})
) ->
    {ok, binary()} | {error, term()}.
read_body_until(N, Acc, _RecvFun) when byte_size(Acc) >= N ->
    <<Body:N/binary, _/binary>> = Acc,
    {ok, Body};
read_body_until(N, Acc, RecvFun) ->
    case RecvFun() of
        {ok, Data} -> read_body_until(N, <<Acc/binary, Data/binary>>, RecvFun);
        {error, _} = E -> E
    end.

%% Read chunks until the size-0 last-chunk, concatenating decoded data
%% into the result. Caps the accumulated body at MaxCL — a malicious
%% client cannot stream unbounded chunked bytes past the configured
%% limit. Body recursion: each call returns the body of the remaining
%% chunks, the current call prepends its own data on the way out.
-spec read_chunked(
    binary(),
    fun(() -> {ok, binary()} | {error, term()}),
    non_neg_integer(),
    non_neg_integer()
) ->
    {ok, binary()} | {error, content_length_too_large | term()}.
read_chunked(Buf, RecvFun, MaxCL, Decoded) ->
    case cactus_http1:parse_chunk(Buf) of
        {ok, last, _Trailers, _Rest} ->
            {ok, <<>>};
        {ok, Data, Rest} ->
            NewDecoded = Decoded + byte_size(Data),
            if
                NewDecoded > MaxCL ->
                    {error, content_length_too_large};
                true ->
                    case read_chunked(Rest, RecvFun, MaxCL, NewDecoded) of
                        {ok, More} -> {ok, <<Data/binary, More/binary>>};
                        {error, _} = E -> E
                    end
            end;
        {more, _} ->
            case RecvFun() of
                {ok, More} ->
                    read_chunked(<<Buf/binary, More/binary>>, RecvFun, MaxCL, Decoded);
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

-spec content_length(cactus_http1:request()) ->
    none | {ok, non_neg_integer()} | {error, bad_content_length}.
content_length(Req) ->
    case cactus_req:header(~"content-length", Req) of
        undefined ->
            none;
        Bin ->
            try binary_to_integer(Bin) of
                N when N >= 0 -> {ok, N};
                _ -> {error, bad_content_length}
            catch
                _:_ -> {error, bad_content_length}
            end
    end.

-doc false.
-spec parse_loop(binary(), fun(() -> {ok, binary()} | {error, term()})) ->
    {ok, cactus_http1:request(), binary()} | {error, term()}.
parse_loop(Buf, RecvFun) ->
    case cactus_http1:parse_request(Buf) of
        {ok, Req, Rest} ->
            {ok, Req, Rest};
        {more, _} ->
            case RecvFun() of
                {ok, Data} -> parse_loop(<<Buf/binary, Data/binary>>, RecvFun);
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

-spec handle_and_send(cactus_transport:socket(), module(), cactus_http1:request()) ->
    keep_alive | close.
handle_and_send(Socket, Handler, Req) ->
    try Handler:handle(Req) of
        {websocket, Mod, State} when is_atom(Mod) ->
            _ = upgrade_to_websocket(Socket, Req, Mod, State),
            close;
        {stream, Status, Headers, Fun} when is_function(Fun, 1) ->
            _ = stream_response(Socket, Status, Headers, Fun),
            close;
        {Status, Headers, Body} when is_integer(Status) ->
            RespBody = response_body_for(Req, Body),
            Resp = cactus_http1:response(Status, Headers, RespBody),
            _ = cactus_transport:send(Socket, Resp),
            keep_alive_decision(Req, Headers)
    catch
        Class:Reason:Stack ->
            logger:error(#{
                msg => "cactus handler crashed",
                handler => Handler,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            _ = send_internal_error(Socket),
            close
    end.

%% RFC 9110 §9.3.2: a response to HEAD must not include a message body.
%% Headers (including Content-Length) stay as the handler set them, so
%% the framing matches what GET would have returned.
-spec response_body_for(cactus_http1:request(), iodata()) -> iodata().
response_body_for(Req, Body) ->
    case cactus_req:method(Req) of
        ~"HEAD" -> ~"";
        _ -> Body
    end.

%% HTTP/1.0 default close. HTTP/1.1 keep-alive unless either side
%% set Connection: close.
-spec keep_alive_decision(cactus_http1:request(), cactus_http1:headers()) ->
    keep_alive | close.
keep_alive_decision(Req, RespHeaders) ->
    case cactus_req:version(Req) of
        {1, 0} ->
            close;
        {1, 1} ->
            ReqClose = has_close_token(cactus_req:header(~"connection", Req)),
            RespClose = has_close_token(header_value(~"connection", RespHeaders)),
            case ReqClose orelse RespClose of
                true -> close;
                false -> keep_alive
            end
    end.

-spec has_close_token(binary() | undefined) -> boolean().
has_close_token(undefined) ->
    false;
has_close_token(Value) ->
    binary:match(string:lowercase(Value), ~"close") =/= nomatch.

-spec header_value(binary(), cactus_http1:headers()) -> binary() | undefined.
header_value(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, V} -> V;
        false -> undefined
    end.

%% Emit the status line + headers (with `Transfer-Encoding: chunked`
%% prepended), then call the user's stream fun with a Send/2 callback.
%% Each Send call frames its data as one chunk; passing `fin` appends
%% the size-0 terminator. Caller-supplied headers must NOT set
%% Transfer-Encoding or Content-Length.
-spec stream_response(
    cactus_transport:socket(),
    cactus_http1:status(),
    cactus_http1:headers(),
    cactus_handler:stream_fun()
) -> ok | {error, term()}.
stream_response(Socket, Status, UserHeaders, Fun) ->
    Headers = [{~"transfer-encoding", ~"chunked"} | UserHeaders],
    Head = cactus_http1:response(Status, Headers, ~""),
    _ = cactus_transport:send(Socket, Head),
    Send = fun(Data, FinFlag) ->
        Chunk = [
            integer_to_binary(iolist_size(Data), 16),
            ~"\r\n",
            Data,
            ~"\r\n"
        ],
        Frame =
            case FinFlag of
                nofin -> Chunk;
                fin -> [Chunk, ~"0\r\n\r\n"]
            end,
        cactus_transport:send(Socket, Frame)
    end,
    _ = Fun(Send),
    ok.

-spec send_bad_request(cactus_transport:socket()) -> ok | {error, term()}.
send_bad_request(Socket) ->
    Resp = cactus_http1:response(
        400,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    cactus_transport:send(Socket, Resp).

-spec send_payload_too_large(cactus_transport:socket()) -> ok | {error, term()}.
send_payload_too_large(Socket) ->
    Resp = cactus_http1:response(
        413,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    cactus_transport:send(Socket, Resp).

-spec send_not_found(cactus_transport:socket()) -> ok | {error, term()}.
send_not_found(Socket) ->
    Resp = cactus_http1:response(
        404,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    cactus_transport:send(Socket, Resp).

-spec send_request_timeout(cactus_transport:socket()) -> ok | {error, term()}.
send_request_timeout(Socket) ->
    Resp = cactus_http1:response(
        408,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    cactus_transport:send(Socket, Resp).

-spec send_internal_error(cactus_transport:socket()) -> ok | {error, term()}.
send_internal_error(Socket) ->
    Resp = cactus_http1:response(
        500,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    cactus_transport:send(Socket, Resp).

%% --- WebSocket upgrade + frame loop ---

-spec upgrade_to_websocket(cactus_transport:socket(), cactus_http1:request(), module(), term()) ->
    ok | {error, term()}.
upgrade_to_websocket(Socket, Req, Mod, State) ->
    case cactus_ws:handshake_response(cactus_req:headers(Req)) of
        {ok, Status, RespHeaders, _} ->
            Resp = cactus_http1:response(Status, RespHeaders, ~""),
            %% If this send fails, the next recv inside ws_loop will return
            %% {error, _} and the loop ends cleanly — no separate handling.
            _ = cactus_transport:send(Socket, Resp),
            ws_loop(Socket, <<>>, Mod, State);
        {error, _} ->
            send_bad_request(Socket)
    end.

-spec ws_loop(cactus_transport:socket(), binary(), module(), term()) -> ok.
ws_loop(Socket, Buffer, Mod, State) ->
    case cactus_ws:parse_frame(Buffer) of
        {ok, Frame, NewBuffer} ->
            handle_ws_frame(Socket, NewBuffer, Mod, State, Frame);
        {more, _} ->
            case cactus_transport:recv(Socket, 0, infinity) of
                {ok, Data} ->
                    ws_loop(Socket, <<Buffer/binary, Data/binary>>, Mod, State);
                {error, _} ->
                    ok
            end;
        {error, _} ->
            ok
    end.

-spec handle_ws_frame(
    cactus_transport:socket(), binary(), module(), term(), cactus_ws:frame()
) -> ok.
handle_ws_frame(Socket, _Buffer, _Mod, _State, #{opcode := close}) ->
    _ = cactus_transport:send(Socket, cactus_ws:encode_frame(close, ~"", true)),
    ok;
handle_ws_frame(Socket, Buffer, Mod, State, #{opcode := ping, payload := P}) ->
    _ = cactus_transport:send(Socket, cactus_ws:encode_frame(pong, P, true)),
    ws_loop(Socket, Buffer, Mod, State);
handle_ws_frame(Socket, Buffer, Mod, State, #{opcode := pong}) ->
    %% Server is not pinging clients yet — pong from client is just dropped.
    ws_loop(Socket, Buffer, Mod, State);
handle_ws_frame(Socket, Buffer, Mod, State, Frame) ->
    case Mod:handle_frame(Frame, State) of
        {reply, OutFrames, NewState} ->
            _ = send_ws_frames(Socket, OutFrames),
            ws_loop(Socket, Buffer, Mod, NewState);
        {ok, NewState} ->
            ws_loop(Socket, Buffer, Mod, NewState);
        {close, _NewState} ->
            _ = cactus_transport:send(Socket, cactus_ws:encode_frame(close, ~"", true)),
            ok
    end.

-spec send_ws_frames(cactus_transport:socket(), [{cactus_ws:opcode(), iodata()}]) ->
    ok | {error, term()}.
send_ws_frames(Socket, OutFrames) ->
    Iodata = [cactus_ws:encode_frame(Op, Payload, true) || {Op, Payload} <- OutFrames],
    cactus_transport:send(Socket, Iodata).
