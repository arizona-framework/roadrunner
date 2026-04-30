-module(cactus_conn).
-moduledoc """
HTTP/1.1 connection process — one per accepted TCP connection.

Reads bytes from the socket, drives `cactus_http1:parse_request/1`
incrementally, sends a hardcoded `200 Hello, cactus!` response on
success or `400 Bad Request` on parse failure, then closes.

This is the minimum end-to-end pipeline for slice 2; the handler
behaviour and routing arrive in slices 3–4.
""".

-export([start/2, parse_loop/2]).

-define(RECV_TIMEOUT, 5000).

-doc """
Spawn an unlinked connection process for the accepted `Socket` and the
chosen `Handler` module.

The caller (typically `cactus_acceptor`) must transfer socket
ownership via `gen_tcp:controlling_process/2` and then send the
process the atom `shoot` to release it.
""".
-spec start(gen_tcp:socket(), module()) -> {ok, pid()}.
start(Socket, Handler) ->
    Pid = proc_lib:spawn(fun() ->
        proc_lib:set_label(cactus_conn),
        receive
            shoot -> serve(Socket, Handler)
        end
    end),
    {ok, Pid}.

-spec serve(gen_tcp:socket(), module()) -> ok.
serve(Socket, Handler) ->
    Recv = fun() -> gen_tcp:recv(Socket, 0, ?RECV_TIMEOUT) end,
    _ =
        case parse_loop(<<>>, Recv) of
            {ok, Req, Body} -> handle_and_send(Socket, Handler, Req#{body => Body});
            {error, _} -> send_bad_request(Socket)
        end,
    _ = gen_tcp:close(Socket),
    ok.

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
