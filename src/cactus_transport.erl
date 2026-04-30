-module(cactus_transport).
-moduledoc """
Tagged-socket transport abstraction over `gen_tcp`, `ssl`, and a
`fake` test backend.

A socket is `{Module, RawSocket}` so callers don't have to know whether
they're talking to plain TCP, TLS, or a test fixture.

The `{fake, Pid}` variant is a per-connection test helper: every
`send/2`, `recv/3`, and `close/1` call dispatches to `Pid` as an
Erlang message, letting tests drive a `cactus_conn` byte-by-byte
without spinning up a listener. See `cactus_transport_tests` for the
message protocol.
""".

-export([
    listen/2,
    listen_tls/2,
    accept/1,
    controlling_process/2,
    recv/3,
    send/2,
    close/1,
    peername/1,
    port/1
]).

-export_type([socket/0]).

-type socket() ::
    {gen_tcp, gen_tcp:socket()}
    | {ssl, ssl:sslsocket()}
    | {fake, pid()}.

-doc "Open a plain TCP listening socket. Options pass verbatim to gen_tcp:listen/2.".
-spec listen(inet:port_number(), [gen_tcp:listen_option()]) ->
    {ok, socket()} | {error, term()}.
listen(Port, Opts) ->
    case gen_tcp:listen(Port, Opts) of
        {ok, S} -> {ok, {gen_tcp, S}};
        {error, _} = Err -> Err
    end.

-doc """
Open a TLS listening socket. The caller is responsible for ensuring
the `ssl` application is started (typically `application:ensure_all_started(ssl)`).

`Opts` is the list passed to `ssl:listen/2` — `cert`, `key`/`keyfile`,
`cacerts`, etc. Performs the TCP listen + TLS context bind in one call;
each `accept/1` then runs the per-connection handshake.
""".
-spec listen_tls(inet:port_number(), [ssl:tls_server_option() | gen_tcp:listen_option()]) ->
    {ok, socket()} | {error, term()}.
listen_tls(Port, Opts) ->
    case ssl:listen(Port, Opts) of
        {ok, S} -> {ok, {ssl, S}};
        {error, _} = Err -> Err
    end.

-doc "Accept the next pending connection. For TLS, runs the handshake before returning.".
-spec accept(socket()) -> {ok, socket()} | {error, term()}.
accept({gen_tcp, LSock}) ->
    case gen_tcp:accept(LSock) of
        {ok, S} -> {ok, {gen_tcp, S}};
        {error, _} = Err -> Err
    end;
accept({ssl, LSock}) ->
    case ssl:transport_accept(LSock) of
        {ok, Pre} ->
            case ssl:handshake(Pre) of
                {ok, S} -> {ok, {ssl, S}};
                {error, _} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end.

-doc "Hand the controlling process for the underlying socket.".
-spec controlling_process(socket(), pid()) -> ok | {error, term()}.
controlling_process({gen_tcp, S}, Pid) ->
    gen_tcp:controlling_process(S, Pid);
controlling_process({ssl, S}, Pid) ->
    ssl:controlling_process(S, Pid);
controlling_process({fake, _Pid}, _NewPid) ->
    ok.

-doc """
Receive bytes from the socket.

For `{fake, Pid}`: sends `{cactus_fake_recv, ConnPid, Length, Timeout}`
to `Pid` and blocks waiting for a `{cactus_fake_recv_reply, Result}`
message back. The test driver is expected to reply with `{ok, Bytes}`
or `{error, Reason}` to drive the conn byte-by-byte.
""".
-spec recv(socket(), non_neg_integer(), timeout()) ->
    {ok, binary()} | {error, term()}.
recv({gen_tcp, S}, Len, Timeout) ->
    gen_tcp:recv(S, Len, Timeout);
recv({ssl, S}, Len, Timeout) ->
    ssl:recv(S, Len, Timeout);
recv({fake, Pid}, Len, Timeout) ->
    Pid ! {cactus_fake_recv, self(), Len, Timeout},
    receive
        {cactus_fake_recv_reply, Result} -> Result
    end.

-doc """
Send bytes on the socket.

For `{fake, Pid}`: forwards `{cactus_fake_send, ConnPid, IoData}` to
`Pid` and returns `ok`. `IoData` is left unflattened so tests can see
what the caller actually constructed.
""".
-spec send(socket(), iodata()) -> ok | {error, term()}.
send({gen_tcp, S}, Data) ->
    gen_tcp:send(S, Data);
send({ssl, S}, Data) ->
    ssl:send(S, Data);
send({fake, Pid}, Data) ->
    Pid ! {cactus_fake_send, self(), Data},
    ok.

-doc """
Close the socket.

For `{fake, Pid}`: forwards `{cactus_fake_close, ConnPid}` to `Pid`.
""".
-spec close(socket()) -> ok.
close({gen_tcp, S}) ->
    _ = gen_tcp:close(S),
    ok;
close({ssl, S}) ->
    _ = ssl:close(S),
    ok;
close({fake, Pid}) ->
    Pid ! {cactus_fake_close, self()},
    ok.

-doc """
Return the peer (`{IpAddress, Port}`) of an accepted connection.

For `{fake, _}`: returns a stub `{127, 0, 0, 1}, 0` so handlers that
read `cactus_req:peer/1` get a sensible value.
""".
-spec peername(socket()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
peername({gen_tcp, S}) ->
    inet:peername(S);
peername({ssl, S}) ->
    ssl:peername(S);
peername({fake, _Pid}) ->
    {ok, {{127, 0, 0, 1}, 0}}.

-doc "Return the locally-bound port of a listening or connected socket.".
-spec port(socket()) -> {ok, inet:port_number()} | {error, term()}.
port({gen_tcp, S}) ->
    inet:port(S);
port({ssl, S}) ->
    case ssl:sockname(S) of
        {ok, {_Addr, Port}} -> {ok, Port};
        {error, _} = Err -> Err
    end.
