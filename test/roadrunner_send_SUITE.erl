-module(roadrunner_send_SUITE).
-moduledoc """
`{send, Headers, Fun}` responses over HTTP/1.1, HTTP/2 (h2c) and HTTP/3:
the fun sends interim, complete, streamed and file responses itself with
`roadrunner_send`, and the framework finishes what it leaves open. The
handler is `roadrunner_send_handler`; each route's state picks what its
fun does.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1, init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    reply_sends_the_response/1,
    inform_sends_interims_first/1,
    reads_the_body_in_the_fun/1,
    stream_sends_the_body/1,
    open_stream_is_ended/1,
    stream_sends_trailers/1,
    sendfile_sends_the_range/1,
    head_reply_has_no_body/1,
    head_sendfile_has_no_body/1,
    no_response_is_500/1,
    crash_before_the_response_is_500/1,
    crash_after_the_response_keeps_it/1,
    crash_in_an_open_stream_cuts_it/1,
    second_final_response_raises/1,
    unsafe_inform_is_not_sent/1,
    unsafe_reply_is_500/1,
    missing_file_is_500/1,
    short_file_is_500/1,
    file_failing_after_the_head_is_cut/1,
    keeps_the_connection_alive/1,
    signals_close_at_the_keep_alive_ceiling/1,
    skips_interims_for_http10/1,
    upgrades_from_the_fun/1,
    refused_upgrade_answers/1,
    upgrade_is_not_supported/1,
    within_the_client_limit_is_sent/1,
    inform_over_the_client_limit_is_not_sent/1,
    stream_over_the_client_limit_is_500/1,
    client_reset_ends_the_fun/1
]).

-define(H, roadrunner_send_handler).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [{group, http1}, {group, http2}, {group, http3}].

groups() ->
    [
        {http1, [], common() ++ http1()},
        {http2, [], common() ++ multiplexed() ++ [client_reset_ends_the_fun]},
        {http3, [], common() ++ multiplexed()}
    ].

common() ->
    [
        reply_sends_the_response,
        inform_sends_interims_first,
        reads_the_body_in_the_fun,
        stream_sends_the_body,
        open_stream_is_ended,
        stream_sends_trailers,
        sendfile_sends_the_range,
        head_reply_has_no_body,
        head_sendfile_has_no_body,
        no_response_is_500,
        crash_before_the_response_is_500,
        crash_after_the_response_keeps_it,
        crash_in_an_open_stream_cuts_it,
        second_final_response_raises,
        unsafe_inform_is_not_sent,
        unsafe_reply_is_500,
        missing_file_is_500,
        short_file_is_500
    ].

http1() ->
    [
        keeps_the_connection_alive,
        signals_close_at_the_keep_alive_ceiling,
        skips_interims_for_http10,
        upgrades_from_the_fun,
        refused_upgrade_answers
    ].

multiplexed() ->
    [
        upgrade_is_not_supported,
        within_the_client_limit_is_sent,
        inform_over_the_client_limit_is_not_sent,
        stream_over_the_client_limit_is_500,
        file_failing_after_the_head_is_cut
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = roadrunner_test_event_handler:start(),
    File = filename:join(?config(priv_dir, Config), "send.txt"),
    ok = file:write_file(File, ~"abcdefgh"),
    [{file, File} | Config].

end_per_suite(_Config) ->
    ok.

init_per_group(Protocol, Config) ->
    [{protocol, Protocol} | Config].

end_per_group(_Protocol, _Config) ->
    ok.

init_per_testcase(Case, Config) ->
    {ok, _} = roadrunner_listener:start_link(
        ?MODULE,
        maps:merge(
            #{port => 0, routes => routes(self(), ?config(file, Config))},
            maps:merge(listener_opts(?config(protocol, Config)), extra(Case))
        )
    ),
    Events = [[roadrunner, request, stop], [roadrunner, request, exception]],
    Self = self(),
    ok = telemetry:attach_many(
        Case,
        Events,
        fun(Event, _Measurements, #{listener_name := ?MODULE} = Metadata, _) ->
            Self ! {telemetry_event, Event, Metadata}
        end,
        []
    ),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(Case, _Config) ->
    ok = telemetry:detach(Case),
    ok = roadrunner_listener:stop(?MODULE).

listener_opts(http1) ->
    #{};
listener_opts(http2) ->
    #{protocols => [http2]};
listener_opts(http3) ->
    #{protocols => [http3], tls => roadrunner_test_certs:server_opts()}.

extra(signals_close_at_the_keep_alive_ceiling) -> #{max_keep_alive_requests => 1};
extra(_Case) -> #{}.

routes(TestPid, File) ->
    [
        {~"/reply", ?H, reply},
        {~"/inform", ?H, inform},
        {~"/echo", ?H, echo},
        {~"/stream", ?H, stream},
        {~"/open", ?H, stream_left_open},
        {~"/trailers", ?H, stream_trailers},
        {~"/file", ?H, {sendfile, File}},
        {~"/nothing", ?H, nothing},
        {~"/crash-before", ?H, crash_before},
        {~"/crash-after", ?H, crash_after},
        {~"/crash-open", ?H, crash_open},
        {~"/twice", ?H, {report, TestPid, twice}},
        {~"/unsafe-inform", ?H, {report, TestPid, unsafe_inform}},
        {~"/unsafe-reply", ?H, {report, TestPid, unsafe_reply}},
        {~"/big-inform", ?H, {report, TestPid, big_inform}},
        {~"/big-stream", ?H, {report, TestPid, big_stream}},
        {~"/until-reset", ?H, {report, TestPid, until_reset}},
        {~"/upgrade", ?H, {report, TestPid, upgrade}},
        {~"/missing-file", ?H, {report, TestPid, {file, {missing_file(File), 0, 4}}}},
        {~"/short-file", ?H, {report, TestPid, {file, {File, 6, 4}}}},
        {~"/empty-device", ?H, {report, TestPid, {file, {"/dev/null", 0, 4}}}}
    ].

missing_file(File) ->
    filename:join(filename:dirname(File), "missing.txt").

%% =============================================================================
%% Every protocol
%% =============================================================================

reply_sends_the_response(Config) ->
    %% The tuple's headers are added; a header the call sets wins.
    {[200], Headers, ~"replied", complete} = get(Config, ~"/reply"),
    ?assertEqual(~"tuple", proplists:get_value(~"x-tuple", Headers)),
    ?assertEqual(~"call", proplists:get_value(~"x-both", Headers)),
    ?assertEqual({200, buffered}, stopped()).

inform_sends_interims_first(Config) ->
    ?assertMatch({[103, 103, 200], _, ~"after hints", complete}, get(Config, ~"/inform")).

reads_the_body_in_the_fun(Config) ->
    ?assertMatch({[200], _, ~"hello", complete}, request(Config, ~"POST", ~"/echo", ~"hello")).

stream_sends_the_body(Config) ->
    ?assertMatch({[200], _, ~"chunk1-chunk2", complete}, get(Config, ~"/stream")),
    ?assertEqual({200, stream}, stopped()).

open_stream_is_ended(Config) ->
    ?assertMatch({[200], _, ~"open", complete}, get(Config, ~"/open")).

stream_sends_trailers(Config) ->
    ?assertMatch({[200], _, ~"body", complete}, get(Config, ~"/trailers")).

sendfile_sends_the_range(Config) ->
    ?assertMatch({[200], _, ~"cdef", complete}, get(Config, ~"/file")),
    ?assertEqual({200, sendfile}, stopped()).

head_reply_has_no_body(Config) ->
    ?assertMatch({[200], _, <<>>, complete}, request(Config, ~"HEAD", ~"/reply", <<>>)).

head_sendfile_has_no_body(Config) ->
    ?assertMatch({[200], _, <<>>, complete}, request(Config, ~"HEAD", ~"/file", <<>>)).

no_response_is_500(Config) ->
    ?assertMatch({[500], _, _, complete}, get(Config, ~"/nothing")),
    ?assertEqual({500, buffered}, stopped()).

crash_before_the_response_is_500(Config) ->
    ?assertMatch({[500], _, _, complete}, get(Config, ~"/crash-before")),
    ?assertEqual(boom, crashed()).

crash_after_the_response_keeps_it(Config) ->
    ?assertMatch({[200], _, ~"sent", complete}, get(Config, ~"/crash-after")),
    ?assertEqual(boom, crashed()).

crash_in_an_open_stream_cuts_it(Config) ->
    %% HTTP/1.1 closes without the last chunk; HTTP/2 and HTTP/3 reset the
    %% stream.
    {[200], _, _Body, End} = get(Config, ~"/crash-open"),
    ?assertNotEqual(complete, End),
    ?assertEqual(boom, crashed()).

second_final_response_raises(Config) ->
    ?assertMatch({[200], _, ~"first", complete}, get(Config, ~"/twice")),
    ?assertEqual({raised, already_sent}, result()),
    ?assertEqual({raised, already_sent}, result()).

unsafe_inform_is_not_sent(Config) ->
    ?assertMatch({[200], _, ~"ok", complete}, get(Config, ~"/unsafe-inform")),
    ?assertEqual({error, unsafe_header}, result()).

unsafe_reply_is_500(Config) ->
    ?assertMatch({[500], _, _, complete}, get(Config, ~"/unsafe-reply")),
    ?assertEqual({error, unsafe_header}, result()).

missing_file_is_500(Config) ->
    %% Checked before anything is sent: no head goes out ahead of the 500.
    ?assertMatch({[500], _, _, complete}, get(Config, ~"/missing-file")),
    ?assertEqual({error, enoent}, result()),
    ?assertEqual({500, buffered}, stopped()).

short_file_is_500(Config) ->
    %% The range ends past the file's 8 bytes.
    ?assertMatch({[500], _, _, complete}, get(Config, ~"/short-file")),
    ?assertEqual({error, file_too_short}, result()),
    ?assertEqual({500, buffered}, stopped()).

%% =============================================================================
%% HTTP/1.1
%% =============================================================================

keeps_the_connection_alive(Config) ->
    %% A complete response leaves the connection open for the next request.
    Sock = h1_connect(Config),
    ok = gen_tcp:send(Sock, h1_request(~"GET", ~"/reply", [], <<>>)),
    {ok, First} = gen_tcp:recv(Sock, 0, 5000),
    ?assertMatch({[200], _, ~"replied", complete}, h1_parse(First, ~"GET")),
    ok = gen_tcp:send(Sock, h1_request(~"GET", ~"/reply", [{~"connection", ~"close"}], <<>>)),
    ?assertMatch({[200], _, ~"replied", complete}, h1_parse(h1_recv_all(Sock), ~"GET")).

signals_close_at_the_keep_alive_ceiling(Config) ->
    %% The server closes after the connection's last request, and says so.
    Sock = h1_connect(Config),
    ok = gen_tcp:send(Sock, h1_request(~"GET", ~"/reply", [], <<>>)),
    {[200], Headers, ~"replied", complete} = h1_parse(h1_recv_all(Sock), ~"GET"),
    ?assertEqual(~"close", proplists:get_value(~"connection", Headers)).

skips_interims_for_http10(Config) ->
    %% RFC 9110 §15.2: no 1xx to an HTTP/1.0 client.
    Sock = h1_connect(Config),
    ok = gen_tcp:send(Sock, ~"GET /inform HTTP/1.0\r\nhost: x\r\n\r\n"),
    ?assertMatch({[200], _, ~"after hints", complete}, h1_parse(h1_recv_all(Sock), ~"GET")).

upgrades_from_the_fun(Config) ->
    %% `websocket/4` from the fun: the 101, then the session echoes.
    Sock = h1_connect(Config),
    ok = gen_tcp:send(Sock, [
        ~"GET /upgrade HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
        ~"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    ]),
    {ok, <<"HTTP/1.1 101", _/binary>>} = gen_tcp:recv(Sock, 0, 5000),
    ?assertEqual(ok, result()),
    Key = <<1, 2, 3, 4>>,
    ok = gen_tcp:send(Sock, <<16#81, 16#82, Key/binary, (crypto:exor(~"hi", <<1, 2>>))/binary>>),
    ?assertEqual({ok, <<16#81, 2, "hi">>}, gen_tcp:recv(Sock, 4, 5000)).

refused_upgrade_answers(Config) ->
    %% Without the handshake headers the upgrade is refused with a 400.
    ?assertMatch({[400], _, _, complete}, get(Config, ~"/upgrade")),
    ?assertEqual({error, rejected}, result()).

%% =============================================================================
%% HTTP/2 and HTTP/3
%% =============================================================================

upgrade_is_not_supported(Config) ->
    ?assertMatch({[501], _, _, complete}, get(Config, ~"/upgrade")),
    ?assertEqual({error, not_supported}, result()).

within_the_client_limit_is_sent(Config) ->
    ?assertMatch({[103, 103, 200], _, ~"after hints", complete}, limited_get(Config, ~"/inform")),
    ?assertMatch({[200], _, ~"chunk1-chunk2", complete}, limited_get(Config, ~"/stream")).

inform_over_the_client_limit_is_not_sent(Config) ->
    ?assertMatch({[200], _, ~"ok", complete}, limited_get(Config, ~"/big-inform")),
    ?assertMatch({error, _}, result()).

stream_over_the_client_limit_is_500(Config) ->
    ?assertMatch({[500], _, _, complete}, limited_get(Config, ~"/big-stream")),
    ?assertMatch({error, _}, result()).

file_failing_after_the_head_is_cut(Config) ->
    %% `/dev/null` passes the check (a device has no size to hold the range
    %% to) and ends before the range does, so the read fails after the
    %% HEADERS: the stream is reset, no 500 follows the 200.
    {[200], _, <<>>, End} = get(Config, ~"/empty-device"),
    ?assertMatch({reset, _}, End),
    ?assertMatch({badmatch, eof}, crashed()).

client_reset_ends_the_fun(Config) ->
    %% The stream reset under a write ends the worker as for the `stream`
    %% shape: no crash is reported.
    C0 = h2_open(Config, []),
    C1 = h2_send_headers(C0, 1, ~"GET", ~"/until-reset", true),
    ?assertEqual(streaming, result()),
    ok = gen_tcp:send(
        maps:get(sock, C1), roadrunner_http2_frame:encode({rst_stream, 1, cancel})
    ),
    receive
        {telemetry_event, [roadrunner, request, exception], _} -> ct:fail(reset_reported)
    after 500 -> ok
    end.

%% =============================================================================
%% Helpers
%% =============================================================================

get(Config, Path) ->
    request(Config, ~"GET", Path, <<>>).

request(Config, Method, Path, Body) ->
    request(?config(protocol, Config), Config, Method, Path, Body, unlimited).

limited_get(Config, Path) ->
    request(?config(protocol, Config), Config, ~"GET", Path, <<>>, 500).

request(http1, Config, Method, Path, Body, _Limit) ->
    Sock = h1_connect(Config),
    ok = gen_tcp:send(Sock, h1_request(Method, Path, [{~"connection", ~"close"}], Body)),
    h1_parse(h1_recv_all(Sock), Method);
request(http2, Config, Method, Path, Body, Limit) ->
    C0 = h2_open(Config, h2_settings(Limit)),
    C1 = h2_send_headers(C0, 1, Method, Path, Body =:= <<>>),
    C2 =
        case Body of
            <<>> -> C1;
            _ -> h2_send_data(C1, 1, Body)
        end,
    h2_response(C2, 1);
request(http3, Config, Method, Path, Body, Limit) ->
    {ok, Conn} = roadrunner_quic_test_h3:connect(
        {127, 0, 0, 1}, ?config(port, Config), h3_opts(Limit)
    ),
    try
        Fields = [
            {~":method", Method},
            {~":scheme", ~"https"},
            {~":authority", ~"localhost"},
            {~":path", Path}
        ],
        {ok, StreamId} = roadrunner_quic_test_h3:open_request(Conn, Fields, Body =:= <<>>),
        ok =
            case Body of
                <<>> -> ok;
                _ -> roadrunner_quic_test_h3:send_data(Conn, StreamId, Body, true)
            end,
        h3_response(Conn, StreamId)
    after
        _ = roadrunner_quic_test_h3:close(Conn)
    end.

%% The status and kind of the next request stop event.
stopped() ->
    receive
        {telemetry_event, [roadrunner, request, stop], #{status := Status, response_kind := Kind}} ->
            {Status, Kind}
    after 5000 -> ct:fail(no_request_stop)
    end.

%% The reason of the next request exception event.
crashed() ->
    receive
        {telemetry_event, [roadrunner, request, exception], #{reason := Reason}} -> Reason
    after 5000 -> ct:fail(no_request_exception)
    end.

result() ->
    receive
        {send_result, Result} -> Result
    after 5000 -> ct:fail(no_send_result)
    end.

%% --- HTTP/1.1 ---

h1_connect(Config) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 5000
    ),
    Sock.

h1_request(Method, Path, Extra, Body) ->
    Headers = [
        {~"host", ~"x"},
        {~"content-length", integer_to_binary(byte_size(Body))}
        | Extra
    ],
    [
        Method,
        ~" ",
        Path,
        ~" HTTP/1.1\r\n",
        [[N, ~": ", V, ~"\r\n"] || {N, V} <- Headers],
        ~"\r\n",
        Body
    ].

h1_recv_all(Sock) ->
    h1_recv_all(Sock, <<>>).

h1_recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> h1_recv_all(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

%% The statuses (interims first), the final response's headers, its body and
%% `complete` or `truncated` (a chunked body without its last chunk).
h1_parse(Bytes, Method) ->
    [Head, Rest] = binary:split(Bytes, ~"\r\n\r\n"),
    [StatusLine | Lines] = binary:split(Head, ~"\r\n", [global]),
    [_Version, Code | _] = binary:split(StatusLine, ~" ", [global]),
    Headers = [list_to_tuple(binary:split(Line, ~": ")) || Line <- Lines],
    case binary_to_integer(Code) of
        Status when Status < 200 ->
            {Statuses, Final, Body, End} = h1_parse(Rest, Method),
            {[Status | Statuses], Final, Body, End};
        Status ->
            {Body, End} = h1_body(Method, Headers, Rest),
            {[Status], Headers, Body, End}
    end.

h1_body(~"HEAD", _Headers, Rest) ->
    {Rest, complete};
h1_body(_Method, Headers, Rest) ->
    case proplists:get_value(~"transfer-encoding", Headers) of
        ~"chunked" -> dechunk(Rest, <<>>);
        undefined -> {Rest, complete}
    end.

dechunk(Bytes, Acc) ->
    case binary:split(Bytes, ~"\r\n") of
        [~"0", _Trailers] ->
            {Acc, complete};
        [SizeHex, Rest] ->
            Size = binary_to_integer(SizeHex, 16),
            case Rest of
                <<Chunk:Size/binary, "\r\n", Rest1/binary>> ->
                    dechunk(Rest1, <<Acc/binary, Chunk/binary>>);
                _ ->
                    {Acc, truncated}
            end;
        [_] ->
            {Acc, truncated}
    end.

%% --- HTTP/2 ---

h2_settings(unlimited) -> [];
h2_settings(Limit) -> [{6, Limit}].

h2_open(Config, Settings) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 5000
    ),
    ok = gen_tcp:send(Sock, [
        ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", roadrunner_http2_frame:encode({settings, 0, Settings})
    ]),
    #{
        sock => Sock,
        buf => <<>>,
        enc => roadrunner_http2_hpack:new_encoder(4096),
        dec => roadrunner_http2_hpack:new_decoder(4096)
    }.

h2_send_headers(#{sock := Sock, enc := Enc} = C, StreamId, Method, Path, EndStream) ->
    Fields = [
        {~":method", Method},
        {~":scheme", ~"http"},
        {~":authority", ~"x"},
        {~":path", Path}
    ],
    {Block, Enc1} = roadrunner_http2_hpack:encode(Fields, Enc),
    Flags =
        case EndStream of
            true -> 16#04 bor 16#01;
            false -> 16#04
        end,
    ok = gen_tcp:send(
        Sock, roadrunner_http2_frame:encode({headers, StreamId, Flags, undefined, Block})
    ),
    C#{enc := Enc1}.

h2_send_data(#{sock := Sock} = C, StreamId, Body) ->
    ok = gen_tcp:send(Sock, roadrunner_http2_frame:encode({data, StreamId, 16#01, Body})),
    C.

h2_response(C, StreamId) ->
    h2_response(C, StreamId, [], [], <<>>).

h2_response(C, StreamId, Statuses, Final, Body) ->
    case h2_next_frame(C) of
        {{headers, StreamId, Flags, Fields}, C1} ->
            case lists:keyfind(~":status", 1, Fields) of
                {_, Code} ->
                    Status = binary_to_integer(Code),
                    Final1 =
                        case Status < 200 of
                            true -> Final;
                            false -> Fields
                        end,
                    h2_ended(C1, StreamId, Flags, [Status | Statuses], Final1, Body);
                false ->
                    h2_ended(C1, StreamId, Flags, Statuses, Final, Body)
            end;
        {{data, StreamId, Flags, Data, _}, C1} ->
            h2_ended(C1, StreamId, Flags, Statuses, Final, <<Body/binary, Data/binary>>);
        {{rst_stream, StreamId, Code}, _C1} ->
            {lists:reverse(Statuses), Final, Body, {reset, Code}};
        {_Other, C1} ->
            h2_response(C1, StreamId, Statuses, Final, Body)
    end.

h2_ended(_C, _StreamId, Flags, Statuses, Final, Body) when Flags band 16#01 =/= 0 ->
    {lists:reverse(Statuses), Final, Body, complete};
h2_ended(C, StreamId, _Flags, Statuses, Final, Body) ->
    h2_response(C, StreamId, Statuses, Final, Body).

h2_next_frame(#{sock := Sock, buf := Buf, dec := Dec} = C) ->
    case roadrunner_http2_frame:parse(Buf, 16384) of
        {ok, {headers, StreamId, Flags, _Priority, Block}, Rest} ->
            {ok, Fields, Dec1} = roadrunner_http2_hpack:decode(Block, Dec),
            {{headers, StreamId, Flags, Fields}, C#{buf := Rest, dec := Dec1}};
        {ok, Frame, Rest} ->
            {Frame, C#{buf := Rest}};
        _More ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            h2_next_frame(C#{buf := <<Buf/binary, Data/binary>>})
    end.

%% --- HTTP/3 ---

h3_opts(unlimited) -> #{};
h3_opts(Limit) -> #{h3_settings => #{max_field_section_size => Limit}}.

h3_response(Conn, StreamId) ->
    h3_response(Conn, StreamId, <<>>).

h3_response(Conn, StreamId, Acc) ->
    receive
        {quic_test_stream, Conn, StreamId, Bytes, false} ->
            h3_response(Conn, StreamId, <<Acc/binary, Bytes/binary>>);
        {quic_test_stream, Conn, StreamId, Bytes, true} ->
            h3_frames(<<Acc/binary, Bytes/binary>>, [], [], <<>>, complete);
        {quic_test_stream_reset, Conn, StreamId, Code} ->
            h3_frames(Acc, [], [], <<>>, {reset, Code})
    after 5000 -> ct:fail(stream_not_ended)
    end.

h3_frames(<<>>, Statuses, Final, Body, End) ->
    {lists:reverse(Statuses), Final, Body, End};
h3_frames(Bytes, Statuses, Final, Body, End) ->
    case roadrunner_quic_h3_frame:decode(Bytes) of
        {ok, {headers, Block}, Rest} ->
            {ok, Fields} = roadrunner_qpack:decode(Block),
            case lists:keyfind(~":status", 1, Fields) of
                {_, Code} when Code < ~"200" ->
                    h3_frames(Rest, [binary_to_integer(Code) | Statuses], Final, Body, End);
                {_, Code} ->
                    h3_frames(Rest, [binary_to_integer(Code) | Statuses], Fields, Body, End);
                false ->
                    h3_frames(Rest, Statuses, Final, Body, End)
            end;
        {ok, {data, Data}, Rest} ->
            h3_frames(Rest, Statuses, Final, <<Body/binary, Data/binary>>, End);
        _Partial ->
            {lists:reverse(Statuses), Final, Body, End}
    end.
