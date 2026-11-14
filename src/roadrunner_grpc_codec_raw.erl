-module(roadrunner_grpc_codec_raw).
-moduledoc """
The `roadrunner_grpc_codec` that leaves messages as bytes: a service gets
each request message as the binary the client sent and answers with iodata
it encoded itself. It answers the `proto` subtype (`application/grpc` and
`application/grpc+proto`), and it is the default when a route lists no
`codecs`.
""".

-behaviour(roadrunner_grpc_codec).

-export([subtype/0, encode/2, decode/2]).

-doc "The `proto` subtype.".
-spec subtype() -> binary().
subtype() ->
    ~"proto".

-doc "The message itself, already bytes.".
-spec encode(term(), iodata()) -> iodata().
encode(_Type, Message) ->
    Message.

-doc "The bytes themselves.".
-spec decode(term(), binary()) -> binary().
decode(_Type, Bytes) ->
    Bytes.
