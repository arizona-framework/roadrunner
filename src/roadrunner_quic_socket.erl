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
%%
%% On Linux the socket also enables UDP generic segmentation offload
%% (UDP_SEGMENT, kernel 4.18+) with a 1200-byte segment, so `send_batch/4`
%% hands a run of datagrams to the kernel in one call and the kernel splits
%% it back into the same datagrams. That needs every datagram sent on the
%% socket to be at most the segment size, which holds since the QUIC stack
%% never builds a datagram larger than 1200 bytes. Where the option is not
%% available the socket sends one datagram per call, as `send/4` does.

-export([
    open/1,
    open/2,
    send/4,
    send_batch/4,
    recv/2,
    activate/1,
    activate/2,
    from_message/2,
    close/1,
    sockname/1
]).
%% Exported for direct unit coverage of the non-Linux and refused-option
%% branches, which the Linux test host cannot reach through open/2.
-export([gso_segment/3]).

-export_type([socket/0, open_opts/0]).

%% The gen_udp socket and its GSO segment size, or `none` without GSO.
-opaque socket() :: {gen_udp, gen_udp:socket(), pos_integer() | none}.

-type active() :: once | false | pos_integer().

-type open_opts() :: #{
    recbuf => pos_integer(),
    sndbuf => pos_integer(),
    reuseport => boolean(),
    active => active(),
    ip => inet:ip_address(),
    gso => boolean()
}.

%% Larger than the OS default, so a burst of datagrams is not dropped
%% before the receiver drains them. Raise via `open/2` for a busy server.
-define(DEFAULT_RECBUF, 1048576).
-define(DEFAULT_SNDBUF, 1048576).

%% Linux UDP_SEGMENT (SOL_UDP 17, option 103): the GSO segment size, the
%% largest datagram the QUIC stack builds (RFC 9000 §14).
-define(SOL_UDP, 17).
-define(UDP_SEGMENT, 103).
-define(GSO_SEGMENT, 1200).
%% Datagrams per GSO send: within the 64 segments every UDP_SEGMENT kernel
%% accepts and the 65507-byte UDP payload limit (64 x 1200 = 76800 would
%% exceed it, so the byte limit caps a run of full datagrams at 54).
-define(GSO_MAX_SEGMENTS, 54).

-doc "Open a UDP socket on `Port` with the default buffer sizes.".
-spec open(inet:port_number()) -> {ok, socket()} | {error, term()}.
open(Port) ->
    open(Port, #{}).

-doc """
Open a UDP socket on `Port`. The socket is binary, with `reuseaddr` set;
`recbuf` and `sndbuf` may be overridden via `Opts`. Port 0 picks an ephemeral
port (read it back with `sockname/1`).

`active` defaults to `false` (passive: drain with `recv/2`). Set it to `once`
or a positive integer `N` for the listener: each datagram is then delivered to
the controlling process as one message, parsed with `from_message/2`, so the
listener can interleave datagrams with monitor/system messages in a single
receive loop. With `N`, the socket delivers up to `N` datagrams and then one
`{udp_passive, _}` message (`from_message/2` returns `passive`); re-arming once
per `N` datagrams with `activate/2` instead of once per datagram with
`activate/1` amortizes the re-arm syscall while keeping the mailbox bounded.

Set `reuseport` to `true` to enable `SO_REUSEPORT`, which lets a pool of
sockets share one concrete port with kernel datagram fan-out (the shape the
listener pool uses); it defaults to `false` for a lone socket.

Set `ip` to a specific local address (e.g. `{127,0,0,1}`) to bind that
interface only; unset binds all interfaces.
""".
-spec open(inet:port_number(), open_opts()) -> {ok, socket()} | {error, term()}.
open(Port, Opts) ->
    Validated = validate_opts(Opts),
    #{recbuf := RecBuf, sndbuf := SndBuf, reuseport := ReusePort, active := Active} = Validated,
    BaseOpts = [
        binary,
        {active, Active},
        {reuseaddr, true},
        {reuseport, ReusePort},
        {recbuf, RecBuf},
        {sndbuf, SndBuf}
    ],
    %% Bind a specific interface only when `ip` was set, so the default
    %% binds all interfaces exactly as before.
    SocketOpts =
        case Validated of
            #{ip := IP} -> [{ip, IP} | BaseOpts];
            #{} -> BaseOpts
        end,
    case gen_udp:open(Port, SocketOpts) of
        {ok, Socket} -> {ok, {gen_udp, Socket, gso_segment(Socket, Validated, os:type())}};
        {error, _} = Error -> Error
    end.

%% Enable GSO on Linux unless the caller turned it off; a kernel without
%% UDP_SEGMENT rejects the option, and the socket then sends one datagram
%% per call.
-spec gso_segment(gen_udp:socket(), #{gso := boolean(), _ => _}, {atom(), atom()}) ->
    pos_integer() | none.
gso_segment(Socket, #{gso := true}, {unix, linux}) ->
    Opt = {raw, ?SOL_UDP, ?UDP_SEGMENT, <<?GSO_SEGMENT:32/native>>},
    case inet:setopts(Socket, [Opt]) of
        ok -> ?GSO_SEGMENT;
        {error, _} -> none
    end;
gso_segment(_Socket, _Opts, _OsType) ->
    none.

-doc "Send `Data` as one UDP datagram to `Ip`/`Port`.".
-spec send(socket(), inet:ip_address(), inet:port_number(), iodata()) -> ok | {error, term()}.
send({gen_udp, Socket, _Segment}, Ip, Port, Data) ->
    gen_udp:send(Socket, Ip, Port, Data).

-doc """
Send each of `Datagrams` as its own UDP datagram to `Ip`/`Port`, in order.
With GSO, a run of full-size datagrams (the last one may be shorter) goes out
in one call; a run the kernel refuses is resent a datagram at a time. Send
errors are not reported, as for a lost datagram.
""".
-spec send_batch(socket(), inet:ip_address(), inet:port_number(), [binary()]) -> ok.
send_batch({gen_udp, Socket, none}, Ip, Port, Datagrams) ->
    send_each(Socket, Ip, Port, Datagrams);
send_batch({gen_udp, Socket, Segment}, Ip, Port, Datagrams) ->
    send_runs(Socket, Ip, Port, Segment, Datagrams).

-spec send_runs(gen_udp:socket(), inet:ip_address(), inet:port_number(), pos_integer(), [binary()]) ->
    ok.
send_runs(_Socket, _Ip, _Port, _Segment, []) ->
    ok;
send_runs(Socket, Ip, Port, Segment, [Datagram]) ->
    _ = gen_udp:send(Socket, Ip, Port, Datagram),
    send_runs(Socket, Ip, Port, Segment, []);
send_runs(Socket, Ip, Port, Segment, Datagrams) ->
    {Run, Rest} = take_run(Datagrams, Segment, ?GSO_MAX_SEGMENTS),
    case gen_udp:send(Socket, Ip, Port, Run) of
        ok -> ok;
        {error, _} -> send_each(Socket, Ip, Port, Run)
    end,
    send_runs(Socket, Ip, Port, Segment, Rest).

%% The next GSO run: full-size datagrams, ended by a shorter one (which the
%% kernel takes as the last segment) or by the segment cap.
-spec take_run([binary()], pos_integer(), non_neg_integer()) -> {[binary()], [binary()]}.
take_run([Datagram | Rest], Segment, Left) when Left > 1, byte_size(Datagram) =:= Segment ->
    {Run, Tail} = take_run(Rest, Segment, Left - 1),
    {[Datagram | Run], Tail};
take_run([Datagram | Rest], _Segment, _Left) ->
    {[Datagram], Rest};
take_run([], _Segment, _Left) ->
    {[], []}.

-spec send_each(gen_udp:socket(), inet:ip_address(), inet:port_number(), [binary()]) -> ok.
send_each(Socket, Ip, Port, [Datagram | Rest]) ->
    _ = gen_udp:send(Socket, Ip, Port, Datagram),
    send_each(Socket, Ip, Port, Rest);
send_each(_Socket, _Ip, _Port, []) ->
    ok.

-doc """
Receive the next whole datagram, blocking up to `Timeout` milliseconds.
Returns the source address and the datagram bytes, or `{error, timeout}`
when none arrives in time.
""".
-spec recv(socket(), timeout()) ->
    {ok, {inet:ip_address(), inet:port_number()}, binary()} | {error, term()}.
recv({gen_udp, Socket, _Segment}, Timeout) ->
    %% The 3-tuple shape assumes no ancillary-data options (pktinfo,
    %% recvtos, ...) are enabled; gen_udp returns a 4-tuple with an
    %% AncData element when they are, and open/2 enables none.
    case gen_udp:recv(Socket, 0, Timeout) of
        {ok, {Ip, Port, Data}} -> {ok, {Ip, Port}, Data};
        {error, _} = Error -> Error
    end.

-doc """
Re-arm a socket for one more datagram (`{active, once}`). Re-arms after a single
datagram; for batched re-arming use `activate/2`.
""".
-spec activate(socket()) -> ok | {error, term()}.
activate(Socket) ->
    activate(Socket, once).

-doc """
Re-arm a socket with the given active mode: `once` for one more datagram, or a
positive integer `N` to deliver up to `N` datagrams before the next
`{udp_passive, _}`. The listener re-arms with its `N` on each `passive` so the
re-arm syscall is paid once per `N` datagrams, not once per datagram.
""".
-spec activate(socket(), once | pos_integer()) -> ok | {error, term()}.
activate({gen_udp, Socket, _Segment}, Active) ->
    inet:setopts(Socket, [{active, Active}]).

-doc """
Parse a mailbox message from an active socket: returns the source address and
datagram bytes for this socket's data message, `passive` for its
`{udp_passive, _}` budget-exhausted notice (the loop should re-arm with
`activate/2`), or `ignore` for anything else (a different socket's data, a
monitor `DOWN`, a system message), so the listener loop can dispatch the rest
itself.
""".
-spec from_message(socket(), term()) ->
    {ok, {inet:ip_address(), inet:port_number()}, binary()} | passive | ignore.
from_message({gen_udp, Socket, _Segment}, {udp, Socket, Ip, Port, Data}) ->
    {ok, {Ip, Port}, Data};
from_message({gen_udp, Socket, _Segment}, {udp_passive, Socket}) ->
    passive;
from_message(_Socket, _Message) ->
    ignore.

-doc "Close the socket.".
-spec close(socket()) -> ok.
close({gen_udp, Socket, _Segment}) ->
    gen_udp:close(Socket).

-doc "The socket's local address and port.".
-spec sockname(socket()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
sockname({gen_udp, Socket, _Segment}) ->
    inet:sockname(Socket).

%% =============================================================================
%% Internal
%% =============================================================================

%% Merge the caller's options over the defaults, rejecting unknown keys
%% and out-of-range values (mirrors the listener-opt validation idiom).
-spec validate_opts(open_opts()) ->
    #{
        recbuf := pos_integer(),
        sndbuf := pos_integer(),
        reuseport := boolean(),
        active := active(),
        ip => inet:ip_address(),
        gso := boolean()
    }.
validate_opts(Opts) ->
    Defaults = #{
        recbuf => ?DEFAULT_RECBUF,
        sndbuf => ?DEFAULT_SNDBUF,
        reuseport => false,
        active => false,
        gso => true
    },
    maps:fold(fun validate_opt/3, Defaults, Opts).

-spec validate_opt(atom(), term(), map()) -> map().
validate_opt(recbuf, Value, Acc) when is_integer(Value), Value > 0 ->
    Acc#{recbuf => Value};
validate_opt(sndbuf, Value, Acc) when is_integer(Value), Value > 0 ->
    Acc#{sndbuf => Value};
validate_opt(reuseport, Value, Acc) when is_boolean(Value) ->
    Acc#{reuseport => Value};
validate_opt(active, Value, Acc) when Value =:= once; Value =:= false ->
    Acc#{active => Value};
validate_opt(active, Value, Acc) when is_integer(Value), Value > 0 ->
    Acc#{active => Value};
validate_opt(ip, Value, Acc) when is_tuple(Value) ->
    Acc#{ip => Value};
validate_opt(gso, Value, Acc) when is_boolean(Value) ->
    Acc#{gso => Value};
validate_opt(Key, Value, _Acc) ->
    error({invalid_quic_socket_opt, Key, Value}).
