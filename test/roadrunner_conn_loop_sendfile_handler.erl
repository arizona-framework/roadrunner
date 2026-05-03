-module(roadrunner_conn_loop_sendfile_handler).
-moduledoc """
Test fixture — emits a `{sendfile, ...}` response covering
`roadrunner_conn_loop:dispatch_response/4`'s sendfile clause. The
file path is read from the request's `route_opts` (set by the
single-handler dispatch helper that stashes opts there) or from
`persistent_term` under `{?MODULE, file}`.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    Path = persistent_term:get({?MODULE, file}),
    {ok, Info} = file:read_file_info(Path),
    Size = element(2, Info),
    Resp = {sendfile, 200, [{~"content-length", integer_to_binary(Size)}], {Path, 0, Size}},
    {Resp, Req}.
