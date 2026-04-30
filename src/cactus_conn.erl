-module(cactus_conn).
-moduledoc """
HTTP/1.1 connection process — one per accepted TCP connection.

Reads bytes from the socket, drives `cactus_http1:parse_request/1`
incrementally, sends a hardcoded `200 Hello, cactus!` response on
success or `400 Bad Request` on parse failure, then closes.

This is the minimum end-to-end pipeline for slice 2; the handler
behaviour and routing arrive in slices 3–4.
""".

-export([start/2, parse_loop/2, read_body/4]).

-export_type([proto_opts/0, dispatch/0]).

-define(RECV_TIMEOUT, 5000).

-type dispatch() ::
    {handler, module()}
    | {router, cactus_router:compiled()}.

-type proto_opts() :: #{
    dispatch := dispatch(),
    max_content_length := non_neg_integer()
}.

-doc """
Spawn an unlinked connection process for the accepted `Socket` and the
shared `ProtoOpts` (handler module, body limits, ...).

The caller (typically `cactus_acceptor`) must transfer socket
ownership via `gen_tcp:controlling_process/2` and then send the
process the atom `shoot` to release it.
""".
-spec start(gen_tcp:socket(), proto_opts()) -> {ok, pid()}.
start(Socket, ProtoOpts) when is_map(ProtoOpts) ->
    Pid = proc_lib:spawn(fun() ->
        proc_lib:set_label(cactus_conn),
        receive
            shoot -> serve(Socket, ProtoOpts)
        end
    end),
    {ok, Pid}.

-spec serve(gen_tcp:socket(), proto_opts()) -> ok.
serve(Socket, #{dispatch := Dispatch, max_content_length := MaxCL}) ->
    Recv = fun() -> gen_tcp:recv(Socket, 0, ?RECV_TIMEOUT) end,
    _ =
        case parse_loop(<<>>, Recv) of
            {ok, Req, Buffered} ->
                case read_body(Req, Buffered, Recv, MaxCL) of
                    {ok, Body} ->
                        ReqWithBody = Req#{body => Body},
                        case resolve_handler(Dispatch, ReqWithBody) of
                            {ok, Handler, Bindings} ->
                                FullReq = ReqWithBody#{bindings => Bindings},
                                handle_and_send(Socket, Handler, FullReq);
                            not_found ->
                                send_not_found(Socket)
                        end;
                    {error, content_length_too_large} ->
                        send_payload_too_large(Socket);
                    {error, _} ->
                        send_bad_request(Socket)
                end;
            {error, _} ->
                send_bad_request(Socket)
        end,
    _ = gen_tcp:close(Socket),
    ok.

-spec resolve_handler(dispatch(), cactus_http1:request()) ->
    {ok, module(), cactus_router:bindings()} | not_found.
resolve_handler({handler, Mod}, _Req) ->
    {ok, Mod, #{}};
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

-spec handle_and_send(gen_tcp:socket(), module(), cactus_http1:request()) ->
    ok | {error, term()}.
handle_and_send(Socket, Handler, Req) ->
    {Status, Headers, Body} = Handler:handle(Req),
    Resp = cactus_http1:response(Status, Headers, Body),
    gen_tcp:send(Socket, Resp).

-spec send_bad_request(gen_tcp:socket()) -> ok | {error, term()}.
send_bad_request(Socket) ->
    Resp = cactus_http1:response(
        400,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    gen_tcp:send(Socket, Resp).

-spec send_payload_too_large(gen_tcp:socket()) -> ok | {error, term()}.
send_payload_too_large(Socket) ->
    Resp = cactus_http1:response(
        413,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    gen_tcp:send(Socket, Resp).

-spec send_not_found(gen_tcp:socket()) -> ok | {error, term()}.
send_not_found(Socket) ->
    Resp = cactus_http1:response(
        404,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    gen_tcp:send(Socket, Resp).
