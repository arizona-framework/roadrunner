-module(cactus_handler).
-moduledoc """
Behaviour for handling parsed HTTP requests.

Implementations receive the parsed request map and return a
`{StatusCode, Headers, Body}` triple. The connection process encodes
the response and closes the socket.

Body framing (`Content-Length` / `Transfer-Encoding`) and the
`Connection: close` directive are the handler's responsibility for
now — a higher-level builder will assume that role in slice 5.
""".

-callback handle(Request :: cactus_http1:request()) ->
    {StatusCode :: 100..599, Headers :: cactus_http1:headers(), Body :: iodata()}.
