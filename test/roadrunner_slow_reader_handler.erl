-module(roadrunner_slow_reader_handler).
-moduledoc """
Test fixture: tells the test process (the route state) which process
serves the request, then answers with a large body, buffered at
`/buffered`, through `sendfile` at `/sendfile` (the state's file), and
streamed at `/stream` as the body in one chunk and a short last chunk.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    #{test := Test, file := File, size := Size} = roadrunner_req:state(Req),
    Test ! {?MODULE, self()},
    Headers = [{~"content-type", ~"application/octet-stream"}],
    case roadrunner_req:path(Req) of
        ~"/buffered" -> {{200, Headers, binary:copy(~"x", Size)}, Req};
        ~"/sendfile" -> {{sendfile, 200, Headers, {File, 0, Size}}, Req};
        ~"/stream" -> {{stream, 200, Headers, stream(Size)}, Req}
    end.

stream(Size) ->
    fun(Send) ->
        ok = Send(binary:copy(~"x", Size), nofin),
        ok = Send(~"end", fin)
    end.
