-module(roadrunner_client_ip_handler).
-moduledoc false.

%% Test fixture: echoes the request's resolved client IP literal (e.g.
%% `203.0.113.7`) so a real-IP test can assert the trusted-proxy resolution
%% produced the forwarded client address, not the socket peer.

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    Body =
        case roadrunner_req:client_ip(Req) of
            undefined -> ~"undefined";
            Ip -> list_to_binary(inet:ntoa(Ip))
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
