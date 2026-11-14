-module(roadrunner_grpc_service).
-moduledoc """
A gRPC service for `roadrunner_grpc`: its full name and its methods. The
module that implements the behaviour also holds the method functions.

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

Each method is called on its own process, with the `t:roadrunner_grpc:stream/0`
of the call, and returns what the call answers:

- `unary`: `Function(Request, Stream)` returns `{reply, Response, Stream}`
- `server_stream`: `Function(Request, Stream)` sends its responses with
  `roadrunner_grpc:send/2` and returns `{ok, Stream}`
- `client_stream`: `Function(Stream)` reads the requests with
  `roadrunner_grpc:recv/1` and returns `{reply, Response, Stream}`
- `bidi_stream`: `Function(Stream)` reads with `roadrunner_grpc:recv/1`
  and sends with `roadrunner_grpc:send/2` as it goes, and returns
  `{ok, Stream}`

Any of them may instead return `{error, Status, Message, Stream}`, a
`t:roadrunner_grpc:status/0` and a UTF-8 message for the client. A method
that crashes ends the call with `INTERNAL`.

`input` and `output` are given to the call's `roadrunner_grpc_codec` as
the message types; the raw codec ignores them.
""".

-export_type([rpc/0, kind/0]).

-doc "How a method's requests and responses flow.".
-type kind() :: unary | server_stream | client_stream | bidi_stream.

-doc "A method: its function in the service module, its kind and message types.".
-type rpc() :: #{function := atom(), kind := kind(), input := term(), output := term()}.

-doc """
The service's full name, `package.Service` as the `.proto` file declares
it, the first segment of a call's path.
""".
-callback name() -> binary().

-doc "The service's methods, by the method name a call's path ends with.".
-callback rpcs() -> #{binary() => rpc()}.
