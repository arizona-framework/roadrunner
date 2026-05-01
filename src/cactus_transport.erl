-module(cactus_transport).
-moduledoc """
Tagged-socket transport abstraction over `gen_tcp`, `ssl`, and a
`fake` test backend.

A socket is `{Module, RawSocket}` so callers don't have to know whether
they're talking to plain TCP, TLS, or a test fixture.

The `{fake, Pid}` variant is a per-connection test helper: every
`send/2`, `recv/3`, `setopts/2`, and `close/1` call dispatches to
`Pid` as an Erlang message, letting tests drive a `cactus_conn`
byte-by-byte without spinning up a listener. See
`cactus_transport_tests` for the message protocol.

## Active-mode reads

`setopts/2` + `messages/1` switch the underlying socket to active
mode (`[{active, once}]` / `[{active, N}]`) so the controlling
process receives data as `info` events instead of blocking in
`recv/3`. This is what lets `gen_statem`'s `hibernate` action fire
between events — passive recv holds the process inside a state
callback indefinitely, so hibernation has no window to run. Active
mode is the prerequisite for WebSocket / long-keep-alive memory
optimization. See `messages/1` for the per-transport tag triples.

## TLS defaults

`default_tls_opts/0` returns a hardened option list that
`cactus_listener` merges underneath user-supplied `tls` opts (user
values win for any key they specify). The defaults are aligned with
the upstream OTP `ssl_hardening.md` guide: TLS 1.2/1.3 only,
`honor_cipher_order`, `client_renegotiation` off, AEAD-only
ECDHE-or-1.3 cipher list filtered through `ssl:filter_cipher_suites/2`,
and the OTP-default signature algorithms / supported groups
re-asserted so we don't drift if upstream lowers standards. OCSP
stapling is intentionally absent — `ssl` does not support
server-side stapling at the time of writing.
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
    port/1,
    sendfile/4,
    setopts/2,
    messages/1,
    default_tls_opts/0,
    apply_tls_defaults/1
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

-doc """
Send `Length` bytes of `Filename` starting at `Offset` over the
socket.

For `{gen_tcp, _}`: dispatches `file:sendfile/5` for kernel-space
zero-copy on Linux/BSD/macOS. For `{ssl, _}`: TLS hides the
plaintext from the kernel sendfile path, so we fall back to a
chunked read+send loop (64 KiB per chunk). For `{fake, _}`:
reads the slice and forwards it as a single `cactus_fake_send`
message so unit tests see one bytes payload.
""".
-spec sendfile(socket(), file:filename_all(), non_neg_integer(), non_neg_integer()) ->
    ok | {error, term()}.
sendfile(Sock, Filename, Offset, Length) ->
    case file:open(Filename, [read, raw, binary]) of
        {ok, File} ->
            try
                do_sendfile(Sock, File, Offset, Length)
            after
                ok = file:close(File)
            end;
        {error, _} = Err ->
            Err
    end.

-spec do_sendfile(
    socket(), file:io_device(), non_neg_integer(), non_neg_integer()
) -> ok | {error, term()}.
do_sendfile({gen_tcp, S}, File, Offset, Length) ->
    case file:sendfile(File, S, Offset, Length, []) of
        {ok, _} -> ok;
        {error, _} = Err -> Err
    end;
do_sendfile({ssl, S}, File, Offset, Length) ->
    sendfile_chunked(fun(Data) -> ssl:send(S, Data) end, File, Offset, Length);
do_sendfile({fake, Pid}, File, Offset, Length) ->
    {ok, Bytes} = file:pread(File, Offset, Length),
    Pid ! {cactus_fake_send, self(), Bytes},
    ok.

%% TLS fallback: positioned read + ssl:send in 64 KiB chunks. The file
%% is freshly opened with `[read, raw, binary]` so positioning and
%% reading are infallible — read errors and position errors here would
%% be programmer error, not a runtime case.
-spec sendfile_chunked(
    fun((iodata()) -> ok | {error, term()}),
    file:io_device(),
    non_neg_integer(),
    non_neg_integer()
) -> ok | {error, term()}.
sendfile_chunked(SendFun, File, Offset, Length) ->
    {ok, _} = file:position(File, {bof, Offset}),
    sendfile_chunked_loop(SendFun, File, Length).

-spec sendfile_chunked_loop(
    fun((iodata()) -> ok | {error, term()}),
    file:io_device(),
    non_neg_integer()
) -> ok | {error, term()}.
sendfile_chunked_loop(_SendFun, _File, 0) ->
    ok;
sendfile_chunked_loop(SendFun, File, Remaining) ->
    Chunk = min(Remaining, 65536),
    case file:read(File, Chunk) of
        eof ->
            %% Length exceeds file size — caller asked for more bytes
            %% than the file holds. Stop here; the truncated body is
            %% on the wire already.
            ok;
        {ok, Data} ->
            case SendFun(Data) of
                ok -> sendfile_chunked_loop(SendFun, File, Remaining - byte_size(Data));
                {error, _} = Err -> Err
            end
    end.

-doc """
Set socket options on the underlying transport.

Used primarily to switch a socket to active mode
(`[{active, once}]` / `[{active, N}]`) so the controlling process
receives data as `info` events instead of blocking in `recv/3`. With
active mode the gen_statem driving the conn returns to its main loop
between events, which lets `gen_statem`'s `hibernate` action and
`{hibernate_after, _}` start option actually fire — passive recv
holds the process inside a state callback indefinitely, so neither
hibernation primitive has a window to run.

For `{fake, Pid}`: forwards `{cactus_fake_setopts, ConnPid, Opts}`
to the sink so test scripts can react to the conn arming itself for
the next read (e.g. by delivering `{cactus_fake_data, _, Bytes}`).
""".
-spec setopts(socket(), [gen_tcp:option()]) -> ok | {error, term()}.
setopts({gen_tcp, S}, Opts) ->
    inet:setopts(S, Opts);
setopts({ssl, S}, Opts) ->
    ssl:setopts(S, Opts);
setopts({fake, Pid}, Opts) ->
    %% Simulate "kernel reports socket closed" via a dead sink so
    %% tests can drive the `{error, _}` branch of active-mode arming
    %% without a real TCP RST. Real sockets return `{error, einval}`
    %% in this scenario; we mirror that.
    case is_process_alive(Pid) of
        true ->
            Pid ! {cactus_fake_setopts, self(), Opts},
            ok;
        false ->
            {error, einval}
    end.

-doc """
Return the `{Data, Closed, Error}` atom triple identifying the
active-mode message tags for this transport. Use this to
pattern-match incoming events in a state callback after switching
the socket to `[{active, once}]`:

```erlang
{Data, Closed, Error} = cactus_transport:messages(Socket),
%% in handle_event/4:
handle_event(info, Msg, State, Data0) ->
    case Msg of
        {Data, _Sock, Bytes}    -> ... ;   %% bytes arrived
        {Closed, _Sock}         -> ... ;   %% peer closed
        {Error, _Sock, _Reason} -> ...     %% transport error
    end.
```

Tag conventions:

- `{gen_tcp, _}` → `{tcp, tcp_closed, tcp_error}` (per `inet:tcp_messages/1`)
- `{ssl, _}`    → `{ssl, ssl_closed, ssl_error}` (per `ssl:tcp_messages/1`)
- `{fake, _}`   → `{cactus_fake_data, cactus_fake_closed, cactus_fake_error}`
""".
-spec messages(socket()) -> {atom(), atom(), atom()}.
messages({gen_tcp, _}) -> {tcp, tcp_closed, tcp_error};
messages({ssl, _}) -> {ssl, ssl_closed, ssl_error};
messages({fake, _}) -> {cactus_fake_data, cactus_fake_closed, cactus_fake_error}.

-doc """
Hardened TLS server defaults — see the moduledoc.

The list is computed at call time so it tracks the OTP version
the listener is started under (`ssl:cipher_suites/2`,
`ssl:signature_algs/2`, `ssl:groups/1`).
""".
-spec default_tls_opts() -> [ssl:tls_server_option()].
default_tls_opts() ->
    [
        {versions, ['tlsv1.3', 'tlsv1.2']},
        {honor_cipher_order, true},
        {client_renegotiation, false},
        {secure_renegotiate, true},
        {early_data, disabled},
        {reuse_sessions, true},
        {ciphers, default_ciphers()},
        {signature_algs, default_signature_algs()},
        {supported_groups, ssl:groups(default)},
        {alpn_preferred_protocols, [~"http/1.1"]}
    ].

-doc """
Merge user-supplied `tls` opts with `default_tls_opts/0`.

User values win: any 2-tuple option the caller already specified is
kept verbatim and the corresponding default is dropped.
""".
-spec apply_tls_defaults([ssl:tls_server_option()]) -> [ssl:tls_server_option()].
apply_tls_defaults(UserOpts) ->
    UserKeys = [element(1, Opt) || Opt <- UserOpts, is_tuple(Opt), tuple_size(Opt) =:= 2],
    Defaults = [
        Opt
     || {Key, _} = Opt <- default_tls_opts(),
        not lists:member(Key, UserKeys)
    ],
    Defaults ++ UserOpts.

%% --- internal ---

%% AEAD-only and (for TLS 1.2) ECDHE-only — modern + forward secrecy.
%% `key_exchange => any` is the TLS 1.3 marker (no separate key exchange).
-spec default_ciphers() -> [ssl:erl_cipher_suite()].
default_ciphers() ->
    Suites = ssl:cipher_suites(default, 'tlsv1.3') ++ ssl:cipher_suites(default, 'tlsv1.2'),
    Filters = [
        {key_exchange, fun
            (any) -> true;
            (ecdhe_ecdsa) -> true;
            (ecdhe_rsa) -> true;
            (_) -> false
        end},
        {mac, fun(M) -> M =:= aead end}
    ],
    ssl:filter_cipher_suites(Suites, Filters).

%% TLS 1.3 algs first (preferred), TLS 1.2 algs appended uniquely.
%% OTP's `default` set already excludes SHA-1.
-spec default_signature_algs() -> ssl:signature_algs().
default_signature_algs() ->
    Algs13 = ssl:signature_algs(default, 'tlsv1.3'),
    Algs12 = ssl:signature_algs(default, 'tlsv1.2'),
    Algs13 ++ [A || A <- Algs12, not lists:member(A, Algs13)].
