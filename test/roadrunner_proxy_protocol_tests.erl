-module(roadrunner_proxy_protocol_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_proxy_protocol).
-define(V2_SIG, 16#0D, 16#0A, 16#0D, 16#0A, 16#00, 16#0D, 16#0A, 16#51, 16#55, 16#49, 16#54, 16#0A).

%% --- v1 text ---

v1_tcp4_ok_test() ->
    Bin = <<"PROXY TCP4 192.168.0.1 10.0.0.5 56324 443\r\nGET / HTTP/1.1\r\n">>,
    ?assertEqual(
        {ok, {{192, 168, 0, 1}, 56324}, <<"GET / HTTP/1.1\r\n">>},
        ?M:parse(Bin)
    ).

v1_tcp6_ok_test() ->
    Bin = <<"PROXY TCP6 2001:db8::1 2001:db8::2 4711 443\r\nrest">>,
    ?assertEqual(
        {ok, {{16#2001, 16#db8, 0, 0, 0, 0, 0, 1}, 4711}, <<"rest">>},
        ?M:parse(Bin)
    ).

v1_unknown_is_local_test() ->
    Bin = <<"PROXY UNKNOWN\r\nrest">>,
    ?assertEqual({local, <<"rest">>}, ?M:parse(Bin)).

v1_unknown_with_addrs_is_local_test() ->
    %% A balancer MAY still send addresses with UNKNOWN; they are ignored.
    Bin = <<"PROXY UNKNOWN 1.1.1.1 2.2.2.2 1 2\r\nrest">>,
    ?assertEqual({local, <<"rest">>}, ?M:parse(Bin)).

v1_missing_crlf_is_more_test() ->
    ?assertEqual(more, ?M:parse(<<"PROXY TCP4 192.168.0.1 10.0.0.5 56324 44">>)).

v1_too_long_no_crlf_test() ->
    %% A line that exceeds the 107-byte budget without a CRLF is rejected.
    Long = list_to_binary(lists:duplicate(110, $x)),
    ?assertEqual({error, v1_too_long}, ?M:parse(<<"PROXY ", Long/binary>>)).

v1_too_long_with_crlf_test() ->
    Long = list_to_binary(lists:duplicate(110, $x)),
    ?assertEqual({error, v1_too_long}, ?M:parse(<<"PROXY ", Long/binary, "\r\n">>)).

v1_bad_address_test() ->
    ?assertEqual(
        {error, v1_bad_address},
        ?M:parse(<<"PROXY TCP4 999.1.1.1 10.0.0.5 1 2\r\n">>)
    ).

v1_tcp4_with_ipv6_address_test() ->
    %% Family/address mismatch: TCP4 carrying an IPv6 literal.
    ?assertEqual(
        {error, v1_bad_address},
        ?M:parse(<<"PROXY TCP4 2001:db8::1 10.0.0.5 1 2\r\n">>)
    ).

v1_bad_port_too_high_test() ->
    ?assertEqual(
        {error, v1_bad_port},
        ?M:parse(<<"PROXY TCP4 192.168.0.1 10.0.0.5 70000 443\r\n">>)
    ).

v1_bad_port_non_numeric_test() ->
    ?assertEqual(
        {error, v1_bad_port},
        ?M:parse(<<"PROXY TCP4 192.168.0.1 10.0.0.5 abc 443\r\n">>)
    ).

v1_malformed_field_count_test() ->
    ?assertEqual({error, v1_malformed}, ?M:parse(<<"PROXY TCP4 192.168.0.1\r\n">>)).

%% --- v2 binary ---

v2_inet_ok_test() ->
    Hdr = v2(2, 1, 1, 1, <<192, 168, 0, 1, 10, 0, 0, 5, 56324:16, 443:16>>),
    ?assertEqual(
        {ok, {{192, 168, 0, 1}, 56324}, <<"rest">>},
        ?M:parse(<<Hdr/binary, "rest">>)
    ).

v2_inet6_ok_test() ->
    Addr = <<16#2001:16, 16#db8:16, 0:16, 0:16, 0:16, 0:16, 0:16, 1:16>>,
    Body = <<Addr/binary, 0:128, 4711:16, 443:16>>,
    Hdr = v2(2, 1, 2, 1, Body),
    ?assertEqual(
        {ok, {{16#2001, 16#db8, 0, 0, 0, 0, 0, 1}, 4711}, <<"rest">>},
        ?M:parse(<<Hdr/binary, "rest">>)
    ).

v2_inet_with_tlv_skipped_test() ->
    %% Trailing TLV bytes are inside the declared length, so they are consumed
    %% (not part of the leftover) and the source address still parses.
    Body = <<192, 168, 0, 1, 10, 0, 0, 5, 56324:16, 443:16, 16#03, 0:16>>,
    Hdr = v2(2, 1, 1, 1, Body),
    ?assertEqual(
        {ok, {{192, 168, 0, 1}, 56324}, <<"rest">>},
        ?M:parse(<<Hdr/binary, "rest">>)
    ).

v2_local_is_local_test() ->
    Hdr = v2(2, 0, 1, 1, <<192, 168, 0, 1, 10, 0, 0, 5, 1:16, 2:16>>),
    ?assertEqual({local, <<"rest">>}, ?M:parse(<<Hdr/binary, "rest">>)).

v2_af_unix_is_local_test() ->
    Hdr = v2(2, 1, 3, 1, binary:copy(<<0>>, 216)),
    ?assertEqual({local, <<"rest">>}, ?M:parse(<<Hdr/binary, "rest">>)).

v2_af_unspec_is_local_test() ->
    Hdr = v2(2, 1, 0, 0, <<>>),
    ?assertEqual({local, <<"rest">>}, ?M:parse(<<Hdr/binary, "rest">>)).

v2_short_body_is_more_test() ->
    %% Signature + header byte present, but the declared body has not all
    %% arrived yet.
    Partial = <<?V2_SIG, (16#21), (16#11), 12:16, 192, 168>>,
    ?assertEqual(more, ?M:parse(Partial)).

v2_bad_version_test() ->
    Hdr = v2(3, 1, 1, 1, <<192, 168, 0, 1, 10, 0, 0, 5, 1:16, 2:16>>),
    ?assertEqual({error, v2_bad_version}, ?M:parse(Hdr)).

v2_bad_command_test() ->
    Hdr = v2(2, 2, 1, 1, <<192, 168, 0, 1, 10, 0, 0, 5, 1:16, 2:16>>),
    ?assertEqual({error, v2_bad_command}, ?M:parse(Hdr)).

v2_bad_address_short_for_inet_test() ->
    %% PROXY + INET but the body is too short to hold the address block.
    Hdr = v2(2, 1, 1, 1, <<1, 2, 3>>),
    ?assertEqual({error, v2_bad_address}, ?M:parse(Hdr)).

%% --- parse/1 dispatch / partial signatures ---

empty_is_more_test() ->
    ?assertEqual(more, ?M:parse(<<>>)).

partial_v1_signature_is_more_test() ->
    ?assertEqual(more, ?M:parse(<<"PROX">>)).

partial_v2_signature_is_more_test() ->
    ?assertEqual(more, ?M:parse(<<16#0D, 16#0A, 16#0D>>)).

not_a_proxy_header_test() ->
    ?assertEqual({error, not_proxy_header}, ?M:parse(<<"GET / HTTP/1.1\r\n">>)).

%% --- end-to-end: a real listener with proxy_protocol => true overrides the
%% request peer with the address the PROXY header reports ---

v1_override_test() ->
    Body = proxy_request(
        <<"PROXY TCP4 192.168.0.7 10.0.0.1 5000 443\r\n">>,
        <<"GET / HTTP/1.1\r\nHost: x\r\n\r\n">>
    ),
    ?assertEqual(~"192.168.0.7", Body).

v2_override_test() ->
    Hdr = v2(2, 1, 1, 1, <<203, 0, 113, 9, 10, 0, 0, 1, 5000:16, 443:16>>),
    Body = proxy_request(Hdr, <<"GET / HTTP/1.1\r\nHost: x\r\n\r\n">>),
    ?assertEqual(~"203.0.113.9", Body).

unknown_keeps_os_peer_test() ->
    Body = proxy_request(<<"PROXY UNKNOWN\r\n">>, <<"GET / HTTP/1.1\r\nHost: x\r\n\r\n">>),
    ?assertEqual(~"127.0.0.1", Body).

split_header_test() ->
    with_listener(fun(Port) ->
        {ok, S} = connect(Port),
        ok = gen_tcp:send(S, <<"PROXY TCP4 192.168.0.7 10.0.0.1 50">>),
        timer:sleep(20),
        ok = gen_tcp:send(S, <<"00 443\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n">>),
        ?assertEqual(~"192.168.0.7", body_of(recv_response(S, <<>>))),
        gen_tcp:close(S)
    end).

malformed_closes_test() ->
    with_listener(fun(Port) ->
        {ok, S} = connect(Port),
        %% A raw request (no PROXY header) on a proxy_protocol listener is a
        %% misconfigured upstream — the connection closes with no response.
        ok = gen_tcp:send(S, <<"GET / HTTP/1.1\r\nHost: x\r\n\r\n">>),
        ?assertEqual(<<>>, recv_response(S, <<>>)),
        gen_tcp:close(S)
    end).

recv_error_closes_test() ->
    with_listener(fun(Port) ->
        {ok, S} = connect(Port),
        %% Half-close (FIN) before sending any PROXY header: the server's first
        %% recv returns {error, closed}, so the connection closes with no reply.
        ok = gen_tcp:shutdown(S, write),
        ?assertEqual(<<>>, recv_response(S, <<>>)),
        gen_tcp:close(S)
    end).

%% --- helpers ---

proxy_request(Header, Request) ->
    with_listener(fun(Port) ->
        {ok, S} = connect(Port),
        ok = gen_tcp:send(S, <<Header/binary, Request/binary>>),
        Body = body_of(recv_response(S, <<>>)),
        gen_tcp:close(S),
        Body
    end).

%% Stand up a real listener directly (no app start/stop, mirroring
%% roadrunner_compress_tests) so concurrent test modules don't race on the
%% shared `pg` scope.
with_listener(Fun) ->
    Name = list_to_atom("proxy_it_" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0,
        proxy_protocol => true,
        protocols => [http1],
        routes => roadrunner_proxy_peer_handler
    }),
    Port = roadrunner_listener:port(Name),
    try
        Fun(Port)
    after
        ok = roadrunner_listener:stop(Name)
    end.

connect(Port) ->
    gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000).

recv_response(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 2000) of
        {ok, Data} -> recv_response(Sock, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.

body_of(Resp) ->
    case binary:split(Resp, <<"\r\n\r\n">>) of
        [_Headers, Body] -> Body;
        [_] -> <<>>
    end.

%% Build a v2 header: signature, version+command, family+transport, the 16-bit
%% body length, then the body.
v2(Ver, Cmd, Fam, Trans, Body) ->
    <<?V2_SIG, Ver:4, Cmd:4, Fam:4, Trans:4, (byte_size(Body)):16, Body/binary>>.
