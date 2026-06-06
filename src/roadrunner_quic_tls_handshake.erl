-module(roadrunner_quic_tls_handshake).
-moduledoc false.

%% TLS 1.3 handshake-message framing (RFC 8446 §4) as carried in QUIC
%% CRYPTO frames. Each message is a 1-byte HandshakeType, a 24-bit
%% big-endian body length, then the body. QUIC places these directly in
%% the CRYPTO stream with no TLS record layer (RFC 9001 §4), so this
%% module frames only the Handshake struct.
%%
%% Pure wire syntax only: `encode/2` frames a type + body, and `decode/1`
%% peels one message off the front of a buffer, returning the remainder
%% so back-to-back messages in one CRYPTO run decode in sequence. The
%% HandshakeType stays a raw integer; naming it and building/parsing the
%% per-type body belong to the messages layered on top of this framing.
%%
%% Framing never fails: any buffer is either a complete message
%% (`{ok, {Type, Body}, Rest}`) or a prefix that needs more bytes
%% (`{more, Need}`), reported in two phases (the 4-byte header first,
%% then the body once its length is known). The decoded message is the
%% `{Type, Body}` pair, in the middle slot of the same `{ok, Value, Rest}`
%% shape the other codecs use. Encoders return an iolist so a large
%% Certificate body is framed by prepending the header, never copied.

-export([encode/2, decode/1]).

-export_type([message/0, decode_result/0]).

-type message() :: {Type :: non_neg_integer(), Body :: binary()}.

-type decode_result() ::
    {ok, message(), Rest :: binary()}
    | {more, Need :: pos_integer()}.

%% =============================================================================
%% encode/2
%% =============================================================================

-doc """
Frame a handshake message: the 1-byte `Type`, the 24-bit big-endian
length of `Body`, then `Body`. Returned as an iolist so a large body is
never copied. `Body` must be at most 2^24-1 bytes (the uint24 length).
""".
-spec encode(byte(), iodata()) -> iolist().
encode(Type, Body) ->
    [<<Type:8, (iolist_size(Body)):24>>, Body].

%% =============================================================================
%% decode/1
%% =============================================================================

-doc """
Decode the leading handshake message from `Bin`.

Returns:
- `{ok, {Type, Body}, Rest}` — a full message was present; `Rest` is the
  buffer that follows it (the next message, or `<<>>`).
- `{more, Need}` — the buffer is a prefix: `Need` more bytes are required
  to reach the next step (the 4-byte header, then the body).
""".
-spec decode(binary()) -> decode_result().
decode(<<Type:8, Length:24, Body:Length/binary, Rest/binary>>) ->
    {ok, {Type, Body}, Rest};
decode(<<_Type:8, Length:24, Partial/binary>>) ->
    %% Full header, body short: ask for the rest of the body.
    {more, Length - byte_size(Partial)};
decode(Bin) ->
    %% Fewer than the 4 header bytes (1 type + 3 length) buffered.
    {more, 4 - byte_size(Bin)}.
