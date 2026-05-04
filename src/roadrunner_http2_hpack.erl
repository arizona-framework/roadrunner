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

-on_load(init_static_tables/0).

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
    %% Single `full_match/3` lookup decides BOTH the wire emission
    %% and whether to insert into the dynamic table — calling it
    %% twice (as the prior shape did) was 2× the static-table
    %% scan + persistent_term reads per response header on the
    %% hot path.
    {Bytes, Ctx1} =
        case full_match(Name, Value, Ctx) of
            {ok, Idx} ->
                {encode_indexed(Idx), Ctx};
            none ->
                Bs =
                    case name_match(Name, Ctx) of
                        {ok, Idx} -> encode_literal_indexed_name(Idx, Value);
                        none -> encode_literal_new_name(Name, Value)
                    end,
                {Bs, insert(H, Ctx)}
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
    {ok, element(Idx, static_table_tuple())};
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

-spec full_match(binary(), binary(), context()) -> {ok, pos_integer()} | none.
full_match(Name, Value, #hpack_ctx{table = Dyn}) ->
    case static_full_match(Name, Value) of
        {ok, _} = R -> R;
        none -> dyn_full_match(Name, Value, Dyn, 1)
    end.

-spec name_match(binary(), context()) -> {ok, pos_integer()} | none.
name_match(Name, #hpack_ctx{table = Dyn}) ->
    case static_name_match(Name) of
        {ok, _} = R -> R;
        none -> dyn_name_match(Name, Dyn, 1)
    end.

dyn_full_match(_, _, [], _) -> none;
dyn_full_match(Name, Value, [{Name, Value} | _], I) -> {ok, ?STATIC_TABLE_LEN + I};
dyn_full_match(Name, Value, [_ | T], I) -> dyn_full_match(Name, Value, T, I + 1).

dyn_name_match(_, [], _) -> none;
dyn_name_match(Name, [{Name, _} | _], I) -> {ok, ?STATIC_TABLE_LEN + I};
dyn_name_match(Name, [_ | T], I) -> dyn_name_match(Name, T, I + 1).

%% =============================================================================
%% RFC 7541 Appendix A — static table (61 entries)
%% =============================================================================

-spec static_table_tuple() -> tuple().
static_table_tuple() ->
    persistent_term:get({?MODULE, static_table}).

-spec static_full_match(binary(), binary()) -> {ok, pos_integer()} | none.
static_full_match(Name, Value) ->
    pt_lookup({?MODULE, static_full}, {Name, Value}).

-spec static_name_match(binary()) -> {ok, pos_integer()} | none.
static_name_match(Name) ->
    pt_lookup({?MODULE, static_name}, Name).

%% Look up `Key` in a persistent_term-stored map. The map is
%% populated by `init_static_tables/0` at module-load time, so the
%% persistent_term entry always exists.
pt_lookup(Slot, Key) ->
    case maps:find(Key, persistent_term:get(Slot)) of
        {ok, V} -> {ok, V};
        error -> none
    end.

build_static_full() ->
    maps:from_list([{KV, I} || {I, KV} <- enumerate(static_table_list())]).

build_static_name() ->
    %% Earlier indices win when names repeat (the static table has
    %% several entries with the same name and different values —
    %% RFC 7541 Appendix A — and the encoder should reference the
    %% first match for the indexed-name + literal-value case).
    lists:foldl(
        fun
            ({I, {Name, _}}, Acc) when not is_map_key(Name, Acc) ->
                Acc#{Name => I};
            (_, Acc) ->
                Acc
        end,
        #{},
        enumerate(static_table_list())
    ).

enumerate(L) ->
    enumerate(L, 1).

enumerate([], _) -> [];
enumerate([H | T], I) -> [{I, H} | enumerate(T, I + 1)].

%% RFC 7541 Appendix A — verbatim, in index order.
-spec static_table_list() -> [header()].
static_table_list() ->
    [
        {~":authority", ~""},
        {~":method", ~"GET"},
        {~":method", ~"POST"},
        {~":path", ~"/"},
        {~":path", ~"/index.html"},
        {~":scheme", ~"http"},
        {~":scheme", ~"https"},
        {~":status", ~"200"},
        {~":status", ~"204"},
        {~":status", ~"206"},
        {~":status", ~"304"},
        {~":status", ~"400"},
        {~":status", ~"404"},
        {~":status", ~"500"},
        {~"accept-charset", ~""},
        {~"accept-encoding", ~"gzip, deflate"},
        {~"accept-language", ~""},
        {~"accept-ranges", ~""},
        {~"accept", ~""},
        {~"access-control-allow-origin", ~""},
        {~"age", ~""},
        {~"allow", ~""},
        {~"authorization", ~""},
        {~"cache-control", ~""},
        {~"content-disposition", ~""},
        {~"content-encoding", ~""},
        {~"content-language", ~""},
        {~"content-length", ~""},
        {~"content-location", ~""},
        {~"content-range", ~""},
        {~"content-type", ~""},
        {~"cookie", ~""},
        {~"date", ~""},
        {~"etag", ~""},
        {~"expect", ~""},
        {~"expires", ~""},
        {~"from", ~""},
        {~"host", ~""},
        {~"if-match", ~""},
        {~"if-modified-since", ~""},
        {~"if-none-match", ~""},
        {~"if-range", ~""},
        {~"if-unmodified-since", ~""},
        {~"last-modified", ~""},
        {~"link", ~""},
        {~"location", ~""},
        {~"max-forwards", ~""},
        {~"proxy-authenticate", ~""},
        {~"proxy-authorization", ~""},
        {~"range", ~""},
        {~"referer", ~""},
        {~"refresh", ~""},
        {~"retry-after", ~""},
        {~"server", ~""},
        {~"set-cookie", ~""},
        {~"strict-transport-security", ~""},
        {~"transfer-encoding", ~""},
        {~"user-agent", ~""},
        {~"vary", ~""},
        {~"via", ~""},
        {~"www-authenticate", ~""}
    ].

init_static_tables() ->
    Tuple = list_to_tuple(static_table_list()),
    persistent_term:put({?MODULE, static_table}, Tuple),
    persistent_term:put({?MODULE, static_full}, build_static_full()),
    persistent_term:put({?MODULE, static_name}, build_static_name()),
    ok.
