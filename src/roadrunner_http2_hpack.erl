-module(roadrunner_http2_hpack).
-moduledoc """
HPACK header compression for HTTP/2 (RFC 7541).

HPACK encodes header lists as a sequence of representations,
each referring to a static (61-entry, RFC-defined) or dynamic
(per-connection, FIFO) header table. Names and values are
length-prefixed strings, optionally Huffman-encoded
(`roadrunner_http2_hpack_huffman`).

This module exposes:

- `new_decoder/1` / `new_encoder/1` — fresh per-connection
  contexts pinned at a max table size.
- `decode/2` — parse a header block fragment, mutating the
  decoder's dynamic table per the spec.
- `encode/2` — emit a header block, mutating the encoder's
  dynamic table.
- `set_max_table_size/2` — drop the configured maximum;
  decoders apply the change to inbound updates, encoders MUST
  emit a Dynamic Table Size Update on the next `encode/2`
  call.

Header names are returned as **lowercase binaries** per RFC 9113
§8.2 case-folding requirement; the decoder rejects any uppercase
character in a literal name field with `bad_header_name`.

## Representations (RFC 7541 §6)

| Prefix bits | Meaning |
|----|---|
| `1xxxxxxx` | Indexed Header Field |
| `01xxxxxx` | Literal w/ Incremental Indexing — indexed/new name |
| `001xxxxx` | Dynamic Table Size Update |
| `0001xxxx` | Literal Never Indexed |
| `0000xxxx` | Literal w/o Indexing |

The encoder here always uses Literal w/ Incremental Indexing
when emitting non-indexed pairs. Indexed-name + literal-value
takes priority when the name appears in the static table.
""".

-export([
    new_decoder/1,
    new_encoder/1,
    decode/2,
    encode/2,
    set_max_table_size/2
]).

-export_type([context/0, header/0, decode_error/0]).

%% RFC 7541 Appendix A — 61 static-table entries. Defined up here
%% so it expands in every later guard / arithmetic site below.
-define(STATIC_TABLE_LEN, 61).

-record(hpack_ctx, {
    %% FIFO queue of dynamic-table entries. Newest at the front
    %% (lowest dynamic index = 62). Eldest is dropped first when
    %% the size limit forces eviction.
    %% Implemented as a list (cons at front, drop-and-rebuild on
    %% eviction) — for typical h2 dynamic tables (<=64 entries) a
    %% list is faster than a queue.
    table = [] :: [header()],
    %% Sum of `byte_size(Name) + byte_size(Value) + 32` per entry,
    %% per RFC 7541 §4.1.
    size = 0 :: non_neg_integer(),
    %% Currently-applied table size limit. Starts at the value
    %% passed to `new_decoder/1` / `new_encoder/1` and changes via
    %% Dynamic Table Size Update reps (decoder side) or
    %% `set_max_table_size/2` + outbound update emission (encoder
    %% side).
    max_size :: non_neg_integer(),
    %% Cap on `max_size` — set by SETTINGS_HEADER_TABLE_SIZE from
    %% the peer. The runtime `max_size` cannot exceed it; any
    %% Dynamic Table Size Update for `N > limit` is a decode
    %% error.
    limit :: non_neg_integer(),
    %% Encoder-only: when the cap is lowered, the encoder MUST
    %% emit a Size Update before any other representation on the
    %% next `encode/2` call.
    pending_update = false :: boolean()
}).

-opaque context() :: #hpack_ctx{}.
-type header() :: {Name :: binary(), Value :: binary()}.

-type decode_error() ::
    invalid_index
    | invalid_table_size
    | huffman_decode_error
    | bad_integer
    | bad_string
    | bad_header_name
    | premature_end_of_block.

%% =============================================================================
%% Constructors
%% =============================================================================

-doc """
New decoder context with the given maximum dynamic-table size in
bytes (default per RFC 9113 §6.5.2 SETTINGS_HEADER_TABLE_SIZE is
4096).
""".
-spec new_decoder(non_neg_integer()) -> context().
new_decoder(MaxSize) ->
    #hpack_ctx{max_size = MaxSize, limit = MaxSize}.

-doc """
New encoder context with the given maximum dynamic-table size in
bytes.
""".
-spec new_encoder(non_neg_integer()) -> context().
new_encoder(MaxSize) ->
    #hpack_ctx{max_size = MaxSize, limit = MaxSize}.

-doc """
Update the maximum dynamic-table size cap. The peer's
SETTINGS_HEADER_TABLE_SIZE is the cap on `max_size`; the actual
runtime size adjusts via Dynamic Table Size Update reps.

For an encoder, this also flags `pending_update` so the next
`encode/2` call will emit a Size Update before any header
representations.
""".
-spec set_max_table_size(non_neg_integer(), context()) -> context().
set_max_table_size(NewLimit, #hpack_ctx{} = Ctx) ->
    Ctx1 =
        case NewLimit < Ctx#hpack_ctx.max_size of
            true ->
                Evicted = evict_to(NewLimit, Ctx),
                Evicted#hpack_ctx{max_size = NewLimit};
            false ->
                Ctx
        end,
    Ctx1#hpack_ctx{limit = NewLimit, pending_update = true}.

%% =============================================================================
%% decode/2 — parse a header block fragment
%% =============================================================================

-doc """
Decode a header block fragment, mutating the dynamic table per
the spec. Returns the decoded header list plus the new context.

`Bin` MUST be a complete header block — incremental decode
across CONTINUATION frames is the caller's responsibility (the
caller concatenates the HEADERS payload + each CONTINUATION
fragment before passing here).
""".
-spec decode(binary(), context()) ->
    {ok, [header()], context()} | {error, decode_error()}.
decode(Bin, Ctx) ->
    %% Third arg is the "updates still permitted" flag (RFC 7541
    %% §4.2): a Dynamic Table Size Update MUST appear at the very
    %% start of a header block. Once any header representation
    %% has been decoded, the flag flips to `false` and any
    %% subsequent update is COMPRESSION_ERROR.
    decode_loop(Bin, Ctx, true).

-spec decode_loop(bitstring(), context(), boolean()) ->
    {ok, [header()], context()} | {error, decode_error()}.
decode_loop(<<>>, Ctx, _) ->
    {ok, [], Ctx};
decode_loop(<<1:1, Rest/bitstring>>, Ctx, _UpdatesAllowed) ->
    %% 1xxxxxxx — Indexed Header Field. 7-bit integer prefix.
    case decode_integer(7, Rest) of
        {ok, 0, _} ->
            {error, invalid_index};
        {ok, Index, Rest1} ->
            case lookup(Index, Ctx) of
                {ok, Header} ->
                    case decode_loop(Rest1, Ctx, false) of
                        {ok, Tail, Ctx2} -> {ok, [Header | Tail], Ctx2};
                        {error, _} = E -> E
                    end;
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end;
decode_loop(<<0:1, 1:1, Rest/bitstring>>, Ctx, _UpdatesAllowed) ->
    %% 01xxxxxx — Literal w/ Incremental Indexing.
    case decode_literal(6, Rest, Ctx) of
        {ok, Header, Rest1} ->
            Ctx2 = insert(Header, Ctx),
            case decode_loop(Rest1, Ctx2, false) of
                {ok, Tail, Ctx3} -> {ok, [Header | Tail], Ctx3};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end;
decode_loop(<<0:1, 0:1, 1:1, _/bitstring>>, _Ctx, false) ->
    %% RFC 7541 §4.2: a Dynamic Table Size Update is only legal
    %% at the start of a header block.
    {error, table_size_update_after_block};
decode_loop(<<0:1, 0:1, 1:1, Rest/bitstring>>, Ctx, true) ->
    %% 001xxxxx — Dynamic Table Size Update.
    case decode_integer(5, Rest) of
        {ok, NewSize, Rest1} when NewSize =< Ctx#hpack_ctx.limit ->
            Ctx1 = evict_to(NewSize, Ctx),
            Ctx2 = Ctx1#hpack_ctx{max_size = NewSize},
            decode_loop(Rest1, Ctx2, true);
        {ok, _, _} ->
            {error, invalid_table_size};
        {error, _} = E ->
            E
    end;
decode_loop(<<0:1, 0:1, 0:1, 1:1, Rest/bitstring>>, Ctx, _UpdatesAllowed) ->
    %% 0001xxxx — Literal Never Indexed. Treated identically to
    %% Literal w/o Indexing on the decode side; the difference
    %% only matters to intermediaries that re-encode (RFC 7541
    %% §6.2.3 sensitive header field).
    case decode_literal(4, Rest, Ctx) of
        {ok, Header, Rest1} ->
            case decode_loop(Rest1, Ctx, false) of
                {ok, Tail, Ctx2} -> {ok, [Header | Tail], Ctx2};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end;
decode_loop(<<0:1, 0:1, 0:1, 0:1, Rest/bitstring>>, Ctx, _UpdatesAllowed) ->
    %% 0000xxxx — Literal w/o Indexing.
    case decode_literal(4, Rest, Ctx) of
        {ok, Header, Rest1} ->
            case decode_loop(Rest1, Ctx, false) of
                {ok, Tail, Ctx2} -> {ok, [Header | Tail], Ctx2};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

-spec decode_literal(pos_integer(), bitstring(), context()) ->
    {ok, header(), bitstring()} | {error, decode_error()}.
decode_literal(PrefixBits, Bits, Ctx) ->
    case decode_integer(PrefixBits, Bits) of
        {ok, 0, AfterIdx} ->
            %% New name.
            case decode_string(AfterIdx) of
                {ok, Name, AfterName} ->
                    case validate_lower(Name) of
                        ok ->
                            case decode_string(AfterName) of
                                {ok, Value, Rest} -> {ok, {Name, Value}, Rest};
                                {error, _} = E -> E
                            end;
                        {error, _} = E ->
                            E
                    end;
                {error, _} = E ->
                    E
            end;
        {ok, NameIdx, AfterIdx} ->
            case lookup(NameIdx, Ctx) of
                {ok, {Name, _}} ->
                    case decode_string(AfterIdx) of
                        {ok, Value, Rest} -> {ok, {Name, Value}, Rest};
                        {error, _} = E -> E
                    end;
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% =============================================================================
%% encode/2 — emit a header block
%% =============================================================================

-doc """
Encode a header list into a header block fragment, mutating the
dynamic table per the spec. Returns the wire bytes plus the new
context.

The encoder uses Indexed Header Field whenever the
{Name, Value} pair is already in the static or dynamic table;
otherwise emits Literal w/ Incremental Indexing with indexed
name (when the name alone is in the table) or new name. Field
values are NOT Huffman-encoded by this implementation — that's
a future optimization (the codec exists; the choice of when to
use it has subtle interop implications and is left for a later
phase).
""".
-spec encode([header()], context()) -> {iodata(), context()}.
encode(Headers, Ctx0) ->
    {SizeUpdate, Ctx1} = take_pending_update(Ctx0),
    {Body, Ctx2} = encode_each(Headers, Ctx1),
    {[SizeUpdate, Body], Ctx2}.

-spec take_pending_update(context()) -> {iodata(), context()}.
take_pending_update(#hpack_ctx{pending_update = false} = Ctx) ->
    {[], Ctx};
take_pending_update(#hpack_ctx{pending_update = true, max_size = N} = Ctx) ->
    {encode_size_update(N), Ctx#hpack_ctx{pending_update = false}}.

-spec encode_each([header()], context()) -> {iodata(), context()}.
encode_each([], Ctx) ->
    {[], Ctx};
encode_each([{Name, Value} = H | Rest], Ctx) ->
    %% `full_match/3` and `name_match/2` return a bare
    %% `pos_integer() | none` — skipping the prior `{ok, _}` tuple
    %% wrapper avoids a per-lookup heap alloc on the dyn-table hit
    %% path (static-table hits are literal constants in the BEAM
    %% pool, so the saving is on dynamic lookups specifically).
    {Bytes, Ctx1} =
        case full_match(Name, Value, Ctx) of
            none ->
                Bs =
                    case name_match(Name, Ctx) of
                        none -> encode_literal_new_name(Name, Value);
                        NameIdx -> encode_literal_indexed_name(NameIdx, Value)
                    end,
                {Bs, insert(H, Ctx)};
            Idx ->
                {encode_indexed(Idx), Ctx}
        end,
    {Tail, Ctx2} = encode_each(Rest, Ctx1),
    {[Bytes | Tail], Ctx2}.

-spec encode_indexed(pos_integer()) -> iodata().
encode_indexed(Idx) ->
    encode_integer(7, 16#80, Idx).

-spec encode_literal_indexed_name(pos_integer(), binary()) -> iodata().
encode_literal_indexed_name(NameIdx, Value) ->
    [encode_integer(6, 16#40, NameIdx), encode_string(Value)].

-spec encode_literal_new_name(binary(), binary()) -> iodata().
encode_literal_new_name(Name, Value) ->
    [<<16#40>>, encode_string(Name), encode_string(Value)].

-spec encode_size_update(non_neg_integer()) -> iodata().
encode_size_update(N) ->
    encode_integer(5, 16#20, N).

%% =============================================================================
%% Integer codec (RFC 7541 §5.1)
%% =============================================================================

%% Decode an N-bit-prefix integer from a bitstring. Returns the
%% integer plus the rest of the bitstring (which is byte-aligned
%% afterwards if Rest is byte-aligned at start — the integer
%% codec only emits/consumes whole bytes after the prefix).
-spec decode_integer(pos_integer(), bitstring()) ->
    {ok, non_neg_integer(), bitstring()} | {error, bad_integer}.
decode_integer(N, Bits) ->
    Max = (1 bsl N) - 1,
    case Bits of
        <<I:N, Rest/bitstring>> when I < Max ->
            {ok, I, Rest};
        <<_:N, Rest/bitstring>> ->
            decode_integer_continuation(Rest, Max, 0)
    end.

-spec decode_integer_continuation(bitstring(), non_neg_integer(), non_neg_integer()) ->
    {ok, non_neg_integer(), bitstring()} | {error, bad_integer}.
decode_integer_continuation(<<0:1, Bits:7, Rest/bitstring>>, I, M) ->
    {ok, I + (Bits bsl M), Rest};
decode_integer_continuation(<<1:1, Bits:7, Rest/bitstring>>, I, M) when M < 56 ->
    decode_integer_continuation(Rest, I + (Bits bsl M), M + 7);
decode_integer_continuation(_, _, _) ->
    {error, bad_integer}.

%% Encode an integer with an N-bit prefix and a leading byte that
%% has the prefix-bit pattern set in its high bits (encoded by
%% caller via `Marker bor I` for the prefix byte).
-spec encode_integer(pos_integer(), 0..255, non_neg_integer()) -> iodata().
encode_integer(N, Marker, I) ->
    Max = (1 bsl N) - 1,
    case I < Max of
        true ->
            <<(Marker bor I):8>>;
        false ->
            [<<(Marker bor Max):8>>, encode_integer_continuation(I - Max)]
    end.

-spec encode_integer_continuation(non_neg_integer()) -> iodata().
encode_integer_continuation(I) when I < 128 ->
    <<I:8>>;
encode_integer_continuation(I) ->
    [<<1:1, (I band 16#7F):7>>, encode_integer_continuation(I bsr 7)].

%% =============================================================================
%% String codec (RFC 7541 §5.2)
%% =============================================================================

-spec decode_string(bitstring()) ->
    {ok, binary(), bitstring()} | {error, decode_error()}.
decode_string(<<H:1, Rest/bitstring>>) ->
    case decode_integer(7, Rest) of
        {ok, Len, AfterLen} ->
            case AfterLen of
                <<Body:Len/binary, Tail/binary>> ->
                    case H of
                        0 ->
                            {ok, Body, Tail};
                        1 ->
                            case roadrunner_http2_hpack_huffman:decode(Body) of
                                {ok, Decoded} -> {ok, Decoded, Tail};
                                {error, _} -> {error, huffman_decode_error}
                            end
                    end;
                _ ->
                    {error, premature_end_of_block}
            end;
        {error, _} = E ->
            E
    end;
decode_string(_) ->
    {error, bad_string}.

%% Plain (non-Huffman) string emission. The encoder picks Huffman
%% only when it shortens the output; for now we emit raw to keep
%% encode deterministic. Future optimization: add a Huffman-when-
%% shorter path.
-spec encode_string(binary()) -> iodata().
encode_string(Bin) ->
    [encode_integer(7, 0, byte_size(Bin)), Bin].

%% =============================================================================
%% Header name validation (RFC 9113 §8.2)
%% =============================================================================

%% Lowercase ASCII letter check on every byte. Pseudo-headers
%% start with `:` (0x3A) which is below 'A' so it doesn't trigger
%% the uppercase test; everything else must already be lowercase.
-spec validate_lower(binary()) -> ok | {error, bad_header_name}.
validate_lower(<<>>) -> ok;
validate_lower(<<C, _Rest/binary>>) when C >= $A, C =< $Z -> {error, bad_header_name};
validate_lower(<<_, Rest/binary>>) -> validate_lower(Rest).

%% =============================================================================
%% Index lookup + table mutation
%% =============================================================================

%% Callers (decode_loop on indexed-header rep, decode_literal on
%% indexed-name lookups) always pass a positive `Idx` — index 0 is
%% caught upstream as a protocol error. The only failure mode is
%% Idx > 61 + |dynamic table|.
-spec lookup(pos_integer(), context()) -> {ok, header()} | {error, invalid_index}.
lookup(Idx, _Ctx) when Idx =< ?STATIC_TABLE_LEN ->
    {ok, lookup_static(Idx)};
lookup(Idx, #hpack_ctx{table = Table}) ->
    DynIdx = Idx - ?STATIC_TABLE_LEN,
    case nth_or_undefined(DynIdx, Table) of
        undefined -> {error, invalid_index};
        H -> {ok, H}
    end.

-spec nth_or_undefined(pos_integer(), [term()]) -> term() | undefined.
nth_or_undefined(_, []) -> undefined;
nth_or_undefined(1, [H | _]) -> H;
nth_or_undefined(N, [_ | T]) -> nth_or_undefined(N - 1, T).

-spec insert(header(), context()) -> context().
insert({Name, Value} = H, #hpack_ctx{max_size = Max} = Ctx) ->
    EntrySize = byte_size(Name) + byte_size(Value) + 32,
    case EntrySize > Max of
        true ->
            %% RFC 7541 §4.4: an entry larger than the table is
            %% silently dropped, evicting the entire current table
            %% in the process.
            Ctx#hpack_ctx{table = [], size = 0};
        false ->
            Evicted = evict_to(Max - EntrySize, Ctx),
            Evicted#hpack_ctx{
                table = [H | Evicted#hpack_ctx.table],
                size = Evicted#hpack_ctx.size + EntrySize
            }
    end.

-spec evict_to(non_neg_integer(), context()) -> context().
evict_to(Target, #hpack_ctx{size = Size} = Ctx) when Size =< Target ->
    Ctx;
evict_to(Target, #hpack_ctx{table = Table} = Ctx) ->
    %% Eldest is at the END of the list. Walk from the newest end
    %% with a remaining-budget; the first entry that doesn't fit
    %% truncates the list there. Body recursion — kept entries
    %% cons on the way back out.
    {Kept, NewSize} = keep_within(Table, Target),
    Ctx#hpack_ctx{table = Kept, size = NewSize}.

%% `evict_to/2` early-exits when the current size already fits the
%% target, so this never sees an empty table — the trim point is
%% always reached strictly before the list runs out (see comment
%% on `evict_to/2` for the proof). A bare function-clause crash
%% on `[]` is the desired "trust the invariant" failure mode.
-spec keep_within([header()], non_neg_integer()) ->
    {[header()], non_neg_integer()}.
keep_within([H | T], Budget) ->
    HSize = entry_size(H),
    case HSize =< Budget of
        true ->
            {Kept, KeptSize} = keep_within(T, Budget - HSize),
            {[H | Kept], KeptSize + HSize};
        false ->
            %% H itself doesn't fit — drop H and every older entry.
            {[], 0}
    end.

-spec entry_size(header()) -> non_neg_integer().
entry_size({Name, Value}) ->
    byte_size(Name) + byte_size(Value) + 32.

%% =============================================================================
%% Lookup helpers — name + name+value match against static then dynamic table
%% =============================================================================

-spec full_match(binary(), binary(), context()) -> pos_integer() | none.
full_match(Name, Value, #hpack_ctx{table = Dyn}) ->
    %% Static lookup is a function-clause dispatch (BEAM JIT turns
    %% the 60-clause `static_full_match/2` into a hash/select jump
    %% table); we still indirect through the wrapper so a hit
    %% returns directly without scanning the dynamic table.
    case static_full_match(Name, Value) of
        none -> dyn_full_match(Name, Value, Dyn, 1);
        Idx -> Idx
    end.

-spec name_match(binary(), context()) -> pos_integer() | none.
name_match(Name, #hpack_ctx{table = Dyn}) ->
    case static_name_match(Name) of
        none -> dyn_name_match(Name, Dyn, 1);
        Idx -> Idx
    end.

dyn_full_match(_, _, [], _) -> none;
dyn_full_match(Name, Value, [{Name, Value} | _], I) -> ?STATIC_TABLE_LEN + I;
dyn_full_match(Name, Value, [_ | T], I) -> dyn_full_match(Name, Value, T, I + 1).

dyn_name_match(_, [], _) -> none;
dyn_name_match(Name, [{Name, _} | _], I) -> ?STATIC_TABLE_LEN + I;
dyn_name_match(Name, [_ | T], I) -> dyn_name_match(Name, T, I + 1).

%% =============================================================================
%% RFC 7541 Appendix A — static table (61 entries)
%% =============================================================================

%% =============================================================================
%% RFC 7541 Appendix A — static table as function-clause dispatch
%% =============================================================================
%%
%% These three functions encode the 61-entry static table directly
%% as Erlang clauses. The BEAM's pattern compiler turns each into a
%% jump/select tree that lookups complete in a few instructions —
%% no persistent_term, no map hash, no tuple element. Cowboy's
%% `cow_hpack:table_find_field/_name` uses the same trick; the
%% earlier persistent_term-backed maps measured at ~3 % of profile
%% on the h2 hello bench, all of which goes away here.
%%
%% Match priority follows RFC 7541 Appendix A: when the same name
%% appears with multiple values (`:method GET` / `:method POST`,
%% `:path /` / `:path /index.html`, all eight `:status N` rows),
%% earlier indices win for indexed-name lookups via
%% `static_name_match/1`.

-spec static_full_match(binary(), binary()) -> pos_integer() | none.
static_full_match(~":authority", ~"") -> 1;
static_full_match(~":method", ~"GET") -> 2;
static_full_match(~":method", ~"POST") -> 3;
static_full_match(~":path", ~"/") -> 4;
static_full_match(~":path", ~"/index.html") -> 5;
static_full_match(~":scheme", ~"http") -> 6;
static_full_match(~":scheme", ~"https") -> 7;
static_full_match(~":status", ~"200") -> 8;
static_full_match(~":status", ~"204") -> 9;
static_full_match(~":status", ~"206") -> 10;
static_full_match(~":status", ~"304") -> 11;
static_full_match(~":status", ~"400") -> 12;
static_full_match(~":status", ~"404") -> 13;
static_full_match(~":status", ~"500") -> 14;
static_full_match(~"accept-charset", ~"") -> 15;
static_full_match(~"accept-encoding", ~"gzip, deflate") -> 16;
static_full_match(~"accept-language", ~"") -> 17;
static_full_match(~"accept-ranges", ~"") -> 18;
static_full_match(~"accept", ~"") -> 19;
static_full_match(~"access-control-allow-origin", ~"") -> 20;
static_full_match(~"age", ~"") -> 21;
static_full_match(~"allow", ~"") -> 22;
static_full_match(~"authorization", ~"") -> 23;
static_full_match(~"cache-control", ~"") -> 24;
static_full_match(~"content-disposition", ~"") -> 25;
static_full_match(~"content-encoding", ~"") -> 26;
static_full_match(~"content-language", ~"") -> 27;
static_full_match(~"content-length", ~"") -> 28;
static_full_match(~"content-location", ~"") -> 29;
static_full_match(~"content-range", ~"") -> 30;
static_full_match(~"content-type", ~"") -> 31;
static_full_match(~"cookie", ~"") -> 32;
static_full_match(~"date", ~"") -> 33;
static_full_match(~"etag", ~"") -> 34;
static_full_match(~"expect", ~"") -> 35;
static_full_match(~"expires", ~"") -> 36;
static_full_match(~"from", ~"") -> 37;
static_full_match(~"host", ~"") -> 38;
static_full_match(~"if-match", ~"") -> 39;
static_full_match(~"if-modified-since", ~"") -> 40;
static_full_match(~"if-none-match", ~"") -> 41;
static_full_match(~"if-range", ~"") -> 42;
static_full_match(~"if-unmodified-since", ~"") -> 43;
static_full_match(~"last-modified", ~"") -> 44;
static_full_match(~"link", ~"") -> 45;
static_full_match(~"location", ~"") -> 46;
static_full_match(~"max-forwards", ~"") -> 47;
static_full_match(~"proxy-authenticate", ~"") -> 48;
static_full_match(~"proxy-authorization", ~"") -> 49;
static_full_match(~"range", ~"") -> 50;
static_full_match(~"referer", ~"") -> 51;
static_full_match(~"refresh", ~"") -> 52;
static_full_match(~"retry-after", ~"") -> 53;
static_full_match(~"server", ~"") -> 54;
static_full_match(~"set-cookie", ~"") -> 55;
static_full_match(~"strict-transport-security", ~"") -> 56;
static_full_match(~"transfer-encoding", ~"") -> 57;
static_full_match(~"user-agent", ~"") -> 58;
static_full_match(~"vary", ~"") -> 59;
static_full_match(~"via", ~"") -> 60;
static_full_match(~"www-authenticate", ~"") -> 61;
static_full_match(_, _) -> none.

-spec static_name_match(binary()) -> pos_integer() | none.
static_name_match(~":authority") -> 1;
static_name_match(~":method") -> 2;
static_name_match(~":path") -> 4;
static_name_match(~":scheme") -> 6;
static_name_match(~":status") -> 8;
static_name_match(~"accept-charset") -> 15;
static_name_match(~"accept-encoding") -> 16;
static_name_match(~"accept-language") -> 17;
static_name_match(~"accept-ranges") -> 18;
static_name_match(~"accept") -> 19;
static_name_match(~"access-control-allow-origin") -> 20;
static_name_match(~"age") -> 21;
static_name_match(~"allow") -> 22;
static_name_match(~"authorization") -> 23;
static_name_match(~"cache-control") -> 24;
static_name_match(~"content-disposition") -> 25;
static_name_match(~"content-encoding") -> 26;
static_name_match(~"content-language") -> 27;
static_name_match(~"content-length") -> 28;
static_name_match(~"content-location") -> 29;
static_name_match(~"content-range") -> 30;
static_name_match(~"content-type") -> 31;
static_name_match(~"cookie") -> 32;
static_name_match(~"date") -> 33;
static_name_match(~"etag") -> 34;
static_name_match(~"expect") -> 35;
static_name_match(~"expires") -> 36;
static_name_match(~"from") -> 37;
static_name_match(~"host") -> 38;
static_name_match(~"if-match") -> 39;
static_name_match(~"if-modified-since") -> 40;
static_name_match(~"if-none-match") -> 41;
static_name_match(~"if-range") -> 42;
static_name_match(~"if-unmodified-since") -> 43;
static_name_match(~"last-modified") -> 44;
static_name_match(~"link") -> 45;
static_name_match(~"location") -> 46;
static_name_match(~"max-forwards") -> 47;
static_name_match(~"proxy-authenticate") -> 48;
static_name_match(~"proxy-authorization") -> 49;
static_name_match(~"range") -> 50;
static_name_match(~"referer") -> 51;
static_name_match(~"refresh") -> 52;
static_name_match(~"retry-after") -> 53;
static_name_match(~"server") -> 54;
static_name_match(~"set-cookie") -> 55;
static_name_match(~"strict-transport-security") -> 56;
static_name_match(~"transfer-encoding") -> 57;
static_name_match(~"user-agent") -> 58;
static_name_match(~"vary") -> 59;
static_name_match(~"via") -> 60;
static_name_match(~"www-authenticate") -> 61;
static_name_match(_) -> none.

-spec lookup_static(pos_integer()) -> header().
lookup_static(1) -> {~":authority", ~""};
lookup_static(2) -> {~":method", ~"GET"};
lookup_static(3) -> {~":method", ~"POST"};
lookup_static(4) -> {~":path", ~"/"};
lookup_static(5) -> {~":path", ~"/index.html"};
lookup_static(6) -> {~":scheme", ~"http"};
lookup_static(7) -> {~":scheme", ~"https"};
lookup_static(8) -> {~":status", ~"200"};
lookup_static(9) -> {~":status", ~"204"};
lookup_static(10) -> {~":status", ~"206"};
lookup_static(11) -> {~":status", ~"304"};
lookup_static(12) -> {~":status", ~"400"};
lookup_static(13) -> {~":status", ~"404"};
lookup_static(14) -> {~":status", ~"500"};
lookup_static(15) -> {~"accept-charset", ~""};
lookup_static(16) -> {~"accept-encoding", ~"gzip, deflate"};
lookup_static(17) -> {~"accept-language", ~""};
lookup_static(18) -> {~"accept-ranges", ~""};
lookup_static(19) -> {~"accept", ~""};
lookup_static(20) -> {~"access-control-allow-origin", ~""};
lookup_static(21) -> {~"age", ~""};
lookup_static(22) -> {~"allow", ~""};
lookup_static(23) -> {~"authorization", ~""};
lookup_static(24) -> {~"cache-control", ~""};
lookup_static(25) -> {~"content-disposition", ~""};
lookup_static(26) -> {~"content-encoding", ~""};
lookup_static(27) -> {~"content-language", ~""};
lookup_static(28) -> {~"content-length", ~""};
lookup_static(29) -> {~"content-location", ~""};
lookup_static(30) -> {~"content-range", ~""};
lookup_static(31) -> {~"content-type", ~""};
lookup_static(32) -> {~"cookie", ~""};
lookup_static(33) -> {~"date", ~""};
lookup_static(34) -> {~"etag", ~""};
lookup_static(35) -> {~"expect", ~""};
lookup_static(36) -> {~"expires", ~""};
lookup_static(37) -> {~"from", ~""};
lookup_static(38) -> {~"host", ~""};
lookup_static(39) -> {~"if-match", ~""};
lookup_static(40) -> {~"if-modified-since", ~""};
lookup_static(41) -> {~"if-none-match", ~""};
lookup_static(42) -> {~"if-range", ~""};
lookup_static(43) -> {~"if-unmodified-since", ~""};
lookup_static(44) -> {~"last-modified", ~""};
lookup_static(45) -> {~"link", ~""};
lookup_static(46) -> {~"location", ~""};
lookup_static(47) -> {~"max-forwards", ~""};
lookup_static(48) -> {~"proxy-authenticate", ~""};
lookup_static(49) -> {~"proxy-authorization", ~""};
lookup_static(50) -> {~"range", ~""};
lookup_static(51) -> {~"referer", ~""};
lookup_static(52) -> {~"refresh", ~""};
lookup_static(53) -> {~"retry-after", ~""};
lookup_static(54) -> {~"server", ~""};
lookup_static(55) -> {~"set-cookie", ~""};
lookup_static(56) -> {~"strict-transport-security", ~""};
lookup_static(57) -> {~"transfer-encoding", ~""};
lookup_static(58) -> {~"user-agent", ~""};
lookup_static(59) -> {~"vary", ~""};
lookup_static(60) -> {~"via", ~""};
lookup_static(61) -> {~"www-authenticate", ~""}.
