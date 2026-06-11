-module(roadrunner_proxy_peer_handler).
-moduledoc false.

%% Test fixture: echoes the request's peer IP literal (e.g. `192.168.0.1`) so a
%% PROXY-protocol test can assert the override produced the real client address,
%% not just that some peer is present.

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    Body =
        case roadrunner_req:peer(Req) of
            {Ip, _Port} -> list_to_binary(inet:ntoa(Ip));
            undefined -> ~"undefined"
        end,
    Resp =
        {200,
            [
                {~"content-type", ~"text/plain"},
                {~"content-length", integer_to_binary(byte_size(Body))},
                {~"connection", ~"close"}
            ],
            Body},
    {Resp, Req}.
