-module(cactus_peer_handler).
-moduledoc """
Test fixture — answers with `peer=ok` when the request has a tuple
peer, `peer=missing` otherwise. Used to verify that `cactus_conn`
populates the peer field for accepted connections.
""".

-behaviour(cactus_handler).

-export([handle/1]).

-spec handle(cactus_http1:request()) ->
    {200, cactus_http1:headers(), iodata()}.
handle(Req) ->
    Body =
        case cactus_req:peer(Req) of
            {Ip, Port} when is_tuple(Ip), is_integer(Port) -> ~"peer=ok";
            _ -> ~"peer=missing"
        end,
    {200,
        [
            {~"content-type", ~"text/plain"},
            {~"content-length", integer_to_binary(byte_size(Body))},
            {~"connection", ~"close"}
        ],
        Body}.
