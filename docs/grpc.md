# gRPC

Roadrunner serves gRPC services on its HTTP/2 and HTTP/3 listeners. This
guide shows how to write a service, put it on a listener, and use what a
call can do: streams, metadata, status codes, deadlines, compression and
the health service. The last part shows how to use Protocol Buffers.

## What you get

- the four call kinds: unary, server streaming, client streaming and
  bidirectional streaming
- gRPC over HTTP/2 (TLS or cleartext h2c) and over HTTP/3
- request and response metadata, with `-bin` values as plain bytes
- every gRPC status code, sent as a status and a message
- deadlines from `grpc-timeout`, and a way to learn that the client
  cancelled
- `gzip` and `deflate` message compression, both ways
- a limit on the size of each request message
- gRPC's health service, `grpc.health.v1.Health`
- pluggable codecs: raw bytes by default, Protocol Buffers through gpb, or
  your own

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
knowledge, which is what gRPC clients use for an insecure channel. With
TLS, add HTTP/3 too:

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
next to them.

### Options

`routes/1` takes a map with `services` and these options, which apply to
every service in it:

- `services`: the service modules (or descriptor maps, see below)
- `codecs`: the codec modules the services speak, by default
  `[roadrunner_grpc_codec_raw]`
- `max_message_size`: the largest request message, in bytes
- `max_content_length`: the most all of a call's requests may add up to,
  in bytes, set on each route in place of the listener's
- `send_compression`: how responses are compressed, `identity` (the
  default), `gzip` or `deflate`
- `health`: `true` adds the health service, by default `false`

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
and for a client stream that fits in `max_content_length`. But a bidi
method then sees all the requests at once, only after the client has
finished sending, and a call over `max_content_length` is answered
`413 Payload Too Large` instead of a gRPC status.

`body_buffering` is a listener option, and with `manual` every other
handler on the listener must read its own body. That is why a listener of
its own is the best place for gRPC.

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
- `recv/1` waits for the next request, so a method cannot wait for other
  messages at the same time
- a request that ends the call (too large, malformed, past its deadline)
  is thrown out of `recv/1` so the core can answer with the right status,
  so do not wrap `recv/1` in a catch-all `try` or `catch`
- if the client cancels or goes away, the method stops at its next write,
  quietly, as there is no one left to answer

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
  `grpc-encoding`, `grpc-accept-encoding`, `grpc-timeout`,
  `grpc-message-type`, `content-type`, `content-length`, `te`)
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

## Errors and status codes

A call answers HTTP `200` and ends with a gRPC status in its trailers:

- `OK` when the method returns normally
- the status of an `{error, Status, Message, Stream}` return
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
- a method other than `POST`: `405`
- a `content-type` none of the codecs speak: `415`
- an unknown service: the router's `404`, which gRPC clients read as
  `UNIMPLEMENTED`

One more is answered at the HTTP level once the call runs: response
headers too big for the client's `SETTINGS_MAX_HEADER_LIST_SIZE` cannot
be sent, so the call gets a `500` and stops.

## Deadlines and cancellation

A client sets a deadline with the `grpc-timeout` header. If a `recv/1` is
still waiting when it passes, the call ends with `DEADLINE_EXCEEDED`. A
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
message when the client cancels or its connection goes away. Check each
message you do not expect with `roadrunner_grpc:cancelled/2`, and return
when it says `true`:

```erlang
watch(_Request, Stream) ->
    ok = events:subscribe(self()),
    events(Stream).

events(Stream) ->
    receive
        {event, Data} ->
            events(roadrunner_grpc:send(Data, Stream));
        Other ->
            case roadrunner_grpc:cancelled(Other, Stream) of
                true -> {ok, Stream};
                false -> events(Stream)
            end
    end.
```

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
- `max_content_length` bounds all of a call's requests together; with
  `manual` buffering, a call over it ends with `RESOURCE_EXHAUSTED`, and
  with `auto` the request is answered `413`

A client stream or bidi stream that lives long can send a lot over its
life, so set `max_content_length` on the routes to what such a call may
total:

```erlang
roadrunner_grpc:routes(#{
    services => [chat_service],
    max_message_size => 1_048_576,
    max_content_length => 1_073_741_824
})
```

See [Resource limits](resource_limits.md) for the defaults.

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

## Protocol Buffers with gpb

Most gRPC services speak Protocol Buffers. roadrunner's adapter,
`roadrunner_grpc_protobuf`, works with modules generated by
[gpb](https://github.com/tomas-abrahamsson/gpb). It builds a service from
what a gpb module knows of it, and it is also the codec that encodes and
decodes the messages.

> #### Not a package yet {: .warning}
>
> The adapter lives in roadrunner's repository under `grpc_protobuf/`,
> and today it is built only in roadrunner's own `test` profile, so it is
> not part of the roadrunner package. It will become a package of its
> own. Until then you can use the raw codec and call your gpb module
> yourself, or write a codec of your own (see Writing a codec).

### Generating the module

Generate the gpb module with services and introspection functions (both
gpb defaults). With `rebar3_gpb_plugin`, for example:

```erlang
{plugins, [rebar3_gpb_plugin]}.
{gpb_opts, [
    {i, "proto"},
    {o_erl, "src"},
    {o_hrl, "include"},
    {module_name_suffix, "_pb"},
    maps,
    strings_as_binaries
]}.
{provider_hooks, [{pre, [{compile, {protobuf, compile}}]}]}.
```

With the `maps` option, messages are maps; without it they are records.

### The service

For a `helloworld.proto` with:

```proto
package helloworld;

service Greeter {
  rpc SayHello (HelloRequest) returns (HelloReply);
}
```

the methods go in a module of their own, one function per method named
after it in snake case (`SayHello` is `say_hello/2`). They are called as
in the rest of this guide, with messages in the shape gpb gives them:

```erlang
-module(greeter).
-export([say_hello/2]).

say_hello(#{name := Name}, Stream) ->
    {reply, #{message => <<"Hello ", Name/binary>>}, Stream}.
```

`roadrunner_grpc_protobuf:service/3` builds the service from the gpb
module, the service name and your module, and `roadrunner_grpc_protobuf`
goes in `codecs`:

```erlang
{ok, _} = roadrunner:start_listener(grpc, #{
    port => 50051,
    protocols => [http2],
    body_buffering => manual,
    routes => roadrunner_grpc:routes(#{
        services => [roadrunner_grpc_protobuf:service(helloworld_pb, ~"helloworld.Greeter", greeter)],
        codecs => [roadrunner_grpc_protobuf]
    })
}).
```

The service name is the full gRPC name as a binary
(`~"helloworld.Greeter"`), or its name in the gpb module as an atom:
`'Greeter'` with the options above, or `'helloworld.Greeter'` when gpb's
`use_packages` option is set.

### Options

`roadrunner_grpc_protobuf:service/4` takes an options map:

- `function_names`: how a method's function is named, `snake_case` (the
  default), `as_is` (`'SayHello'`), or a fun from the method name (a
  binary) to the function name (an atom)
- `unexported`: what to do with a method your module does not export,
  `error` (the default: the routes fail to compile, so a forgotten method
  shows up at startup) or `unimplemented` (the method is left out, and a
  call to it is answered `UNIMPLEMENTED`)

```erlang
roadrunner_grpc_protobuf:service(helloworld_pb, ~"helloworld.Greeter", greeter,
                                 #{unexported => unimplemented})
```

`service/3,4` raises at once for a gpb module with no services, an
unknown service, two methods that would share a function, or a bad
option.

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
