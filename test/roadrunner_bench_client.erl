-module(roadrunner_bench_client).
-moduledoc """
Pure-Erlang HTTP client for the bench / stress / profile harness.

Drives `h1` over plain TCP and `h2` over TLS+ALPN against a real
roadrunner listener (or any RFC-conformant HTTP server). One
connection per `open/3`; many `request/5` calls in a tight loop
share the same connection and share HPACK state for h2.

`h3` is reserved as a stub clause so the bench only has to track a
single client surface across protocol versions; switching the
clause body to `quicer:connect` lands h3 support in one focused
PR when QUIC arrives.

## Why pure-Erlang and not h2load

Roadrunner's stance is "no external runtime deps unless stdlib
genuinely can't" — `telemetry` is the only runtime dep. The bench
is dev-only but a same-language driver removes a class of "tool
not installed" error reports, lets the bench reuse the in-tree
h2 codec (which is already 100% covered + dialyzer-clean), and
keeps perf measurements honest because client and server share
a measurement model (per-request nanosecond timing → real
percentiles).

The previous attempt at this stalled because of a server-side
TCP Nagle interaction that capped h2 keep-alive latency at ~50
ms. That's now fixed at the listener layer
(`roadrunner_listener:base_listen_opts/0`) — see
`docs/h2_loadgen_artifact.md`.
""".

-export([open/3, request/5, close/1]).
-export_type([conn/0, protocol/0]).

%% RFC 9113 §3.4 client connection preface.
-define(PREFACE, ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").
%% RFC 9113 §6.5.2 default frame size cap (we never request larger).
-define(MAX_FRAME_SIZE, 16384).

-type protocol() :: h1 | h2 | h3.

-record(h1_conn, {
    sock :: gen_tcp:socket(),
    buf = <<>> :: binary()
}).

-record(h2_conn, {
    sock :: ssl:sslsocket(),
    buf = <<>> :: binary(),
    enc :: roadrunner_http2_hpack:context(),
    dec :: roadrunner_http2_hpack:context(),
    next_stream_id = 1 :: pos_integer(),
    authority :: binary()
}).

-type conn() :: #h1_conn{} | #h2_conn{}.

-doc """
Open a connection. For `h2` performs the full preface + initial
SETTINGS exchange before returning so the first `request/5` can
go straight to a HEADERS frame.
""".
-spec open(inet:hostname() | inet:ip_address(), inet:port_number(), protocol()) ->
    {ok, conn()} | {error, term()}.
open(Host, Port, h1) ->
    HostArg = host_arg(Host),
    case gen_tcp:connect(HostArg, Port, [binary, {active, false}, {nodelay, true}], 5000) of
        {ok, Sock} -> {ok, #h1_conn{sock = Sock}};
        {error, _} = E -> E
    end;
open(Host, Port, h2) ->
    SslOpts = [
        binary,
        {active, false},
        {nodelay, true},
        {alpn_advertised_protocols, [~"h2"]},
        {verify, verify_none},
        {server_name_indication, disable}
    ],
    HostArg = host_arg(Host),
    case ssl:connect(HostArg, Port, SslOpts, 5000) of
        {ok, Sock} ->
            ok = ssl:send(Sock, [?PREFACE, h2_empty_settings_frame()]),
            case h2_handshake(Sock, <<>>, false, false) of
                {ok, Buf} ->
                    {ok, #h2_conn{
                        sock = Sock,
                        buf = Buf,
                        enc = roadrunner_http2_hpack:new_encoder(4096),
                        dec = roadrunner_http2_hpack:new_decoder(4096),
                        authority = host_to_authority(Host)
                    }};
                {error, _} = E ->
                    _ = ssl:close(Sock),
                    E
            end;
        {error, _} = E ->
            E
    end;
open(_Host, _Port, h3) ->
    {error, not_implemented}.

-doc """
Issue one request on `Conn` and read the full response. Returns
the updated conn so subsequent calls reuse the same socket (and
HPACK contexts for h2).
""".
-spec request(
    conn(),
    Method :: binary(),
    Path :: binary(),
    Headers :: [{binary(), binary()}],
    Body :: binary()
) ->
    {ok, Status :: pos_integer(), [{binary(), binary()}], binary(), conn()}
    | {error, term()}.
request(#h1_conn{sock = Sock, buf = Buf} = Conn, Method, Path, Headers, Body) ->
    Req = build_h1_request(Method, Path, Headers, Body),
    case gen_tcp:send(Sock, Req) of
        ok ->
            case recv_h1_response(Sock, Buf) of
                {ok, Status, RespHeaders, RespBody, Buf1} ->
                    {ok, Status, RespHeaders, RespBody, Conn#h1_conn{buf = Buf1}};
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end;
request(
    #h2_conn{
        sock = Sock,
        buf = Buf,
        enc = Enc,
        dec = Dec,
        next_stream_id = Sid,
        authority = Auth
    } = Conn,
    Method,
    Path,
    Headers,
    Body
) ->
    Pseudo = [
        {~":method", Method},
        {~":scheme", ~"https"},
        {~":authority", Auth},
        {~":path", Path}
    ],
    {Block, Enc1} = roadrunner_http2_hpack:encode(Pseudo ++ Headers, Enc),
    BlockBin = iolist_to_binary(Block),
    HasBody = Body =/= <<>>,
    HFlags =
        case HasBody of
            true -> 16#04;
            false -> 16#04 bor 16#01
        end,
    HFrame = roadrunner_http2_frame:encode({headers, Sid, HFlags, undefined, BlockBin}),
    Frames =
        case HasBody of
            true -> [HFrame, roadrunner_http2_frame:encode({data, Sid, 16#01, Body})];
            false -> HFrame
        end,
    case ssl:send(Sock, Frames) of
        ok ->
            case recv_h2_response(Sock, Buf, Sid, Dec) of
                {ok, Status, RespHeaders, RespBody, Buf1, Dec1} ->
                    {ok, Status, RespHeaders, RespBody, Conn#h2_conn{
                        buf = Buf1,
                        enc = Enc1,
                        dec = Dec1,
                        next_stream_id = Sid + 2
                    }};
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

-doc "Close the underlying TCP / TLS socket.".
-spec close(conn()) -> ok.
close(#h1_conn{sock = Sock}) ->
    _ = gen_tcp:close(Sock),
    ok;
close(#h2_conn{sock = Sock}) ->
    _ = ssl:close(Sock),
    ok.

%% =============================================================================
%% h1 helpers
%% =============================================================================

build_h1_request(Method, Path, ExtraHeaders, Body) ->
    BodyLen = byte_size(Body),
    StatusLine = [Method, ~" ", Path, ~" HTTP/1.1\r\n"],
    HostHeader = [~"host: localhost\r\n"],
    UserHeaders = [[N, ~": ", V, ~"\r\n"] || {N, V} <- ExtraHeaders],
    LengthHeader =
        case BodyLen of
            0 -> [];
            _ -> [~"content-length: ", integer_to_binary(BodyLen), ~"\r\n"]
        end,
    [StatusLine, HostHeader, UserHeaders, LengthHeader, ~"\r\n", Body].

recv_h1_response(Sock, Buf) ->
    case binary:split(Buf, ~"\r\n\r\n") of
        [HeaderBlock, AfterHeaders] ->
            {Status, Headers} = parse_h1_status_and_headers(HeaderBlock),
            BodyLen = h1_content_length(Headers),
            recv_h1_body(Sock, AfterHeaders, BodyLen, Status, Headers);
        [_Partial] ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, More} ->
                    recv_h1_response(Sock, <<Buf/binary, More/binary>>);
                {error, _} = E ->
                    E
            end
    end.

recv_h1_body(_Sock, AfterHeaders, BodyLen, Status, Headers) when
    byte_size(AfterHeaders) >= BodyLen
->
    <<Body:BodyLen/binary, Rest/binary>> = AfterHeaders,
    {ok, Status, Headers, Body, Rest};
recv_h1_body(Sock, AfterHeaders, BodyLen, Status, Headers) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, More} ->
            recv_h1_body(
                Sock, <<AfterHeaders/binary, More/binary>>, BodyLen, Status, Headers
            );
        {error, _} = E ->
            E
    end.

parse_h1_status_and_headers(HeaderBlock) ->
    [StatusLine | HeaderLines] = binary:split(HeaderBlock, ~"\r\n", [global]),
    [_HttpVer, StatusBin | _Reason] = binary:split(StatusLine, ~" ", [global]),
    Status = binary_to_integer(StatusBin),
    Headers = [parse_h1_header_line(L) || L <- HeaderLines, L =/= <<>>],
    {Status, Headers}.

parse_h1_header_line(Line) ->
    [Name, Value] = binary:split(Line, ~":"),
    {
        roadrunner_bin:ascii_lowercase(string:trim(Name)),
        string:trim(Value)
    }.

h1_content_length(Headers) ->
    case lists:keyfind(~"content-length", 1, Headers) of
        {_, V} -> binary_to_integer(V);
        false -> 0
    end.

%% =============================================================================
%% h2 helpers
%% =============================================================================

h2_empty_settings_frame() ->
    <<0:24, 4, 0, 0:32>>.

h2_settings_ack_frame() ->
    <<0:24, 4, 1, 0:32>>.

%% Read until we've consumed the server's initial SETTINGS AND the
%% server's ACK to ours. We send our ACK as soon as we see server
%% SETTINGS (RFC 9113 §6.5.3 "Settings Synchronization").
h2_handshake(_Sock, Buf, true, true) ->
    {ok, Buf};
h2_handshake(Sock, Buf, GotS, GotA) ->
    case roadrunner_http2_frame:parse(Buf, ?MAX_FRAME_SIZE) of
        {ok, {settings, 1, _}, Rest} ->
            h2_handshake(Sock, Rest, GotS, true);
        {ok, {settings, 0, _Params}, Rest} ->
            ok = ssl:send(Sock, h2_settings_ack_frame()),
            h2_handshake(Sock, Rest, true, GotA);
        {ok, _Other, Rest} ->
            h2_handshake(Sock, Rest, GotS, GotA);
        {more, _Need} ->
            case ssl:recv(Sock, 0, 5000) of
                {ok, More} ->
                    h2_handshake(Sock, <<Buf/binary, More/binary>>, GotS, GotA);
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% Drain frames from the socket until we've collected a complete
%% response for `Sid` (HEADERS optionally followed by DATA, ending
%% in a frame with END_STREAM). Frames that aren't ours
%% (server-side SETTINGS / WINDOW_UPDATE / PING) are answered or
%% dropped inline so the connection stays usable.
recv_h2_response(Sock, Buf, Sid, Dec) ->
    recv_h2_loop(Sock, Buf, Sid, Dec, undefined, [], <<>>).

recv_h2_loop(Sock, Buf, Sid, Dec, Status, Headers, Body) ->
    case roadrunner_http2_frame:parse(Buf, ?MAX_FRAME_SIZE) of
        {ok, {headers, Sid, F, _Priority, Block}, Rest} ->
            {ok, Decoded, Dec1} = roadrunner_http2_hpack:decode(Block, Dec),
            {NewStatus, NewHeaders} = merge_h2_headers(Decoded, Status, Headers),
            case (F band 16#01) =/= 0 of
                true -> {ok, NewStatus, NewHeaders, Body, Rest, Dec1};
                false -> recv_h2_loop(Sock, Rest, Sid, Dec1, NewStatus, NewHeaders, Body)
            end;
        {ok, {data, Sid, F, Payload}, Rest} ->
            Body1 = <<Body/binary, Payload/binary>>,
            case (F band 16#01) =/= 0 of
                true -> {ok, Status, Headers, Body1, Rest, Dec};
                false -> recv_h2_loop(Sock, Rest, Sid, Dec, Status, Headers, Body1)
            end;
        {ok, {settings, 0, _}, Rest} ->
            ok = ssl:send(Sock, h2_settings_ack_frame()),
            recv_h2_loop(Sock, Rest, Sid, Dec, Status, Headers, Body);
        {ok, {ping, 0, Opaque}, Rest} ->
            ok = ssl:send(Sock, roadrunner_http2_frame:encode({ping, 1, Opaque})),
            recv_h2_loop(Sock, Rest, Sid, Dec, Status, Headers, Body);
        {ok, _Other, Rest} ->
            recv_h2_loop(Sock, Rest, Sid, Dec, Status, Headers, Body);
        {more, _Need} ->
            case ssl:recv(Sock, 0, 5000) of
                {ok, More} ->
                    recv_h2_loop(
                        Sock, <<Buf/binary, More/binary>>, Sid, Dec, Status, Headers, Body
                    );
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% Split decoded HEADERS into `:status` (response pseudo-header)
%% and regular headers; merge with the running accumulator (so
%% trailer HEADERS frames append to the regular header list).
merge_h2_headers(Decoded, Status0, Headers0) ->
    Status =
        case Status0 of
            undefined ->
                {_, S} = lists:keyfind(~":status", 1, Decoded),
                binary_to_integer(S);
            _ ->
                Status0
        end,
    Regular = [{N, V} || {N, V} <- Decoded, binary:first(N) =/= $:],
    {Status, Headers0 ++ Regular}.

%% `:authority` MUST be a binary; tolerate hostname-as-list AND
%% IP-tuple inputs from the bench's --host arg / `inet:ip_address()`.
host_to_authority(Host) when is_list(Host) -> list_to_binary(Host);
host_to_authority(Host) when is_binary(Host) -> Host;
host_to_authority(Host) when is_tuple(Host) -> list_to_binary(inet:ntoa(Host)).

%% `gen_tcp:connect` and `ssl:connect` accept hostname as a list
%% (string) or an `inet:ip_address()` tuple, NOT a binary. The
%% bench passes binaries for ergonomics — flatten here.
host_arg(Host) when is_binary(Host) -> binary_to_list(Host);
host_arg(Host) -> Host.
