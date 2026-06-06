-module(roadrunner_quic_socket).
-moduledoc false.

%% The gen_udp baseline for the native QUIC transport: open a UDP socket,
%% receive whole datagrams, send datagrams. A thin tagged wrapper (like
%% `roadrunner_transport`), not a process; the listener (D3) and
%% connection (D2) processes own the socket and call these primitives.
%%
%% Deliberately just a byte mover. The RFC 9000 §8.1 anti-amplification
%% accounting (`roadrunner_quic_amp`), the §14 padding of Initial
%% datagrams to 1200 bytes, and the splitting of coalesced packets within
%% a datagram are all per-connection concerns owned by the connection
%% send/receive pipeline, not the shared socket. The socket delivers each
%% UDP datagram whole, with its source address.

-export([open/1, open/2, send/4, recv/2, close/1, sockname/1]).

-export_type([socket/0, open_opts/0]).

-opaque socket() :: {gen_udp, gen_udp:socket()}.

-type open_opts() :: #{
    recbuf => pos_integer(), sndbuf => pos_integer(), reuseport => boolean()
}.

%% Larger than the OS default, so a burst of datagrams is not dropped
%% before the receiver drains them. Raise via `open/2` for a busy server.
-define(DEFAULT_RECBUF, 1048576).
-define(DEFAULT_SNDBUF, 1048576).

-doc "Open a UDP socket on `Port` with the default buffer sizes.".
-spec open(inet:port_number()) -> {ok, socket()} | {error, term()}.
open(Port) ->
    open(Port, #{}).

-doc """
Open a UDP socket on `Port`. The socket is binary and passive
(`{active, false}`), with `reuseaddr` set; `recbuf` and `sndbuf` may be
overridden via `Opts`. Port 0 picks an ephemeral port (read it back with
`sockname/1`).

Set `reuseport` to `true` to enable `SO_REUSEPORT`, which lets a pool
of sockets share one concrete port with kernel datagram fan-out (the
shape the listener pool uses); it defaults to `false` for a lone socket.
""".
-spec open(inet:port_number(), open_opts()) -> {ok, socket()} | {error, term()}.
open(Port, Opts) ->
    #{recbuf := RecBuf, sndbuf := SndBuf, reuseport := ReusePort} = validate_opts(Opts),
    SocketOpts = [
        binary,
        {active, false},
        {reuseaddr, true},
        {reuseport, ReusePort},
        {recbuf, RecBuf},
        {sndbuf, SndBuf}
    ],
    case gen_udp:open(Port, SocketOpts) of
        {ok, Socket} -> {ok, {gen_udp, Socket}};
        {error, _} = Error -> Error
    end.

-doc "Send `Data` as one UDP datagram to `Ip`/`Port`.".
-spec send(socket(), inet:ip_address(), inet:port_number(), iodata()) -> ok | {error, term()}.
send({gen_udp, Socket}, Ip, Port, Data) ->
    gen_udp:send(Socket, Ip, Port, Data).

-doc """
Receive the next whole datagram, blocking up to `Timeout` milliseconds.
Returns the source address and the datagram bytes, or `{error, timeout}`
when none arrives in time.
""".
-spec recv(socket(), timeout()) ->
    {ok, {inet:ip_address(), inet:port_number()}, binary()} | {error, term()}.
recv({gen_udp, Socket}, Timeout) ->
    %% The 3-tuple shape assumes no ancillary-data options (pktinfo,
    %% recvtos, ...) are enabled; gen_udp returns a 4-tuple with an
    %% AncData element when they are, and open/2 enables none.
    case gen_udp:recv(Socket, 0, Timeout) of
        {ok, {Ip, Port, Data}} -> {ok, {Ip, Port}, Data};
        {error, _} = Error -> Error
    end.

-doc "Close the socket.".
-spec close(socket()) -> ok.
close({gen_udp, Socket}) ->
    gen_udp:close(Socket).

-doc "The socket's local address and port.".
-spec sockname(socket()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
sockname({gen_udp, Socket}) ->
    inet:sockname(Socket).

%% =============================================================================
%% Internal
%% =============================================================================

%% Merge the caller's options over the defaults, rejecting unknown keys
%% and out-of-range values (mirrors the listener-opt validation idiom).
-spec validate_opts(open_opts()) ->
    #{recbuf := pos_integer(), sndbuf := pos_integer(), reuseport := boolean()}.
validate_opts(Opts) ->
    Defaults = #{recbuf => ?DEFAULT_RECBUF, sndbuf => ?DEFAULT_SNDBUF, reuseport => false},
    maps:fold(fun validate_opt/3, Defaults, Opts).

-spec validate_opt(atom(), term(), map()) -> map().
validate_opt(recbuf, Value, Acc) when is_integer(Value), Value > 0 ->
    Acc#{recbuf => Value};
validate_opt(sndbuf, Value, Acc) when is_integer(Value), Value > 0 ->
    Acc#{sndbuf => Value};
validate_opt(reuseport, Value, Acc) when is_boolean(Value) ->
    Acc#{reuseport => Value};
validate_opt(Key, Value, _Acc) ->
    error({invalid_quic_socket_opt, Key, Value}).
