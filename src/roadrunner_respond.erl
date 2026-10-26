-module(roadrunner_respond).
-moduledoc """
Send a response from inside the handler, as it runs.

A handler normally returns its response and the connection sends it. A
handler that returns `{respond, Headers, Fun}` sends it itself instead:
the connection calls `Fun(Req)` and the fun calls this module's functions
to put the response on the wire, then returns the request.

```erlang
handle(Req) ->
    {{respond, [], fun respond/1}, Req}.

respond(Req0) ->
    ok = roadrunner_respond:inform(103, [{~"link", ~"</app.css>; rel=preload"}], Req0),
    {ok, Body, Req} = roadrunner_req:read_body(Req0),
    ok = roadrunner_respond:reply(200, [{~"content-type", ~"text/plain"}], Body, Req),
    Req.
```

Use it when the response can only be decided while the handler runs:

- `inform/3` sends an interim 1xx response (such as `103 Early Hints`)
  before the final one, as many times as needed
- `reply/4` sends a complete response
- `stream/3` sends the status and headers and returns the same `Send`
  fun a `{stream, ...}` response gets, to write the body as it goes
- `sendfile/4` sends a file, as a `{sendfile, ...}` response does

The fun sends one final response (`reply/4`, `stream/3` or `sendfile/4`);
a second one raises `already_sent`. The calls take the request the fun
holds now, so pass the one returned by `roadrunner_req:read_body/1,2`,
and return the last one from the fun, as `handle/1` does.

The framework finishes what the fun leaves open. A stream the fun did
not end with `Send(Data, fin)` is ended when the fun returns. A fun that
returns without a final response gets a `500` sent for it. A fun that
crashes before a final response is answered `500`; one that crashes
after it closes the connection (HTTP/1.1) or resets the stream (HTTP/2,
HTTP/3) when the body was still open.

`Headers` in the `{respond, Headers, Fun}` tuple is where middlewares add
their headers (`roadrunner_cors`, `roadrunner_security_headers`). They
are added to the final response, unless the call already sets a header
with the same name. `vary` is the exception: both values are kept. Interim responses get only the headers they are
given. `roadrunner_compress` does not compress a response sent this way.

The rules of the other response shapes apply. Header names must be
lowercase. A response with a CR, LF or NUL in a header, or (on HTTP/2
and HTTP/3) headers over the client's header size limit, is not sent:
the final ones are answered `500` and the call returns an error. A HEAD
request gets no body from `reply/4` or `sendfile/4`. An interim response
to an HTTP/1.0 client is skipped, as RFC 9110 §15.2 asks.
""".

-export([inform/3, reply/4, stream/3, sendfile/4]).

-export_type([respond_fun/0]).

-doc """
The fun of a `{respond, Headers, Fun}` response. It gets the request,
sends the response with this module's functions, and returns the request.
""".
-type respond_fun() :: fun((roadrunner_req:request()) -> roadrunner_req:request()).

-doc """
Send an interim response: a 1xx status, `102` to `199`, ahead of the
final response. Returns `ok` once it is written, or `{error, Reason}`
when it could not be sent.
""".
-spec inform(roadrunner_http:status(), roadrunner_http:headers(), roadrunner_req:request()) ->
    ok | {error, term()}.
inform(Status, Headers, Req) when
    is_integer(Status), Status >= 102, Status =< 199, is_list(Headers)
->
    roadrunner_respond_writer:inform(Status, Headers, Req).

-doc """
Send a complete response. Returns `ok` once it is handed to the
connection, or `{error, Reason}` when it could not be sent.
""".
-spec reply(
    roadrunner_http:status(), roadrunner_http:headers(), iodata(), roadrunner_req:request()
) -> ok | {error, term()}.
reply(Status, Headers, Body, Req) when
    is_integer(Status), Status >= 200, Status =< 599, is_list(Headers)
->
    roadrunner_respond_writer:final(buffered, {reply, Status, Headers, Body}, Req).

-doc """
Send the status and headers of a streamed response. Returns `{ok, Send}`
with the `t:roadrunner_handler:send_fun/0` that writes the body, the same
fun a `{stream, ...}` response gets, or `{error, Reason}` when the head
could not be sent.
""".
-spec stream(roadrunner_http:status(), roadrunner_http:headers(), roadrunner_req:request()) ->
    {ok, roadrunner_handler:send_fun()} | {error, term()}.
stream(Status, Headers, Req) when
    is_integer(Status), Status >= 200, Status =< 599, is_list(Headers)
->
    roadrunner_respond_writer:final(stream, {stream, Status, Headers}, Req).

-doc """
Send bytes `[Offset, Offset + Length)` of a file as the response body, as
a `{sendfile, ...}` response does: the headers must carry its
`content-length` and `content-type`. Returns `ok` once it is sent, or
`{error, Reason}` when it could not be.
""".
-spec sendfile(
    roadrunner_http:status(),
    roadrunner_http:headers(),
    roadrunner_handler:sendfile_spec(),
    roadrunner_req:request()
) -> ok | {error, term()}.
sendfile(Status, Headers, {_File, Offset, Length} = Spec, Req) when
    is_integer(Status),
    Status >= 200,
    Status =< 599,
    is_list(Headers),
    is_integer(Offset),
    Offset >= 0,
    is_integer(Length),
    Length >= 0
->
    roadrunner_respond_writer:final(sendfile, {sendfile, Status, Headers, Spec}, Req).
