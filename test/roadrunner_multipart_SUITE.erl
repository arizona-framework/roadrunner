-module(roadrunner_multipart_SUITE).
-moduledoc """
Streaming multipart over HTTP/1.1 in manual body mode: the handler
(`roadrunner_multipart_stream_handler`) reads each part's headers as they
arrive and its body in bounded pieces, with the request body read only as
far as it needs.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    reads_parts_as_they_arrive/1,
    reads_a_chunked_body/1,
    read_error_is_returned/1,
    read_error_in_headers_is_returned/1,
    reads_shorter_than_the_boundary/1
]).

-define(H, roadrunner_multipart_stream_handler).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        reads_parts_as_they_arrive,
        reads_a_chunked_body,
        read_error_is_returned,
        read_error_in_headers_is_returned,
        reads_shorter_than_the_boundary
    ].

init_per_testcase(Case, Config) ->
    {ok, _} = roadrunner_listener:start_link(
        ?MODULE,
        maps:merge(
            #{
                port => 0,
                protocols => [http1],
                body_buffering => manual,
                routes => [
                    {~"/parts", ?H, {self(), 64, 3}},
                    {~"/small-reads", ?H, {self(), 4, 3}}
                ]
            },
            extra(Case)
        )
    ),
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, roadrunner_listener:port(?MODULE), [binary, {active, false}], 5000
    ),
    [{sock, Sock} | Config].

end_per_testcase(_Case, Config) ->
    ok = gen_tcp:close(?config(sock, Config)),
    ok = roadrunner_listener:stop(?MODULE).

extra(read_error_is_returned) -> #{request_timeout => 200};
extra(read_error_in_headers_is_returned) -> #{request_timeout => 200};
extra(_Case) -> #{}.

reads_parts_as_they_arrive(Config) ->
    %% The first part's headers reach the handler before the rest of the
    %% body is sent, and the second delimiter is split across sends. A read
    %% asks for up to 64 bytes, so the first send carries more than that.
    Sock = ?config(sock, Config),
    First = <<"--B\r\ncontent-disposition: form-data; name=\"a\"\r\n\r\nhello, more text">>,
    Rest = [
        <<" world\r\n-">>,
        <<"-B\r\ncontent-disposition: form-data; name=\"b\"\r\n\r\n">>,
        <<"second\r\n--B--\r\n">>
    ],
    Size = iolist_size([First | Rest]),
    ok = gen_tcp:send(Sock, [head(~"content-length: ", integer_to_binary(Size)), First]),
    ?assertEqual({part, [{~"content-disposition", ~"form-data; name=\"a\""}]}, next()),
    ok = lists:foreach(fun(Piece) -> ok = gen_tcp:send(Sock, Piece) end, Rest),
    ?assertEqual({part, [{~"content-disposition", ~"form-data; name=\"b\""}]}, next()),
    ?assertEqual(
        {parts,
            {ok, [
                {[{~"content-disposition", ~"form-data; name=\"a\""}], ~"hello, more text world"},
                {[{~"content-disposition", ~"form-data; name=\"b\""}], ~"second"}
            ]}},
        next()
    ),
    ?assertMatch({ok, <<"HTTP/1.1 200 ", _/binary>>}, gen_tcp:recv(Sock, 0, 5000)).

reads_a_chunked_body(Config) ->
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, [
        head(~"transfer-encoding: ", ~"chunked"),
        chunk(<<"--B\r\n\r\nab">>),
        chunk(<<"cdef\r\n--B--">>),
        ~"0\r\n\r\n"
    ]),
    ?assertEqual({part, []}, next()),
    ?assertEqual({parts, {ok, [{[], ~"abcdef"}]}}, next()),
    ?assertMatch({ok, <<"HTTP/1.1 200 ", _/binary>>}, gen_tcp:recv(Sock, 0, 5000)).

read_error_is_returned(Config) ->
    %% The body stops coming: the read fails, and the reader returns why.
    Sock = ?config(sock, Config),
    Sent = <<"--B\r\n\r\n", (binary:copy(~"x", 70))/binary>>,
    ok = gen_tcp:send(Sock, [head(~"content-length: ", ~"200"), Sent]),
    ?assertEqual({part, []}, next()),
    ?assertEqual({parts, {error, request_timeout}}, next()).

read_error_in_headers_is_returned(Config) ->
    %% The body stops before the first part's headers end: `read_part`
    %% returns why, with no part.
    Sock = ?config(sock, Config),
    ok = gen_tcp:send(Sock, [head(~"content-length: ", ~"200"), <<"--B\r\nx-a: 1">>]),
    ?assertEqual({parts, {error, request_timeout}}, next()).

reads_shorter_than_the_boundary(Config) ->
    %% Each read asks for 4 bytes, fewer than the opening `--BOUNDARY12`, so
    %% the reader reads on before it can tell the body opens with it.
    Sock = ?config(sock, Config),
    Body = <<"--BOUNDARY12\r\n\r\nvalue\r\n--BOUNDARY12--">>,
    ok = gen_tcp:send(Sock, [
        ~"POST /small-reads HTTP/1.1\r\nhost: x\r\n",
        ~"content-type: multipart/form-data; boundary=BOUNDARY12\r\n",
        ~"content-length: ",
        integer_to_binary(byte_size(Body)),
        ~"\r\n\r\n",
        Body
    ]),
    ?assertEqual({part, []}, next()),
    ?assertEqual({parts, {ok, [{[], ~"value"}]}}, next()).

head(Name, Value) ->
    [
        ~"POST /parts HTTP/1.1\r\nhost: x\r\n",
        ~"content-type: multipart/form-data; boundary=B\r\n",
        Name,
        Value,
        ~"\r\n\r\n"
    ].

chunk(Data) ->
    [integer_to_binary(byte_size(Data), 16), ~"\r\n", Data, ~"\r\n"].

next() ->
    receive
        {part, _} = Part -> Part;
        {parts, _} = Parts -> Parts
    after 5000 -> ct:fail(no_message)
    end.
