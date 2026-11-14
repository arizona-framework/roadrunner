-module(roadrunner_grpc_frame).
-moduledoc false.

%% gRPC message framing over the HTTP/2 or HTTP/3 body (gRPC's
%% PROTOCOL-HTTP2, "Length-Prefixed-Message"): a Compressed-Flag byte (0 or
%% 1), the message length as a 4-byte big-endian unsigned integer, then the
%% message. DATA frame boundaries say nothing about message boundaries, so
%% `decode/2` works on whatever bytes have arrived and asks for more until a
%% whole message is there.

-export([encode/2, decode/2]).

-export_type([decoded/0]).

-type decoded() ::
    {ok, Compressed :: boolean(), Message :: binary(), Rest :: binary()}
    | more
    | {error, message_too_large | bad_compressed_flag}.

-doc """
Frame one message, `Compressed` saying whether its bytes went through the
call's `grpc-encoding`.
""".
-spec encode(boolean(), iodata()) -> iodata().
encode(Compressed, Message) ->
    [<<(flag(Compressed)), (iolist_size(Message)):32>>, Message].

-doc """
Take the first message off `Buffer`, one of at most `MaxSize` bytes. A
message announced larger is refused before its bytes are waited for, and a
Compressed-Flag other than 0 or 1 is malformed.
""".
-spec decode(binary(), non_neg_integer()) -> decoded().
decode(<<Flag, Len:32, Message:Len/binary, Rest/binary>>, MaxSize) when
    Flag =< 1, Len =< MaxSize
->
    {ok, Flag =:= 1, Message, Rest};
decode(<<Flag, _/binary>>, _MaxSize) when Flag > 1 ->
    {error, bad_compressed_flag};
decode(<<_Flag, Len:32, _/binary>>, MaxSize) when Len > MaxSize ->
    {error, message_too_large};
decode(_Buffer, _MaxSize) ->
    more.

-spec flag(boolean()) -> 0 | 1.
flag(false) -> 0;
flag(true) -> 1.
