-module(roadrunner_send).
-moduledoc """
Send the response from inside the handler, as it runs.

A handler normally returns its response and the connection sends it. A
handler that returns `{send, Headers, Fun}` sends it itself instead: the
connection calls `Fun(Req)` and the fun sends the response with this
module's functions, then returns the request.

```erlang
handle(Req) ->
    {{send, [], fun send/1}, Req}.

send(Req0) ->
    ok = roadrunner_send:inform(103, [{~"link", ~"</app.css>; rel=preload"}], Req0),
    {ok, Body, Req} = roadrunner_req:read_body(Req0),
    ok = roadrunner_send:reply(roadrunner_resp:text(200, Body), Req),
    Req.
```

Use it when the response can only be decided while the handler runs:

- `inform/3` sends an interim 1xx response (such as `103 Early Hints`)
  before the final one, as many times as needed
- `reply/2` sends a complete response built with `roadrunner_resp`, and
  `reply/4` one given as its status, headers and body
- `stream/3` sends the status and headers and returns the same `Send`
  fun a `{stream, ...}` response gets, to write the body as it goes
- `file/4` sends a file, as a `{sendfile, ...}` response does

The fun sends one final response (`reply/2,4`, `stream/3` or `file/4`); a
second one raises `already_sent`. The calls take the request the fun
holds now, so pass the one returned by `roadrunner_req:read_body/1,2`,
and return the last one from the fun, as `handle/1` does. The calls work
only inside the fun.

The framework finishes what the fun leaves open. A stream the fun did
not end with `Send(Data, fin)` is ended when the fun returns. A fun that
returns without a final response gets a `500` sent for it. A fun that
crashes before a final response is answered `500`; one that crashes
after it closes the connection (HTTP/1.1) or resets the stream (HTTP/2,
HTTP/3) when the body was still open.

`Headers` in the `{send, Headers, Fun}` tuple is where middlewares add
their headers (`roadrunner_cors`, `roadrunner_security_headers`). They
are added to the final response, unless the call already sets a header
with the same name. `vary` is the exception: both values are kept.
Interim responses get only the headers they are given.
`roadrunner_compress` does not compress a response sent this way.

The rules of the other response shapes apply. Header names must be
lowercase. A response with a CR, LF or NUL in a header, or (on HTTP/2
and HTTP/3) headers over the client's header size limit, is not sent:
the final ones are answered `500` and the call returns an error. A HEAD
request gets no body from `reply/2,4` or `file/4`. An interim response
to an HTTP/1.0 client is skipped, as RFC 9110 §15.2 asks.
""".

-export([inform/3, reply/2, reply/4, stream/3, file/4]).

-export_type([sender/0]).

-doc """
The fun of a `{send, Headers, Fun}` response. It gets the request, sends
the response with this module's functions, and returns the request.
""".
-type sender() :: fun((roadrunner_req:request()) -> roadrunner_req:request()).

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
    roadrunner_send_writer:inform(Status, Headers, Req).

-doc """
Send a complete response built with `roadrunner_resp`, such as
`roadrunner_resp:json(200, Term)`. The same as `reply/4` with its
status, headers and body.
""".
-spec reply(roadrunner_resp:buffered_response(), roadrunner_req:request()) ->
    ok | {error, term()}.
reply({Status, Headers, Body}, Req) ->
    reply(Status, Headers, Body, Req).

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
    roadrunner_send_writer:final(buffered, {reply, Status, Headers, Body}, Req).

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
    roadrunner_send_writer:final(stream, {stream, Status, Headers}, Req).

-doc """
Send bytes `[Offset, Offset + Length)` of a file as the response body, as
a `{sendfile, ...}` response does: the headers must carry its
`content-length` and `content-type`. Returns `ok` once it is sent, or
`{error, Reason}` when it could not be.
""".
-spec file(
    roadrunner_http:status(),
    roadrunner_http:headers(),
    roadrunner_handler:sendfile_spec(),
    roadrunner_req:request()
) -> ok | {error, term()}.
file(Status, Headers, {_File, Offset, Length} = Spec, Req) when
    is_integer(Status),
    Status >= 200,
    Status =< 599,
    is_list(Headers),
    is_integer(Offset),
    Offset >= 0,
    is_integer(Length),
    Length >= 0
->
    roadrunner_send_writer:final(sendfile, {sendfile, Status, Headers, Spec}, Req).
