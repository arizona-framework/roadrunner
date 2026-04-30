-module(cactus_transport).
-moduledoc """
Tagged-socket transport abstraction over `gen_tcp` (and, in a follow-up
feature, `ssl`).

A socket is `{Module, RawSocket}` so callers don't have to know whether
they're talking to plain TCP or TLS. The first phase wires up only the
`gen_tcp` backend; adding the `{ssl, _}` tag is a non-breaking change
to this module.
""".

-export([
    listen/2,
    accept/1,
    controlling_process/2,
    recv/3,
    send/2,
    close/1,
    peername/1,
    port/1
]).

-export_type([socket/0]).

-type socket() :: {gen_tcp, gen_tcp:socket()}.

-doc "Open a listening socket. Options are passed verbatim to gen_tcp:listen/2.".
-spec listen(inet:port_number(), [gen_tcp:listen_option()]) ->
    {ok, socket()} | {error, term()}.
listen(Port, Opts) ->
    case gen_tcp:listen(Port, Opts) of
        {ok, S} -> {ok, {gen_tcp, S}};
        {error, _} = Err -> Err
    end.

-doc "Accept the next pending connection on a listening socket.".
-spec accept(socket()) -> {ok, socket()} | {error, term()}.
accept({gen_tcp, LSock}) ->
    case gen_tcp:accept(LSock) of
        {ok, S} -> {ok, {gen_tcp, S}};
        {error, _} = Err -> Err
    end.

-doc "Hand the controlling process for the underlying socket.".
-spec controlling_process(socket(), pid()) -> ok | {error, term()}.
controlling_process({gen_tcp, S}, Pid) ->
    gen_tcp:controlling_process(S, Pid).

-doc "Receive bytes from the socket.".
-spec recv(socket(), non_neg_integer(), timeout()) ->
    {ok, binary()} | {error, term()}.
recv({gen_tcp, S}, Len, Timeout) ->
    gen_tcp:recv(S, Len, Timeout).

-doc "Send bytes on the socket.".
-spec send(socket(), iodata()) -> ok | {error, term()}.
send({gen_tcp, S}, Data) ->
    gen_tcp:send(S, Data).

-doc "Close the socket.".
-spec close(socket()) -> ok.
close({gen_tcp, S}) ->
    _ = gen_tcp:close(S),
    ok.

-doc "Return the peer (`{IpAddress, Port}`) of an accepted connection.".
-spec peername(socket()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
peername({gen_tcp, S}) ->
    inet:peername(S).

-doc "Return the locally-bound port of a listening or connected socket.".
-spec port(socket()) -> {ok, inet:port_number()} | {error, term()}.
port({gen_tcp, S}) ->
    inet:port(S).
