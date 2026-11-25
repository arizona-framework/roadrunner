-module(roadrunner_addr_handler).
-moduledoc """
Test fixture: answers with `{peer/1, client_ip/1, sockname/1}` of the
request, as an Erlang term (`term_to_binary/1`).
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    Addr = {
        roadrunner_req:peer(Req), roadrunner_req:client_ip(Req), roadrunner_req:sockname(Req)
    },
    {{200, [], term_to_binary(Addr)}, Req}.
