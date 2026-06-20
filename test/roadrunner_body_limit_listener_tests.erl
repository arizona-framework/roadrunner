-module(roadrunner_body_limit_listener_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Opt validation.
%% =============================================================================

valid_max_body_starts_test() ->
    Routes = [#{path => ~"/upload", handler => roadrunner_hello_handler, max_body => 1024}],
    with_route_listener([http1], Routes, fun(_Port, Name) ->
        ?assert(is_integer(roadrunner_listener:port(Name)))
    end).

rejects_bad_max_body_test() ->
    process_flag(trap_exit, true),
    Routes = [#{path => ~"/x", handler => roadrunner_hello_handler, max_body => -1}],
    R = roadrunner_listener:start_link(unique(bl_bad), #{
        port => 0, protocols => [http1], routes => Routes
    }),
    ?assertMatch({error, {{invalid_route_max_body, ~"/x", -1}, _}}, R).

%% =============================================================================
%% HTTP/1: the route cap is enforced before the body is read (413 / 200).
%% =============================================================================

h1_over_route_cap_413_test() ->
    Routes = [#{path => ~"/upload", handler => roadrunner_hello_handler, max_body => 10}],
    with_route_listener([http1], Routes, fun(Port, _Name) ->
        %% 20-byte body to a 10-byte-capped route → 413 (rejected before read).
        ?assertMatch(
            <<"HTTP/1.1 413", _/binary>>, h1_post(Port, ~"/upload", binary:copy(~"x", 20))
        ),
        %% 5-byte body is under the cap → reaches the handler.
        ?assertMatch(
            <<"HTTP/1.1 200", _/binary>>, h1_post(Port, ~"/upload", binary:copy(~"x", 5))
        )
    end).

h1_uncapped_route_uses_global_test() ->
    %% A route with no `max_body` rides the (large) global `max_content_length`,
    %% so a 20-byte body is fine even when a sibling route caps at 10.
    Routes = [
        #{path => ~"/upload", handler => roadrunner_hello_handler, max_body => 10},
        #{path => ~"/open", handler => roadrunner_hello_handler}
    ],
    with_route_listener([http1], Routes, fun(Port, _Name) ->
        ?assertMatch(
            <<"HTTP/1.1 200", _/binary>>, h1_post(Port, ~"/open", binary:copy(~"x", 20))
        )
    end).

%% =============================================================================
%% HTTP/2 (h2c): the route cap is enforced at dispatch (post-accumulation 413).
%% =============================================================================

h2c_over_route_cap_413_test() ->
    Routes = [#{path => ~"/upload", handler => roadrunner_hello_handler, max_body => 10}],
    with_route_listener([http2], Routes, fun(Port, _Name) ->
        {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
        Preface = ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",
        EmptySettings = <<0:24, 4, 0, 0:32>>,
        ok = gen_tcp:send(Sock, [Preface, EmptySettings | h2_post_frames(~"/upload", 20)]),
        Reply = recv_for(Sock, <<>>, 800),
        ok = gen_tcp:close(Sock),
        %% The 413 response body is "Payload Too Large" (a DATA frame payload).
        ?assertMatch({match, _}, re:run(Reply, ~"Payload Too Large"))
    end).

%% --- helpers ---

with_route_listener(Protocols, Routes, Fun) ->
    Name = unique(bl_it),
    {ok, _} = roadrunner_listener:start_link(Name, #{
        port => 0, protocols => Protocols, routes => Routes
    }),
    Port = roadrunner_listener:port(Name),
    try
        Fun(Port, Name)
    after
        ok = roadrunner_listener:stop(Name)
    end.

unique(Prefix) ->
    list_to_atom(atom_to_list(Prefix) ++ "_" ++ integer_to_list(erlang:unique_integer([positive]))).

h1_post(Port, Path, Body) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    CL = integer_to_binary(byte_size(Body)),
    Req = [
        ~"POST ",
        Path,
        ~" HTTP/1.1\r\nHost: x\r\nContent-Length: ",
        CL,
        ~"\r\nConnection: close\r\n\r\n",
        Body
    ],
    ok = gen_tcp:send(Sock, Req),
    Reply = recv_for(Sock, <<>>, 1000),
    ok = gen_tcp:close(Sock),
    Reply.

recv_for(Sock, Acc, Timeout) ->
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, Data} -> recv_for(Sock, <<Acc/binary, Data/binary>>, Timeout);
        {error, _} -> Acc
    end.

%% A POST request on stream 1: HEADERS (END_HEADERS, no END_STREAM) then a DATA
%% frame of `BodyLen` bytes (END_STREAM).
h2_post_frames(Path, BodyLen) ->
    {Block, _Enc} = roadrunner_http2_hpack:encode(
        [
            {~":method", ~"POST"},
            {~":scheme", ~"http"},
            {~":authority", ~"x"},
            {~":path", Path}
        ],
        roadrunner_http2_hpack:new_encoder(4096)
    ),
    Headers = roadrunner_http2_frame:encode(
        {headers, 1, 16#04, undefined, iolist_to_binary(Block)}
    ),
    Payload = binary:copy(~"x", BodyLen),
    Data = <<BodyLen:24, 0:8, 16#01:8, 0:1, 1:31, Payload/binary>>,
    [Headers, Data].
