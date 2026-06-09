-module(bench_quic_h3_loadgen).
-moduledoc false.

%% Bench-only HTTP/3 loadgen over the `quic` dependency's `quic_h3` client.
%% Compiled only under the `bench` rebar3 profile. It exposes the same
%% `open/3` + `request/5` + `close/1` surface as `roadrunner_bench_client`, so
%% the bench worker loop can drive ANY h3 server (roadrunner's native server or
%% the dep's `erlang_quic` server) through the SAME strong client base, which
%% is what makes the server-vs-server comparison honest. The dep's client is a
%% mature loadgen (it sustained tens of thousands of req/s in the bench),
%% unlike the native test client which is built for correctness, not load.
%%
%% This is the pre-native-client `roadrunner_bench_client` h3 path (commit
%% 65e4760) lifted verbatim: the dep delivers responses as `{quic_h3, Conn, _}`
%% messages, collected per request into `{Status, Headers, Body}`.

-export([open/3, request/5, close/1]).

-record(h3_conn, {
    conn :: pid(),
    authority :: binary()
}).

%% Open one keep-alive QUIC connection. Under load the dep's handshake can
%% intermittently stall even though a fresh connection completes immediately,
%% so retry with a new connection a few times rather than lean on one deadline.
-spec open(inet:hostname() | inet:ip_address(), inet:port_number(), h3) ->
    {ok, #h3_conn{}} | {error, term()}.
open(Host, Port, h3) ->
    open_h3(host_to_authority(Host), Port, 5).

open_h3(_HostBin, _Port, 0) ->
    {error, timeout};
open_h3(HostBin, Port, Attempts) ->
    case quic_h3:connect(HostBin, Port, #{verify => verify_none}) of
        {ok, Conn} ->
            case quic_h3:wait_connected(Conn, 5000) of
                ok ->
                    {ok, #h3_conn{conn = Conn, authority = HostBin}};
                {error, _} ->
                    _ = quic_h3:close(Conn),
                    open_h3(HostBin, Port, Attempts - 1)
            end;
        {error, _} = Error ->
            Error
    end.

%% Issue one request on the keep-alive connection and collect the response.
-spec request(#h3_conn{}, binary(), binary(), [{binary(), binary()}], binary()) ->
    {ok, non_neg_integer(), [{binary(), binary()}], binary(), #h3_conn{}} | {error, term()}.
request(#h3_conn{conn = Conn, authority = Auth} = C, Method, Path, Headers, Body) ->
    AllHeaders = [
        {~":method", Method},
        {~":scheme", ~"https"},
        {~":authority", Auth},
        {~":path", Path}
        | Headers
    ],
    case h3_send_request(Conn, AllHeaders, Body) of
        {ok, StreamId} ->
            case h3_collect(Conn, StreamId, undefined, [], <<>>) of
                {ok, Status, RespHeaders, RespBody} ->
                    {ok, Status, RespHeaders, RespBody, C};
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

-spec close(#h3_conn{}) -> ok.
close(#h3_conn{conn = Conn}) ->
    _ = quic_h3:close(Conn),
    ok.

h3_send_request(Conn, AllHeaders, <<>>) ->
    quic_h3:request(Conn, AllHeaders);
h3_send_request(Conn, AllHeaders, Body) ->
    case quic_h3:request(Conn, AllHeaders, #{end_stream => false}) of
        {ok, StreamId} ->
            case quic_h3:send_data(Conn, StreamId, Body, true) of
                ok -> {ok, StreamId};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

h3_collect(Conn, StreamId, Status, Headers, Acc) ->
    receive
        {quic_h3, Conn, {response, StreamId, S, H}} ->
            h3_collect(Conn, StreamId, S, H, Acc);
        {quic_h3, Conn, {data, StreamId, Data, true}} ->
            {ok, Status, Headers, <<Acc/binary, Data/binary>>};
        {quic_h3, Conn, {data, StreamId, Data, false}} ->
            h3_collect(Conn, StreamId, Status, Headers, <<Acc/binary, Data/binary>>);
        {quic_h3, Conn, {trailers, StreamId, _Trailers}} ->
            {ok, Status, Headers, Acc};
        {quic_h3, Conn, {stream_reset, StreamId, ErrorCode}} ->
            {error, {stream_reset, ErrorCode}};
        {quic_h3, Conn, {error, ErrorCode, _Reason}} ->
            {error, {conn_error, ErrorCode}};
        {quic_h3, Conn, closed} ->
            {error, closed};
        {quic_h3, Conn, _Other} ->
            h3_collect(Conn, StreamId, Status, Headers, Acc)
    after 5000 ->
        {error, timeout}
    end.

host_to_authority(Host) when is_list(Host) -> list_to_binary(Host);
host_to_authority(Host) when is_binary(Host) -> Host;
host_to_authority(Host) when is_tuple(Host) -> list_to_binary(inet:ntoa(Host)).
