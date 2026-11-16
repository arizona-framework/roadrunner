# gRPC

Roadrunner serves gRPC services on its HTTP/2 and HTTP/3 listeners. This
guide shows how to write a service, put it on a listener, and use what a
call can do: streams, metadata, status codes, deadlines, compression,
telemetry, the health service and server reflection. Then it shows how to use
Protocol Buffers, how to write a codec, and the small gRPC client roadrunner
comes with.

## What you get

- the four call kinds: unary, server streaming, client streaming and
  bidirectional streaming
- gRPC over HTTP/2 (TLS or cleartext h2c) and over HTTP/3
- request and response metadata, with `-bin` values as plain bytes
- every gRPC status code, sent as a status and a message
- deadlines from `grpc-timeout`, and a way to learn that the client
  cancelled or that the server is shutting down
- a method can wait for the next request and its own messages at once,
  for a chat that also pushes what others say
- `gzip` and `deflate` message compression, both ways
- a limit on the size of each request message
- an event when each call starts and ends, for metrics and tracing
- gRPC's health service, `grpc.health.v1.Health`
- gRPC's server reflection, for tools such as `grpcurl`
- pluggable codecs: raw bytes by default, Protocol Buffers through the
  `roadrunner_grpc_protobuf` package, or your own
- a small gRPC client, `roadrunner_grpc_client`, for tests, tooling and
  simple calls

gRPC needs HTTP/2 or later, so a call that comes in over HTTP/1.1 is
answered `505 HTTP Version Not Supported`.

## How it fits together

A service is a module that implements the `roadrunner_grpc_service`
behaviour. It names the service and lists its methods, and it holds one
function per method.

`roadrunner_grpc:routes/1` turns your services into ordinary roadrunner
routes, one per service, at `/package.Service/:method`. You give these
routes to a listener like any other routes.

Each call runs its method on the request's own process, with a stream
(`t:roadrunner_grpc:stream/0`). The method reads requests from the stream
and writes responses to it, then returns the stream.

The gRPC core only moves bytes. A codec turns those bytes into messages
and back. The codec is picked by the request's `content-type`: plain
`application/grpc` is the `proto` subtype, `application/grpc+json` is the
`json` subtype. With no codec set, `roadrunner_grpc_codec_raw` hands your
method the bytes as the client sent them, and sends the bytes (any
iodata) you return.

## A first service

This unary service uses the raw codec, so a request is a binary and the
reply is iodata:

```erlang
-module(greeter).
-behaviour(roadrunner_grpc_service).
-export([name/0, rpcs/0, say_hello/2]).

name() -> ~"helloworld.Greeter".

rpcs() ->
    #{~"SayHello" => #{function => say_hello, kind => unary,
                       input => hello_request, output => hello_reply}}.

say_hello(Name, Stream) ->
    {reply, <<"hello ", Name/binary>>, Stream}.
```

- `name/0` is the full service name, `package.Service`, as the `.proto`
  file declares it
- `rpcs/0` maps each method name (as it appears in the call's path) to
  its function, its kind and its message types
- `input` and `output` are passed to the codec as the message types; the
  raw codec ignores them

The functions must be exported with the right arity: 2 for `unary` and
`server_stream` methods (the request and the stream), 1 for
`client_stream` and `bidi_stream` methods (the stream only). If one is
missing, the routes fail to compile and the listener does not start.

## Putting it on a listener

```erlang
{ok, _} = roadrunner:start_listener(grpc, #{
    port => 50051,
    protocols => [http2],
    body_buffering => manual,
    routes => roadrunner_grpc:routes(#{services => [greeter]})
}).
```

On plain TCP, `protocols => [http2]` serves cleartext HTTP/2 with prior
knowledge, which is what gRPC clients use for an insecure channel. To
serve HTTP/1.1 on the same port too, use `protocols => [http1, http2]`: a
connection that opens with the HTTP/2 preface is HTTP/2, any other is
HTTP/1.1 (see [Body buffering](#body-buffering-use-manual) for what that
means for the other routes). With TLS, add HTTP/3 too:

```erlang
{ok, _} = roadrunner:start_listener(grpc, #{
    port => 50051,
    protocols => [http2, http3],
    tls => [{certfile, "cert.pem"}, {keyfile, "key.pem"}],
    body_buffering => manual,
    routes => roadrunner_grpc:routes(#{services => [greeter]})
}).
```

`routes/1` returns a plain list of routes, so you can add other routes
next to them. Its routes answer `POST` only (`methods => [~"POST"]`): a
route above them that answers every method on the same paths, such as
`/:a/:b`, would take every call, so the listener refuses that table as it
starts (`unreachable_route`). Put the gRPC routes first, or give the
other route its own `methods`.

### Options

`routes/1` takes a map with `services` and these options, which apply to
every service in it:

- `services`: the service modules (or descriptor maps, see below)
- `codecs`: the codec modules the services speak, by default
  `[roadrunner_grpc_codec_raw]`
- `max_message_size`: the largest request message, in bytes
- `max_content_length`: the most all of a call's requests may add up to,
  in bytes, by default `infinity` (see
  [Message size limits](#message-size-limits))
- `middlewares`: middlewares for every route, see
  [Middlewares](#middlewares)
- `send_compression`: how responses are compressed, `identity` (the
  default), `gzip` or `deflate`
- `health`: `true` adds the health service, by default `false`
- `reflection`: `true` adds server reflection, by default `false`

A bad option raises, from `routes/1` itself or as the listener starts
(then wrapped as `{init_route_failed, Path, roadrunner_grpc, Reason}`),
with `{unknown_grpc_opt, Key}` or `{invalid_grpc_opt, Key, Value}`.

### Body buffering: use `manual`

The listener option `body_buffering` decides when a call's request body
is read.

With `body_buffering => manual`, a call reads its requests as they
arrive. Client streams and bidirectional streams really stream: a bidi
method can answer each request before the next one comes in. This is the
setting to use for gRPC.

With `auto` (the listener's default), the whole request body is read
before the method runs. That works for unary and server-streaming calls,
and for a client stream that fits in the listener's `max_content_length`.
But a bidi method then sees all the requests at once, only after the
client has finished sending, and a call over the cap is answered
`413 Payload Too Large` instead of a gRPC status.

`body_buffering` is a listener option, and with `manual` every other
handler on the listener must read its own body, over HTTP/1.1 as well as
HTTP/2 when the listener serves both. That is why a listener of its own is
the best place for gRPC. Setting `body_buffering` per route is on the
roadmap.

### Beside an Arizona app

An [Arizona](https://github.com/arizona-framework/arizona) app can serve
gRPC on the same listener and port as its pages, through a `grpc` entry in
its routes that uses `roadrunner_grpc:routes/1`. The
[arizona_roadrunner](https://github.com/arizona-framework/arizona_roadrunner#grpc)
README shows how.

### A service built at runtime

When the methods are only known at runtime (read from a schema, say),
pass a descriptor map in `services` in place of a module. It holds the
name and methods the callbacks would return, and the module with the
method functions:

```erlang
roadrunner_grpc:routes(#{services => [
    #{name => ~"helloworld.Greeter",
      module => greeter_impl,
      rpcs => #{~"SayHello" => #{function => say_hello, kind => unary,
                                 input => hello_request, output => hello_reply}}}
]}).
```

This is how the Protocol Buffers adapter builds services.

## The four call kinds

Every method returns the stream it was given (or a newer copy of it). A
method may also return `{error, Status, Message, Stream}` to end the call
with an error (see Errors and status codes).

### Unary

One request in, one response out. The function takes the request and the
stream and returns `{reply, Response, Stream}`:

```erlang
say_hello(Name, Stream) ->
    {reply, <<"hello ", Name/binary>>, Stream}.
```

### Server streaming

One request in, many responses out. Send each response with
`roadrunner_grpc:send/2`, which returns the stream to use next, and
return `{ok, Stream}`:

```erlang
%% rpcs: ~"Count" => #{function => count, kind => server_stream, ...}
count(N, Stream0) ->
    Stream = lists:foldl(
        fun(I, S) -> roadrunner_grpc:send(integer_to_binary(I), S) end,
        Stream0,
        lists:seq(1, binary_to_integer(N))
    ),
    {ok, Stream}.
```

### Client streaming

Many requests in, one response out. The function takes only the stream.
`roadrunner_grpc:recv/1` returns `{ok, Message, Stream}` for each request
and `{eof, Stream}` once the client has sent them all. Return
`{reply, Response, Stream}`:

```erlang
%% rpcs: ~"Sum" => #{function => sum, kind => client_stream, ...}
sum(Stream) ->
    sum(Stream, 0).

sum(Stream0, Total) ->
    case roadrunner_grpc:recv(Stream0) of
        {ok, N, Stream} -> sum(Stream, Total + binary_to_integer(N));
        {eof, Stream} -> {reply, integer_to_binary(Total), Stream}
    end.
```

### Bidirectional streaming

Many requests in, many responses out, in any order. Read with `recv/1`,
send with `send/2` as you go, and return `{ok, Stream}`:

```erlang
%% rpcs: ~"Chat" => #{function => chat, kind => bidi_stream, ...}
chat(Stream0) ->
    case roadrunner_grpc:recv(Stream0) of
        {ok, Message, Stream} -> chat(roadrunner_grpc:send(Message, Stream));
        {eof, Stream} -> {ok, Stream}
    end.
```

### The stream and the method's process

- the stream belongs to the call's process: send from that process only
- `recv/1` waits for the next request and nothing else; to wait for your
  own messages too, see the next section
- a request that ends the call (too large, malformed, past its deadline)
  is thrown out of `recv/1` and `info/2` so the core can answer with the
  right status, so do not wrap them in a catch-all `try` or `catch`
- if the client cancels or goes away, the method stops at its next write,
  quietly, as there is no one left to answer

### Waiting for requests and your own messages

A method that also gets messages of its own, such as a chat where the
client sends what it says and the server pushes what everyone else says,
cannot sit in `recv/1`. Ask for the next request with
`roadrunner_grpc:recv_async/1` instead: it returns at once, and the
request arrives in the method's mailbox. Hand every message you do not
handle yourself to `roadrunner_grpc:info/2`, which tells you what it is:

- `{message, Request, Stream}`: the next request; ask for the one after
  with `recv_async/1` when you are ready for it
- `{more, Stream}`: part of a request arrived and the rest is asked for
  already; just keep waiting
- `{eof, Stream}`: the client has sent all its requests
- `cancelled`: the client cancelled the call or went away; return
- `drain`: the server is shutting down (see below)
- `ignore`: the message is not the call's

```erlang
%% rpcs: ~"Chat" => #{function => chat, kind => bidi_stream, ...}
chat(Stream) ->
    ok = room:join(self()),
    loop(roadrunner_grpc:recv_async(Stream)).

loop(Stream) ->
    receive
        {said, Text} ->
            %% Someone else in the room.
            loop(roadrunner_grpc:send(Text, Stream));
        Other ->
            case roadrunner_grpc:info(Other, Stream) of
                {message, Text, Stream1} ->
                    ok = room:say(Text),
                    loop(roadrunner_grpc:recv_async(Stream1));
                {more, Stream1} ->
                    loop(Stream1);
                {eof, Stream1} ->
                    {ok, Stream1};
                cancelled ->
                    {ok, Stream};
                drain ->
                    {error, unavailable, ~"server shutting down", Stream};
                ignore ->
                    loop(Stream)
            end
    end.
```

Always go on with the stream `info/2` returns. One request is asked for
at a time: calling `recv_async/1` again before `info/2` handed you the
last one does nothing. The size limit, compression, the deadline and the
call's events work as with `recv/1`. You can still call `recv/1` after
`recv_async/1`: it waits for the request already asked for.

Both work with either body buffering mode. With `auto` the requests are
all read already, so each one arrives in the mailbox at once.

### When the server shuts down

When the listener drains (`roadrunner_listener:drain/2`), new calls are
refused and the calls running are left to finish until the drain's
timeout. A long streaming call should end early instead, so its client
can call again on another server: `info/2` returns `drain` for the
message the call's process gets. End the call with
`{error, unavailable, ~"server shutting down", Stream}`; gRPC clients
treat `UNAVAILABLE` as safe to retry. A method that never waits on its
own messages does not see the drain, and runs until it is done or the
drain's timeout stops it.

## Metadata, headers and trailers

`roadrunner_grpc:metadata/1` returns the request's custom metadata as a
list of `{Name, Value}` pairs. It leaves out the headers HTTP/2 and gRPC
use themselves (`content-type`, `te`, `user-agent`, `host` and every
`grpc-*` name). Names are lowercase.

`roadrunner_grpc:set_headers/2` adds response headers and
`roadrunner_grpc:set_trailers/2` adds trailers, which go out after the
status when the call ends:

```erlang
say_hello(Name, Stream0) ->
    case lists:keyfind(~"x-api-key", 1, roadrunner_grpc:metadata(Stream0)) of
        {_, ~"secret"} ->
            Stream1 = roadrunner_grpc:set_headers([{~"x-served-by", ~"node-a"}], Stream0),
            Stream = roadrunner_grpc:set_trailers([{~"x-trace-bin", <<1, 2, 3>>}], Stream1),
            {reply, <<"hello ", Name/binary>>, Stream};
        _ ->
            {error, unauthenticated, ~"bad api key", Stream0}
    end.
```

- a name ending in `-bin` carries bytes: you read and write plain bytes,
  and roadrunner does the base64 on the wire
- a request `-bin` value with several comma-separated parts gives one
  entry per part; one that is not valid base64 ends the call with
  `INTERNAL` before the method runs
- names you set are made of `0-9`, `a-z`, `_`, `-` and `.`, and cannot
  be a name gRPC or HTTP/2 sets itself (`grpc-status`, `grpc-message`,
  `grpc-status-details-bin`, `grpc-encoding`, `grpc-accept-encoding`,
  `grpc-timeout`, `grpc-message-type`, `content-type`, `content-length`,
  `te`)
- values you set, other than `-bin` ones, are printable ASCII with no
  space at either end
- a name or value that breaks these rules raises
  `{invalid_metadata, Name}` from `set_headers/2` or `set_trailers/2`, so
  the call ends with `INTERNAL`
- headers go out with the first response, so `set_headers/2` after the
  first `send/2` raises `headers_already_sent` (and the call ends with
  `INTERNAL`); trailers can be added until the method returns

`roadrunner_grpc:peer/1` returns the client's address as
`{IP, Port}`.

`roadrunner_grpc:request/1` returns the call's HTTP request, for what
the metadata leaves out. Read it with the `roadrunner_req` functions:
the client's certificate with `roadrunner_req:peercert/1`, its TLS
session with `roadrunner_req:tls_info/1`, what a middleware put on the
request with `roadrunner_req:private/2`, the `request_id`, and any header,
`grpc-*` ones included, with `roadrunner_req:header/2`. It is for
reading: the call reads the request body itself, so read the requests
with `recv/1` or `recv_async/1`, not through the request.

```erlang
whoami(_Request, Stream) ->
    case roadrunner_req:peercert(roadrunner_grpc:request(Stream)) of
        {ok, Der} -> {reply, subject(Der), Stream};
        {error, _} -> {error, unauthenticated, ~"no client certificate", Stream}
    end.
```

## Errors and status codes

A call answers HTTP `200` and ends with a gRPC status in its trailers:

- `OK` when the method returns normally
- the status of an `{error, Status, Message, Stream}` return, or of an
  `{error, Status, Message, Details, Stream}` one (see
  [Error details](#error-details))
- `INTERNAL` when the method crashes; the crash is logged with the stack,
  under the logger domain `[roadrunner, grpc]`, and the client gets only
  `internal error`

`Status` is one of gRPC's status codes by name, an atom of
`t:roadrunner_grpc:status/0`: `cancelled`, `unknown`, `invalid_argument`,
`deadline_exceeded`, `not_found`, `already_exists`, `permission_denied`,
`resource_exhausted`, `failed_precondition`, `aborted`, `out_of_range`,
`unimplemented`, `internal`, `unavailable`, `data_loss` and
`unauthenticated`. `Message` is a UTF-8 binary for the client;
roadrunner encodes it for the `grpc-message` trailer.

```erlang
get_user(Id, Stream) ->
    case users:find(Id) of
        {ok, User} -> {reply, User, Stream};
        error -> {error, not_found, <<"no user ", Id/binary>>, Stream}
    end.
```

A streaming method can send some responses and then return an error: the
client gets the responses, then the error status. A call that fails
before any response is answered with the status in the response headers
alone (gRPC's Trailers-Only form).

### Error details

gRPC's richer error model attaches details to a status: messages such as
`google.rpc.BadRequest` (which fields were wrong) or
`google.rpc.RetryInfo` (when to try again). Return
`{error, Status, Message, Details, Stream}`, `Details` a list of
`{TypeUrl, Value}`, each a `google.protobuf.Any`: `TypeUrl` names the
detail's message type and `Value` is that message encoded, with your
codec. roadrunner sends them in the `grpc-status-details-bin` trailer as
a `google.rpc.Status` whose code and message are the call's own, as gRPC
clients check (grpc-go turns a mismatch into `INTERNAL`), and its client
libraries hand them to your code (`status.FromError(err).Details()` in
Go, `StatusProto.fromThrowable` in Java).

```erlang
create_user(#{name := <<>>}, Stream) ->
    %% bad_request/2 encodes a google.rpc.BadRequest with your codec.
    Details = [{~"type.googleapis.com/google.rpc.BadRequest", bad_request(~"name", ~"is empty")}],
    {error, invalid_argument, ~"invalid user", Details, Stream};
```

`grpc-status-details-bin` is roadrunner's to set, so `set_trailers/2`
refuses it, and the details always agree with the status.

### Retry pushback

A client whose retry policy allows it retries a call that failed with a
retryable status (`UNAVAILABLE`, say). The `grpc-retry-pushback-ms`
trailer tells it how long to wait first, in milliseconds, or not to retry
at all with a negative or malformed value. Set it with `set_trailers/2`:

```erlang
{error, unavailable, ~"overloaded",
    roadrunner_grpc:set_trailers([{~"grpc-retry-pushback-ms", ~"500"}], Stream)}
```

roadrunner answers some calls for you:

- an unknown method of a known service: `UNIMPLEMENTED`
- a request message over `max_message_size`: `RESOURCE_EXHAUSTED`
- a request message that does not decode or decompress: `INTERNAL`
- a unary or server-streaming call with no request message, or more than
  one: `INTERNAL`
- a `grpc-encoding` other than `identity`, `gzip` and `deflate`:
  `UNIMPLEMENTED`

Some requests are refused at the HTTP level, before any call starts:

- over HTTP/1.1: `505`
- a method other than `POST`: the router's `405`, with `allow: POST`
- a `content-type` none of the codecs speak: `415`
- an unknown service: the router's `404`, which gRPC clients read as
  `UNIMPLEMENTED`

One more is answered at the HTTP level once the call runs: response
headers too big for the client's `SETTINGS_MAX_HEADER_LIST_SIZE` cannot
be sent, so the call gets a `500` and stops.

## Middlewares

`middlewares` puts route middlewares (see `roadrunner_middleware`) on
every route `routes/1` returns, the health and reflection ones included,
as gRPC servers apply their interceptors to every service they serve. A
middleware runs before the call starts, with the request: it can check
the request's metadata (as headers) or the client's certificate, put
values on the request for the method (`roadrunner_req:put_private/3`,
read back through `roadrunner_grpc:request/1`), and refuse the call.

To refuse a call, return `roadrunner_grpc:reject(Status, Message, Req)`
in place of `Next(Req)`. It answers with the gRPC status and message in
the response headers (Trailers-Only), which is what gRPC clients read.
An HTTP error such as a `401` would reach them as `UNKNOWN` or
`UNAVAILABLE`, without your message.

```erlang
-module(api_key).
-behaviour(roadrunner_middleware).
-export([call/3]).

call(Req, Next, Keys) ->
    case roadrunner_req:header(~"x-api-key", Req) of
        Key when is_binary(Key) andalso is_map_key(Key, Keys) ->
            Next(roadrunner_req:put_private(api_client, map_get(Key, Keys), Req));
        _ ->
            roadrunner_grpc:reject(unauthenticated, ~"missing or unknown x-api-key", Req)
    end.
```

```erlang
roadrunner_grpc:routes(#{
    services => [greeter],
    health => true,
    middlewares => [{api_key, #{~"k1" => ~"client-1"}}]
})
```

`roadrunner_grpc:reject/4` takes a map of what goes with the status:
`details`, as a method returns them (see [Error details](#error-details)),
and `trailers`, metadata sent with the status, such as a retry pushback:

```erlang
roadrunner_grpc:reject(
    resource_exhausted,
    ~"rate limited",
    #{trailers => [{~"grpc-retry-pushback-ms", ~"1000"}]},
    Req
)
```

A middleware that should let some calls through, such as health checks
from a load balancer, matches on the path, `/package.Service/Method`:

```erlang
call(Req, Next, Keys) ->
    case roadrunner_req:path(Req) of
        <<"/grpc.health.v1.Health/", _/binary>> -> Next(Req);
        _ -> check_key(Req, Next, Keys)
    end.
```

A call a middleware rejects never starts: its method does not run and it
emits no gRPC call events, only the request's own (see
[Telemetry](#telemetry)). The listener's `middlewares` run too, before
the routes' ones, for gRPC requests as for any other.

## Deadlines and cancellation

A client sets a deadline with the `grpc-timeout` header. If a `recv/1`, or
a request asked for with `recv_async/1`, is still waiting when it passes,
the call ends with `DEADLINE_EXCEEDED`. A
call still running shortly after the deadline is cancelled: its stream is
reset, and the method stops at its next read or write. Without a
`grpc-timeout`, a call may run for as long as the client stays connected.

`roadrunner_grpc:deadline/1` returns when the deadline passes, in
`erlang:monotonic_time(millisecond)` units, or `infinity`. Use it to
bound your own work, such as a call to another service:

```erlang
lookup(Request, Stream) ->
    Timeout =
        case roadrunner_grpc:deadline(Stream) of
            infinity -> 5000;
            Deadline -> max(0, Deadline - erlang:monotonic_time(millisecond))
        end,
    case backend:lookup(Request, Timeout) of
        {ok, Reply} -> {reply, Reply, Stream};
        {error, timeout} -> {error, deadline_exceeded, ~"backend timed out", Stream}
    end.
```

With `body_buffering => auto`, the deadline counts from when the body was
read, a little after the client started its clock.

### Learning that the client cancelled

A method that only sends and receives through the stream needs nothing
more: a cancelled call stops it at its next write. A method that waits in
its own `receive`, such as a server stream that pushes events, gets a
message when the client cancels or its connection goes away. Hand each
message you do not expect to `roadrunner_grpc:info/2`, and return when it
says `cancelled`; it also tells you when the server shuts down:

```erlang
watch(_Request, Stream) ->
    ok = events:subscribe(self()),
    events(Stream).

events(Stream) ->
    receive
        {event, Data} ->
            events(roadrunner_grpc:send(Data, Stream));
        Other ->
            case roadrunner_grpc:info(Other, Stream) of
                cancelled -> {ok, Stream};
                drain -> {error, unavailable, ~"server shutting down", Stream};
                ignore -> events(Stream)
            end
    end.
```

`roadrunner_grpc:cancelled/2` answers only the first question, `true`
when the call is over, for a method that has no use for the drain.

## Compression

Requests may come compressed with `gzip` or `deflate`, as the client's
`grpc-encoding` says. roadrunner decompresses them before your method sees
them, and every response says it reads `identity`, `gzip` and `deflate`.
`roadrunner_grpc:recv_compressed/1` tells whether the last message
`recv/1` returned came compressed (for unary and server-streaming
methods, the request).

Responses are not compressed unless you ask. Set it for every call on the
routes:

```erlang
roadrunner_grpc:routes(#{services => [greeter], send_compression => gzip})
```

or for one call, before its first response, with
`roadrunner_grpc:set_send_compression/2` (`identity`, `gzip` or
`deflate`); after the first response it raises `headers_already_sent`:

```erlang
report(Request, Stream0) ->
    Stream = roadrunner_grpc:set_send_compression(gzip, Stream0),
    {reply, reports:build(Request), Stream}.
```

Responses are compressed only when the client's `grpc-accept-encoding`
lists the encoding; otherwise they go out as they are.

To send one message uncompressed in a compressed call, use
`roadrunner_grpc:send/3` with `#{compress => false}`. This is how gRPC
keeps a message that carries a secret out of a compressed stream:

```erlang
Stream1 = roadrunner_grpc:send(Token, Stream0, #{compress => false})
```

## Message size limits

Two limits bound what a client can send:

- `max_message_size` bounds each request message, both as it arrives and
  after it is decompressed, so a small compressed message cannot expand
  into a huge one; a larger message ends the call with
  `RESOURCE_EXHAUSTED`
- `max_content_length` bounds all of a call's requests together, by
  default `infinity`: no bound

gRPC has no limit on a whole call: a client stream or bidi stream may go
on for as long as it lives, and gRPC servers such as grpc-go and
grpc-java set none. With `manual` buffering a call never holds more than
the message it is reading, which `max_message_size` bounds, and the
client sends only as fast as the method reads (HTTP/2 and HTTP/3 flow
control), so the default stays `infinity`. Set `max_content_length` on
the routes to end a call that sends more than that in all with
`RESOURCE_EXHAUSTED`:

```erlang
roadrunner_grpc:routes(#{
    services => [upload_service],
    max_message_size => 1_048_576,
    max_content_length => 1_073_741_824
})
```

With `auto` buffering the listener reads a call's whole body before the
method runs, so a route left at `infinity` keeps the listener's
`max_content_length` (10 MB by default), and a body over it is answered
`413`.

See [Resource limits](resource_limits.md) for the defaults.

## Telemetry

Each call emits events to roadrunner's event handler (see
`roadrunner_event_handler`), as requests do:

- `grpc_call_start` as the call starts, with the request, the service's
  full name, the method's name and the call kind (`undefined` for a
  method the service does not have); what the handler returns is the
  call's span
- `grpc_call_stop` as the call ends, with the span, the status and its
  message, how the call ended, the messages read and sent with their
  bytes, and the encodings both ways
- `grpc_call_exception` in place of the stop when the method crashed
  (the client gets `INTERNAL`) or the call raised as it ended (trailers
  too large for the client, say, which reset the stream), with the span,
  the class, reason and stacktrace, and the same messages and encodings

How a call ended is one of:

- `normal`: it ended `OK`
- `error`: it ended with another status, yours or one roadrunner
  answered for you (a call you end `UNAVAILABLE` on a drain among them)
- `cancelled`: the client cancelled it or went away before it could
  read the status; the status is `cancelled`
- `deadline`: the same, from 50 ms before its deadline on; the status is
  `deadline_exceeded`. The time that counts is when the call learned the
  client was gone: when `roadrunner_grpc:info/2` or
  `roadrunner_grpc:cancelled/2` said so, or else at its next read or
  write or as its status went out, which can be long after the client
  cancelled if the method keeps working without either.
  The deadline counts from when the call starts (with `auto` buffering,
  after the body was read), so a client that cancels at its own deadline
  is reported `cancelled` when its body took more than about 50 ms to
  arrive
- `stopped`: it ended with no gRPC status (an `exit({shutdown, _})`, or
  response headers too large for the client); the status is the one a
  client reads then, `unknown` before any response and `internal` after

A request answered before its call starts emits no gRPC call events:
an HTTP refusal (`405`, `415`, `505`, the router's `404`) or a
middleware's `roadrunner_grpc:reject/3`. Its request events
(`request_start`, `request_stop`) report it.

Every call that starts ends with exactly one stop or exception event,
unless its process dies of an exit signal it does not trap (such as
`exit(Pid, kill)` or a linked process crashing) or its method never
returns. Calls to the health service and to server reflection emit the
same events, under their own service names
(`grpc.health.v1.Health`, `grpc.reflection.v1.ServerReflection`).
A call checks the handler once, as it starts. With the default
`roadrunner_event_noop` it emits no events and keeps no counts, so
event work costs a call almost nothing until you set a handler. A call
that started under a handler still ends with its stop or exception
event if that handler crashes and is replaced while the call runs.
The events run in the call's own process, inside the request's events,
so the request's `request_id` ties them together. Time is not measured
for you: read `erlang:monotonic_time/0` in the start event and keep it
in the span. A handler that sends these to the `telemetry` library, a
Prometheus exporter or OpenTelemetry can label them by service, method,
kind and status.

```erlang
handle_event(grpc_call_start, {_Req, Service, Method, _Kind}) ->
    {erlang:monotonic_time(), Service, Method};
handle_event(grpc_call_stop, {{Start, Service, Method}, Status, _Message, _How, _, _}) ->
    Duration = erlang:monotonic_time() - Start,
    my_metrics:observe(Service, Method, Status, Duration);
handle_event(_Event, _Args) ->
    ok.
```

## The health service

gRPC's health service (`grpc.health.v1.Health`) lets load balancers and
probes such as `grpc_health_probe` ask whether your server and its
services are serving. Add it with `health => true`:

```erlang
routes => roadrunner_grpc:routes(#{services => [greeter], health => true})
```

It speaks its own Protocol Buffers messages, whatever codecs your
services use, so it needs no extra setup.

Set each service's status with `roadrunner_grpc_health:set_status/2`, by
its full name. The empty name stands for the whole server, which starts
`serving`:

```erlang
ok = roadrunner_grpc_health:set_status(~"helloworld.Greeter", serving),
ok = roadrunner_grpc_health:set_status(~"", not_serving).
```

The status is `serving`, `not_serving`, or `unknown` to forget it.

- `Check` answers a service's status, `NOT_FOUND` for a service with no
  status
- `List` answers every status set
- `Watch` sends a service's status at once and again each time it
  changes, until the client cancels; a service with no status is
  `SERVICE_UNKNOWN` until it gets one

When the listener drains, each `Watch` ends, first sending `NOT_SERVING`
unless that was already its last status or its service has no status, so
a load balancer moves away. The statuses live in a process roadrunner
supervises: if it restarts, they start over (the server `serving`, the
rest unset), and each `Watch` ends with `UNAVAILABLE` so its client
watches again.

## Server reflection

Server reflection lets tools such as `grpcurl` and `grpcui` ask your
server which services it has and how their messages look, so you can call
them without a copy of the `.proto` files. Add it with
`reflection => true`:

```erlang
routes => roadrunner_grpc:routes(#{services => [greeter], reflection => true})
```

It answers on `grpc.reflection.v1.ServerReflection` and on the older
`grpc.reflection.v1alpha.ServerReflection`, which some tools still call
first. Like the health service, it speaks its own Protocol Buffers
messages, whatever codecs your services use.

To describe a service, it needs the service's `.proto` files: each one a
serialized `google.protobuf.FileDescriptorProto`, the file that declares
the service and the files it imports. A service module gives them with
the optional `files/0` callback, which returns the list of binaries, and
a descriptor map with a `files` key holding the same list.
The Protocol Buffers package can fill them in for you (see below).

With the files, reflection answers:

- which file declares a name: a message, enum, enum value, service,
  method, field, oneof or extension, by its full name such as
  `helloworld.Greeter.SayHello`
- a file by its name
- which file declares an extension of a message, and the numbers of a
  message's extensions

Each answer holds the file and the files it imports, all the way down. A
file already sent on the same stream is not sent again as an import.
When two services give a file of the same name, the first one is kept.
Anything reflection does not know is answered `NOT_FOUND`.

Reflection lists the services that give their descriptor files, plus the
health service and reflection itself, which give gRPC's own. A service
that gives no files (one that speaks the raw codec, say) is left out of
the list, so every service a tool such as `grpcurl` or `grpcui` is told of
can be described: those tools describe each listed service as they start,
and stop at the first one they cannot.

A bad `files` value raises as the listener starts, like any other bad
option.

## Protocol Buffers

Most gRPC services speak Protocol Buffers. The
[`roadrunner_grpc_protobuf`](https://github.com/arizona-framework/roadrunner_grpc_protobuf)
package builds a service from a generated Protocol Buffers module and is
the codec that encodes and decodes its messages, so your methods get and
return messages instead of bytes. Its README covers adding it, generating
the module, naming the methods, and server reflection. A service it
builds goes in `services` like any other, with the package in `codecs`:

```erlang
routes => roadrunner_grpc:routes(#{
    services => [roadrunner_grpc_protobuf:service(helloworld_pb, ~"helloworld.Greeter", greeter)],
    codecs => [roadrunner_grpc_protobuf]
})
```

## Writing a codec

A codec is a module that implements `roadrunner_grpc_codec`: the
`content-type` subtype it answers, and how a message turns into bytes and
back. `Type` is the method's `input` or `output` from `rpcs/0`, passed
through as it is:

```erlang
-module(my_json_codec).
-behaviour(roadrunner_grpc_codec).
-export([subtype/0, encode/2, decode/2]).

subtype() -> ~"json".
encode(_Type, Message) -> json:encode(Message).
decode(_Type, Bytes) -> json:decode(Bytes).
```

List it in `codecs`, next to others if your services speak more than one:

```erlang
roadrunner_grpc:routes(#{services => [greeter], codecs => [my_json_codec]})
```

This codec answers `application/grpc+json`. If `decode/2` raises, the
call ends with `INTERNAL`.

## gRPC client

`roadrunner_grpc_client` calls gRPC servers, roadrunner's own or any
other, over HTTP/2: cleartext h2c or TLS with ALPN `h2`. It is made for
tests, tooling and simple service-to-service calls.

```erlang
{ok, Conn} = roadrunner_grpc_client:connect("localhost", 50051, #{}),
{ok, Reply, _Meta} =
    roadrunner_grpc_client:unary(Conn, ~"/helloworld.Greeter/SayHello", ~"world", #{
        timeout => 1000
    }),
ok = roadrunner_grpc_client:close(Conn).
```

It does the four call kinds (`unary/4`, and `stream/3` with `send/2`,
`close_send/1` and `recv/2` for the streaming ones), metadata both ways
with `-bin` values as plain bytes, every status code, deadlines it sends
as `grpc-timeout` and also enforces itself, cancellation, `gzip` and
`deflate` compression both ways, and a limit on the size of each
response message. Calls take the same codecs as your services, so
`codec => my_json_codec` sends `application/grpc+json`. A non-`OK` call
returns `{error, {grpc, Status, Message, Trailers}}`.

It is not a production client. It has no HTTP/3, no reconnect or
backoff, no keepalive pings, no name resolution or load balancing, no
retries, hedging or service config, no connection pooling (one
connection, with every call multiplexed on it), no interceptors and no
telemetry events, and it talks to one address. Response header lists are
capped at its `max_header_list_size` (64 KiB by default). See
`roadrunner_grpc_client` for the whole API and its limitations.
