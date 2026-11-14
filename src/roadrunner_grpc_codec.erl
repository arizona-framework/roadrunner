-module(roadrunner_grpc_codec).
-moduledoc """
A message codec for `roadrunner_grpc`: how a call's messages turn into
bytes and back. roadrunner's gRPC core moves bytes and never looks inside
them, so the codec is what knows the schema, such as Protocol Buffers.

A codec is picked by the request's `content-type`: `application/grpc` is
the `proto` subtype, `application/grpc+json` the `json` one. The
`roadrunner_grpc` route option `codecs` lists the codecs a service speaks;
`roadrunner_grpc_codec_raw`, the default, hands the bytes over as they are.

```erlang
-module(my_json_codec).
-behaviour(roadrunner_grpc_codec).
-export([subtype/0, encode/2, decode/2]).

subtype() -> ~"json".
encode(_Type, Message) -> json:encode(Message).
decode(_Type, Bytes) -> json:decode(Bytes).
```

`Type` is the `input` or `output` a service gives a method in
`c:roadrunner_grpc_service:rpcs/0`, passed through as it is. A message that
does not decode makes `decode/2` raise, and the call ends with the gRPC
status `INTERNAL`.
""".

-doc "The `content-type` subtype the codec answers, such as `~\"proto\"`.".
-callback subtype() -> binary().

-doc "The bytes of a message of type `Type`.".
-callback encode(Type :: term(), Message :: term()) -> iodata().

-doc "The message of type `Type` the bytes hold; raises when they hold none.".
-callback decode(Type :: term(), Bytes :: binary()) -> term().
