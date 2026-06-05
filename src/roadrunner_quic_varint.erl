-module(roadrunner_quic_varint).
-moduledoc false.

%% QUIC variable-length integer codec (RFC 9000 §16).
%%
%% The two most significant bits of the first byte select the length
%% class; the remaining bits are the value, big-endian:
%%
%% | Prefix | Bytes | Bits | Range |
%% |--------|-------|------|-------|
%% | 2#00   | 1     | 6    | 0 .. 63 |
%% | 2#01   | 2     | 14   | 0 .. 16383 |
%% | 2#10   | 4     | 30   | 0 .. 1073741823 |
%% | 2#11   | 8     | 62   | 0 .. 4611686018427387903 |
%%
%% Pure wire syntax: `encode/1` always emits the minimal-length form, and
%% `decode/1` reports `{more, Need}` for a truncated buffer rather than
%% crashing, so callers (`roadrunner_quic_h3_frame`, the packet/frame
%% codecs) can thread incremental input without a `try`.

-export([encode/1, decode/1]).

-export_type([decode_result/0]).

%% 2^6 - 1
-define(MAX_1, 63).
%% 2^14 - 1
-define(MAX_2, 16383).
%% 2^30 - 1
-define(MAX_4, 1073741823).
%% 2^62 - 1
-define(MAX_8, 4611686018427387903).

-type decode_result() ::
    {ok, non_neg_integer(), Rest :: binary()}
    | {more, Need :: pos_integer()}.

%% =============================================================================
%% encode/1
%% =============================================================================

-doc """
Encode a non-negative integer as a QUIC varint, in the minimal-length
form per RFC 9000 §16. The value must fit in 62 bits (0 ..
4611686018427387903); a larger value has no encoding and raises a
`function_clause`.
""".
-spec encode(non_neg_integer()) -> binary().
encode(V) when is_integer(V), V >= 0, V =< ?MAX_1 -> <<0:2, V:6>>;
encode(V) when is_integer(V), V > ?MAX_1, V =< ?MAX_2 -> <<1:2, V:14>>;
encode(V) when is_integer(V), V > ?MAX_2, V =< ?MAX_4 -> <<2:2, V:30>>;
encode(V) when is_integer(V), V > ?MAX_4, V =< ?MAX_8 -> <<3:2, V:62>>.

%% =============================================================================
%% decode/1
%% =============================================================================

-doc """
Decode the leading QUIC varint from `Bin`.

Returns:
- `{ok, Value, Rest}` — a full varint was present; `Rest` is the
  buffer that follows it.
- `{more, Need}` — the buffer is shorter than the length class its
  first byte selects (or empty); `Need` more bytes are required.
""".
-spec decode(binary()) -> decode_result().
decode(<<0:2, V:6, Rest/binary>>) ->
    {ok, V, Rest};
decode(<<1:2, V:14, Rest/binary>>) ->
    {ok, V, Rest};
decode(<<2:2, V:30, Rest/binary>>) ->
    {ok, V, Rest};
decode(<<3:2, V:62, Rest/binary>>) ->
    {ok, V, Rest};
decode(<<Prefix:2, _/bitstring>> = Bin) ->
    %% First byte present, but the selected length class wants more bytes.
    %% Prefix 0/1/2/3 maps to a total length of 1/2/4/8 bytes.
    {more, (1 bsl Prefix) - byte_size(Bin)};
decode(<<>>) ->
    {more, 1}.
