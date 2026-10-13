-module(roadrunner_linger_SUITE).
-moduledoc """
HTTP/1.1 closes after a response sent before the request was read to its
end: the connection lingers over what the client still sends, so a client
uploading a body it was refused reads the response instead of losing it to
the reset a close with unread input sends.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    over_cap_upload_gets_its_413/1,
    over_cap_upload_gets_its_413_over_tls/1,
    handler_answer_lingers_over_the_upload/1,
    not_found_lingers_over_the_upload/1,
    streamed_answer_lingers_over_the_upload/1,
    oversized_header_gets_its_431/1,
    rate_limited_request_answered_before_its_body/1,
    linger_ends_when_the_client_closes/1,
    linger_ends_at_its_timeout/1
]).

-define(H, roadrunner_manual_body_handler).
%% Far over every cap here, and large enough that most of it is still in
%% flight when the response goes out.
-define(UPLOAD, 4000000).
%% Each case repeats its upload: a close that resets loses the response in
%% most runs, not all.
-define(RUNS, 5).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        over_cap_upload_gets_its_413,
        over_cap_upload_gets_its_413_over_tls,
        handler_answer_lingers_over_the_upload,
        not_found_lingers_over_the_upload,
        streamed_answer_lingers_over_the_upload,
        oversized_header_gets_its_431,
        rate_limited_request_answered_before_its_body,
        linger_ends_when_the_client_closes,
        linger_ends_at_its_timeout
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(telemetry),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    Opts = maps:merge(
        #{
            port => 0,
            max_content_length => 1000,
            routes => [{~"/r", ?H, reject}, {~"/stream", roadrunner_stream_handler}]
        },
        opts(Case)
    ),
    {ok, _} = roadrunner_listener:start_link(?MODULE, Opts),
    [{port, roadrunner_listener:port(?MODULE)} | Config].

end_per_testcase(_Case, _Config) ->
    ok = roadrunner_listener:stop(?MODULE).

opts(over_cap_upload_gets_its_413_over_tls) ->
    #{tls => roadrunner_test_certs:server_opts()};
opts(Case) when
    Case =:= handler_answer_lingers_over_the_upload;
    Case =:= not_found_lingers_over_the_upload;
    Case =:= streamed_answer_lingers_over_the_upload
->
    #{body_buffering => manual, protocols => [{http1, #{linger_timeout => 60000}}]};
opts(rate_limited_request_answered_before_its_body) ->
    #{rate_limit => #{rate => 1, burst => 1, period => 60}};
opts(linger_ends_when_the_client_closes) ->
    #{protocols => [{http1, #{linger_timeout => 60000}}]};
opts(linger_ends_at_its_timeout) ->
    #{protocols => [{http1, #{linger_timeout => 200}}]};
opts(_Case) ->
    #{}.

over_cap_upload_gets_its_413(Config) ->
    [?assertEqual(~"413", upload(gen_tcp, Config)) || _ <- lists:seq(1, ?RUNS)].

over_cap_upload_gets_its_413_over_tls(Config) ->
    [?assertEqual(~"413", upload(ssl, Config)) || _ <- lists:seq(1, ?RUNS)].

handler_answer_lingers_over_the_upload(Config) ->
    %% The handler answers 401 without reading a body over its cap.
    lingers_after(Config, ~"/r", ~"401").

not_found_lingers_over_the_upload(Config) ->
    %% No route: the 404 goes out ahead of the body the request frames.
    lingers_after(Config, ~"/missing", ~"404").

streamed_answer_lingers_over_the_upload(Config) ->
    %% A streamed answer, its body never read.
    lingers_after(Config, ~"/stream", ~"200").

oversized_header_gets_its_431(Config) ->
    %% A header line past `max_header_line` is refused while the client is
    %% still sending it.
    Request = [~"GET /r HTTP/1.1\r\nHost: x\r\nX-Big: ", binary:copy(~"a", ?UPLOAD), ~"\r\n\r\n"],
    [?assertEqual(~"431", exchange(gen_tcp, Config, Request)) || _ <- lists:seq(1, ?RUNS)].

rate_limited_request_answered_before_its_body(Config) ->
    %% Over its rate, a request is answered 429 from its headers alone: the
    %% client holding back its body is not waited on.
    ?assertEqual(
        ~"401",
        exchange(gen_tcp, Config, ~"GET /r HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    ),
    {ok, Sock} = connect(gen_tcp, Config),
    ok = gen_tcp:send(Sock, head(500)),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 2000),
    ?assertMatch(<<"HTTP/1.1 429 ", _/binary>>, Reply),
    ok = gen_tcp:close(Sock).

linger_ends_when_the_client_closes(Config) ->
    %% A 60 s linger: the connection still ends at once when the client,
    %% having read the 413, closes.
    Ref = attach_conn_close(),
    {ok, Sock} = connect(gen_tcp, Config),
    ok = gen_tcp:send(Sock, head(?UPLOAD)),
    ?assertMatch(<<"HTTP/1.1 413 ", _/binary>>, recv_until_closed(gen_tcp, Sock, <<>>)),
    ok = gen_tcp:close(Sock),
    ok = conn_closed(Ref).

linger_ends_at_its_timeout(Config) ->
    %% A client that keeps sending never lets a read time out: the linger
    %% still ends at its 200 ms, the connection closes, and the client's
    %% sending fails.
    Ref = attach_conn_close(),
    {ok, Sock} = connect(gen_tcp, Config),
    ok = gen_tcp:send(Sock, head(1000000000)),
    ok = send_until_refused(Sock, binary:copy(~"x", 65536)),
    ok = conn_closed(Ref),
    ok = gen_tcp:close(Sock).

%% --- helpers ---

%% A POST of `?UPLOAD` bytes to the refusing route, sent in full before the
%% response is read, as a client that only reads once its upload is out
%% does. Returns the response's status.
upload(Transport, Config) ->
    exchange(Transport, Config, [head(?UPLOAD), binary:copy(~"x", ?UPLOAD)]).

exchange(Transport, Config, Request) ->
    {ok, Sock} = connect(Transport, Config),
    _ = Transport:send(Sock, Request),
    Reply = recv_until_closed(Transport, Sock, <<>>),
    _ = Transport:close(Sock),
    case Reply of
        <<"HTTP/1.1 ", Status:3/binary, _/binary>> -> Status;
        Other -> {no_response, Other}
    end.

head(Length) ->
    head(~"/r", Length).

head(Path, Length) ->
    [
        ~"POST ",
        Path,
        ~" HTTP/1.1\r\nHost: x\r\nContent-Length: ",
        integer_to_binary(Length),
        ~"\r\n\r\n"
    ].

%% A request answered with `Status` before its body was read: the connection
%% then reads on, so 16 MB more, past any socket buffer, all go out where a
%% closed connection would reset them, and the client's close ends it.
lingers_after(Config, Path, Status) ->
    Ref = attach_conn_close(),
    %% `exit_on_close` off: the server's FIN after its response ends only
    %% the client's reading, so it can go on sending.
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1},
        ?config(port, Config),
        [binary, {active, false}, {exit_on_close, false}],
        5000
    ),
    ok = gen_tcp:send(Sock, head(Path, 1000000000)),
    <<"HTTP/1.1 ", Got:3/binary, _/binary>> = recv_until_closed(gen_tcp, Sock, <<>>),
    ?assertEqual(Status, Got),
    Chunk = binary:copy(~"x", 65536),
    [ok = gen_tcp:send(Sock, Chunk) || _ <- lists:seq(1, 256)],
    ok = gen_tcp:close(Sock),
    ok = conn_closed(Ref).

connect(gen_tcp, Config) ->
    gen_tcp:connect({127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 5000);
connect(ssl, Config) ->
    ClientOpts = [{verify, verify_none} | roadrunner_test_certs:client_opts()],
    ssl:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false} | ClientOpts], 5000
    ).

recv_until_closed(Transport, Sock, Acc) ->
    case Transport:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_until_closed(Transport, Sock, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.

send_until_refused(Sock, Chunk) ->
    case gen_tcp:send(Sock, Chunk) of
        ok -> send_until_refused(Sock, Chunk);
        {error, _} -> ok
    end.

attach_conn_close() ->
    Self = self(),
    Ref = make_ref(),
    ok = telemetry:attach(
        Ref,
        [roadrunner, listener, conn_close],
        fun(_Event, _Measurements, #{listener_name := ?MODULE}, _Config) ->
            Self ! {conn_closed, Ref}
        end,
        undefined
    ),
    Ref.

conn_closed(Ref) ->
    receive
        {conn_closed, Ref} -> telemetry:detach(Ref)
    after 5000 -> ct:fail(conn_not_closed)
    end.
