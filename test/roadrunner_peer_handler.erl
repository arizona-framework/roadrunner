-module(roadrunner_peer_handler).
-moduledoc """
Test fixture — answers with `peer=ok` when the request has a tuple
peer, `peer=missing` otherwise. Used to verify that `roadrunner_conn`
populates the peer field for accepted connections.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    Body =
        case roadrunner_req:peer(Req) of
            {Ip, Port} when is_tuple(Ip), is_integer(Port) -> ~"peer=ok";
            _ -> ~"peer=missing"
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
