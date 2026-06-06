-module(roadrunner_quic_socket_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_quic_socket).

%% Option validation runs before any socket is opened, so these reject
%% paths need no loopback fixture: a bad option raises before gen_udp is
%% touched. The I/O paths (open/send/recv/close/sockname, valid opts)
%% live in roadrunner_quic_socket_SUITE.

open_rejects_unknown_opt_test() ->
    ?assertError({invalid_quic_socket_opt, bogus, 1}, ?M:open(0, #{bogus => 1})).

open_rejects_zero_recbuf_test() ->
    ?assertError({invalid_quic_socket_opt, recbuf, 0}, ?M:open(0, #{recbuf => 0})).

open_rejects_negative_sndbuf_test() ->
    ?assertError({invalid_quic_socket_opt, sndbuf, -1}, ?M:open(0, #{sndbuf => -1})).

open_rejects_non_boolean_reuseport_test() ->
    ?assertError({invalid_quic_socket_opt, reuseport, yes}, ?M:open(0, #{reuseport => yes})).
