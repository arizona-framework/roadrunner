-module(roadrunner_http2_hpack_huffman).
-moduledoc """
HPACK Huffman codec (RFC 7541 §5.2 + Appendix B).

The static Huffman code table maps each of the 256 byte values plus
an end-of-string symbol (id 256) to a variable-length bit string of
5 to 30 bits. Encoded strings are zero-padded with `1`-bits at the
end of the final byte to reach a byte boundary; the EOS symbol
(`11111111 11111111 11111111 111111`) is **never** emitted as part
of a string and MUST trigger a decode error if it appears.

## Encoding

`encode(Bin)` walks the input byte-by-byte, looking up each byte's
code in the encode table (a 256-element tuple of `{NumBits, Code}`)
and packing the bits into the output via a small accumulator.
EOS-padding is applied at the end.

## Decoding

`decode(Bin)` uses a 4-bit-nibble state machine. Each state has
16 transitions; a transition either emits 0/1/2 bytes and lands
in a new state, or rejects with `eos_in_string` (EOS symbol seen
mid-string) or `invalid_huffman` (no path through the tree).

The state table is a tuple keyed by state id (state 0 is the root
of the prefix tree); each entry is `{TransitionsTuple, AcceptFlag}`.
A state is accepting if pad bits (all `1`s) from this point lie on
the EOS path of the tree — i.e. terminating the input here is
valid.

Both tables are constructed at module-load time and stashed in
`persistent_term` so the hot path does no allocation.
""".

-on_load(init_tables/0).

-export([encode/1, decode/1]).

-export_type([decode_error/0]).

-type decode_error() ::
    invalid_padding
    | eos_in_string.

-define(ENCODE_KEY, {?MODULE, encode_table}).
-define(DECODE_KEY, {?MODULE, decode_table}).

%% =============================================================================
%% encode/1
%% =============================================================================

-doc """
Huffman-encode a binary, padding the final byte with `1`-bits to
reach a byte boundary per RFC 7541 §5.2. The padding is at most 7
bits; an empty input produces an empty output.
""".
-spec encode(binary()) -> binary().
encode(Bin) ->
    Table = persistent_term:get(?ENCODE_KEY),
    {Out, Acc, BitLen} = encode_loop(Bin, Table, <<>>, 0, 0),
    PadBits = (8 - (BitLen rem 8)) rem 8,
    case PadBits of
        0 ->
            Out;
        _ ->
            Byte = (Acc bsl PadBits) bor ((1 bsl PadBits) - 1),
            <<Out/binary, Byte:8>>
    end.

-spec encode_loop(binary(), tuple(), binary(), non_neg_integer(), non_neg_integer()) ->
    {binary(), non_neg_integer(), non_neg_integer()}.
encode_loop(<<>>, _Table, Out, Acc, BitLen) ->
    {Out, Acc, BitLen};
encode_loop(<<B, Rest/binary>>, Table, Out, Acc, BitLen) ->
    {Width, Code} = element(B + 1, Table),
    Acc1 = (Acc bsl Width) bor Code,
    Len1 = BitLen + Width,
    {Out2, Acc2, Len2} = flush_full_bytes(Out, Acc1, Len1),
    encode_loop(Rest, Table, Out2, Acc2, Len2).

%% Pull complete bytes out of the accumulator, appending to the
%% binary output. Erlang's runtime optimizes the
%% `<<X/binary, B:8>>` pattern to in-place append when X is the
%% latest mutator on the binary heap, so this stays linear in the
%% output size.
-spec flush_full_bytes(binary(), non_neg_integer(), non_neg_integer()) ->
    {binary(), non_neg_integer(), non_neg_integer()}.
flush_full_bytes(Out, Acc, Len) when Len >= 8 ->
    Shift = Len - 8,
    Byte = (Acc bsr Shift) band 16#FF,
    Mask = (1 bsl Shift) - 1,
    flush_full_bytes(<<Out/binary, Byte:8>>, Acc band Mask, Shift);
flush_full_bytes(Out, Acc, Len) ->
    {Out, Acc, Len}.

%% =============================================================================
%% decode/1
%% =============================================================================

-doc """
Huffman-decode a binary back to its plain-text form, validating per
RFC 7541 §5.2:

- the EOS symbol (id 256) MUST NOT appear in the encoded stream
  (`eos_in_string`),
- any padding longer than 7 bits or that strays off the EOS path
  is `invalid_padding`,
- any path through the tree that doesn't terminate at a leaf is
  `invalid_huffman`.
""".
-spec decode(binary()) -> {ok, binary()} | {error, decode_error()}.
decode(Bin) ->
    Table = persistent_term:get(?DECODE_KEY),
    decode_loop(Bin, Table, 0, <<>>).

-spec decode_loop(binary(), tuple(), non_neg_integer(), binary()) ->
    {ok, binary()} | {error, decode_error()}.
decode_loop(<<>>, Table, State, Out) ->
    %% End of input. RFC 7541 §5.2:
    %%   - state must be accepting (pad bits along the EOS path);
    %%   - the depth-since-last-emit (= state depth) must be < 8.
    {_Trans, Accept, Depth} = element(State + 1, Table),
    case Accept andalso Depth < 8 of
        true -> {ok, Out};
        false -> {error, invalid_padding}
    end;
decode_loop(<<Byte, Rest/binary>>, Table, State, Out) ->
    Hi = Byte bsr 4,
    Lo = Byte band 16#0F,
    maybe
        {ok, S1, Out1} ?= nibble_step(Table, State, Hi, Out),
        {ok, S2, Out2} ?= nibble_step(Table, S1, Lo, Out1),
        decode_loop(Rest, Table, S2, Out2)
    end.

%% RFC 7541's Huffman codes are Kraft-equal (sum of 2^-len = 1) so
%% the constructed tree is complete — no path through 4 nibble bits
%% lands on an `undefined` slot. We trust that invariant and don't
%% emit an `invalid` branch here. Similarly, no two codes are short
%% enough to fit in a single 4-bit nibble (the shortest code is
%% 5 bits), so a transition emits at most one byte.
-spec nibble_step(tuple(), non_neg_integer(), 0..15, binary()) ->
    {ok, non_neg_integer(), binary()} | {error, decode_error()}.
nibble_step(Table, State, Nibble, Out) ->
    {Trans, _Accept, _Depth} = element(State + 1, Table),
    case element(Nibble + 1, Trans) of
        eos -> {error, eos_in_string};
        {Next, none} -> {ok, Next, Out};
        {Next, {emit, B1}} -> {ok, Next, <<Out/binary, B1:8>>}
    end.

%% =============================================================================
%% Table construction (-on_load)
%% =============================================================================

-spec init_tables() -> ok.
init_tables() ->
    Codes = code_table(),
    Encode = build_encode_table(Codes),
    Decode = build_decode_table(Codes),
    persistent_term:put(?ENCODE_KEY, Encode),
    persistent_term:put(?DECODE_KEY, Decode),
    ok.

%% Encode table: 256-tuple keyed by byte+1, value `{Width, Code}`.
-spec build_encode_table([{non_neg_integer(), pos_integer(), non_neg_integer()}]) ->
    tuple().
build_encode_table(Codes) ->
    Map = #{S => {W, C} || {S, W, C} <- Codes, S =< 255},
    list_to_tuple([maps:get(I, Map) || I <- lists:seq(0, 255)]).

%% Decode table: each state is a branch node in the prefix tree.
%% State id 0 is the root.
%%
%% 1. Build the prefix tree from the codes.
%% 2. BFS-walk the tree, assigning each branch node a state id.
%% 3. For each (state, nibble in 0..15), pre-compute the transition
%%    by walking 4 bits down the tree from that node, emitting
%%    symbols and resetting to root on each leaf.
-spec build_decode_table([{non_neg_integer(), pos_integer(), non_neg_integer()}]) ->
    tuple().
build_decode_table(Codes) ->
    Tree = build_tree(Codes),
    {Branches, IdMap} = assign_state_ids(Tree),
    list_to_tuple([
        build_state_entry(Node, Tree, IdMap)
     || Node <- Branches
    ]).

%% --- prefix tree ---

%% Tree nodes: `{branch, Left, Right}`, `{leaf, Symbol}`, or
%% `undefined` (no child placed yet — only seen during construction).
-spec build_tree([{non_neg_integer(), pos_integer(), non_neg_integer()}]) -> term().
build_tree(Codes) ->
    lists:foldl(fun insert_code/2, empty_branch(), Codes).

empty_branch() -> {branch, undefined, undefined}.

insert_code({Sym, Width, Code}, Tree) ->
    Bits = code_to_bits(Code, Width),
    insert_bits(Tree, Bits, Sym).

%% MSB-first list of `Width` bits.
code_to_bits(Code, Width) ->
    [(Code bsr (Width - I - 1)) band 1 || I <- lists:seq(0, Width - 1)].

%% Place a leaf at the path `Bits` starting from `Tree`.
%% `default_branch/1` materializes any `undefined` child slot we
%% pass through, so `insert_bits/3` only ever sees `{branch, _, _}`
%% or the base-case `[]`.
insert_bits(_Tree, [], Sym) ->
    {leaf, Sym};
insert_bits({branch, L, R}, [0 | Rest], Sym) ->
    L1 = insert_bits(default_branch(L), Rest, Sym),
    {branch, L1, R};
insert_bits({branch, L, R}, [1 | Rest], Sym) ->
    R1 = insert_bits(default_branch(R), Rest, Sym),
    {branch, L, R1}.

default_branch(undefined) -> empty_branch();
default_branch(N) -> N.

%% --- state assignment ---

%% BFS walk; each branch node gets the next free state id. We use a
%% map from the term-as-key to its id, which works because every
%% branch in a canonical Huffman tree is unique. Body recursion
%% builds the BFS-ordered branch list with cons-on-the-way-out so
%% no `lists:reverse/1` is needed.
-spec assign_state_ids(term()) -> {[term()], map()}.
assign_state_ids(Root) ->
    bfs([Root], #{}, 0).

%% Children we enqueue are only branch nodes (filtered via
%% `is_branch_node/1`), and trees built from canonical Huffman
%% codes contain no duplicate sub-branches, so every dequeued node
%% is a fresh branch worth a new state id.
bfs([], IdMap, _Next) ->
    {[], IdMap};
bfs([{branch, L, R} = Node | Queue], IdMap, Next) ->
    IdMap1 = IdMap#{Node => Next},
    Children = [N || N <- [L, R], is_branch_node(N)],
    {Tail, FinalMap} = bfs(Queue ++ Children, IdMap1, Next + 1),
    {[Node | Tail], FinalMap}.

is_branch_node({branch, _, _}) -> true;
is_branch_node(_) -> false.

%% --- per-state transitions ---

-spec build_state_entry(term(), term(), map()) -> {tuple(), boolean(), non_neg_integer()}.
build_state_entry(BranchNode, Tree, IdMap) ->
    Trans = list_to_tuple([
        nibble_transition(N, BranchNode, Tree, IdMap)
     || N <- lists:seq(0, 15)
    ]),
    {Trans, accept_flag(BranchNode), node_depth(BranchNode, Tree)}.

%% Depth of a branch node from the tree root, in bits. Used by
%% `decode_loop/4` to enforce RFC 7541 §5.2: padding MUST be < 8
%% bits, which means at end-of-input the current state's depth
%% (= bits consumed since last symbol emit) must be < 8.
%% Branch nodes assigned via BFS are guaranteed reachable from the
%% root, so the walk always terminates at the target.
-spec node_depth(term(), term()) -> non_neg_integer().
node_depth(Node, Tree) ->
    {ok, D} = node_depth_walk(Tree, Node, 0),
    D.

node_depth_walk(Node, Node, D) ->
    {ok, D};
node_depth_walk({branch, L, R}, Target, D) ->
    case node_depth_walk(L, Target, D + 1) of
        {ok, _} = R0 -> R0;
        not_found -> node_depth_walk(R, Target, D + 1)
    end;
node_depth_walk(_Leaf, _Target, _D) ->
    not_found.

%% Walk 4 bits (high-order first) from `StartNode` through `Tree`,
%% emitting symbols on each leaf and resetting to root when so.
%%
%% RFC 7541 codes are 5–30 bits each, so a 4-bit nibble walk can
%% emit at most ONE byte (the shortest code already exceeds the
%% nibble width). The canonical tree is also complete (Kraft sum
%% = 1), so no nibble-walk lands on `undefined` — those defensive
%% branches are removed and any deviation crashes loudly.
%%
%% Returns:
%%   `{NextStateId, none | {emit, B}}` — landing in a branch node
%%       (the new state) after consuming all 4 bits, having
%%       emitted 0 or 1 bytes,
%%   `eos` — the path led into the EOS leaf (symbol 256).
-spec nibble_transition(0..15, term(), term(), map()) ->
    {non_neg_integer(), none | {emit, byte()}} | eos.
nibble_transition(Nibble, StartNode, Tree, IdMap) ->
    Bits = [(Nibble bsr (3 - I)) band 1 || I <- lists:seq(0, 3)],
    walk_bits(Bits, StartNode, Tree, IdMap, none).

%% Emitted: `none` (no symbol so far) or `{emit, Byte}` after a
%% leaf was hit on this nibble walk.
-spec walk_bits([0 | 1], term(), term(), map(), none | {emit, byte()}) ->
    {non_neg_integer(), none | {emit, byte()}} | eos.
walk_bits([], EndNode, _Tree, IdMap, Emitted) ->
    {maps:get(EndNode, IdMap), Emitted};
walk_bits([Bit | Rest], {branch, L, R}, Tree, IdMap, Emitted) ->
    Next =
        case Bit of
            0 -> L;
            1 -> R
        end,
    case Next of
        {leaf, 256} ->
            eos;
        {leaf, Sym} ->
            walk_bits(Rest, Tree, Tree, IdMap, {emit, Sym});
        {branch, _, _} ->
            walk_bits(Rest, Next, Tree, IdMap, Emitted)
    end.

%% --- accept flag ---

%% A branch node is "accepting" if the bits not yet consumed at this
%% point form a prefix of EOS — i.e. the path from this node to the
%% EOS leaf consists of all `1`-bits. Equivalently: keep walking the
%% right child; if we eventually hit `{leaf, 256}`, we're accepting.
%% The `_Tree` argument isn't needed; the check is local to the
%% subtree at `Node`.
-spec accept_flag(term()) -> boolean().
accept_flag({branch, _, R}) ->
    accept_flag(R);
accept_flag({leaf, 256}) ->
    true;
accept_flag(_) ->
    false.

%% =============================================================================
%% RFC 7541 Appendix B — the canonical 257-entry static Huffman table.
%% Each tuple is {Symbol, BitWidth, Code}. Symbol 256 is EOS.
%% =============================================================================

-spec code_table() -> [{non_neg_integer(), pos_integer(), non_neg_integer()}].
code_table() ->
    [
        {0, 13, 16#1FF8},
        {1, 23, 16#7FFFD8},
        {2, 28, 16#FFFFFE2},
        {3, 28, 16#FFFFFE3},
        {4, 28, 16#FFFFFE4},
        {5, 28, 16#FFFFFE5},
        {6, 28, 16#FFFFFE6},
        {7, 28, 16#FFFFFE7},
        {8, 28, 16#FFFFFE8},
        {9, 24, 16#FFFFEA},
        {10, 30, 16#3FFFFFFC},
        {11, 28, 16#FFFFFE9},
        {12, 28, 16#FFFFFEA},
        {13, 30, 16#3FFFFFFD},
        {14, 28, 16#FFFFFEB},
        {15, 28, 16#FFFFFEC},
        {16, 28, 16#FFFFFED},
        {17, 28, 16#FFFFFEE},
        {18, 28, 16#FFFFFEF},
        {19, 28, 16#FFFFFF0},
        {20, 28, 16#FFFFFF1},
        {21, 28, 16#FFFFFF2},
        {22, 30, 16#3FFFFFFE},
        {23, 28, 16#FFFFFF3},
        {24, 28, 16#FFFFFF4},
        {25, 28, 16#FFFFFF5},
        {26, 28, 16#FFFFFF6},
        {27, 28, 16#FFFFFF7},
        {28, 28, 16#FFFFFF8},
        {29, 28, 16#FFFFFF9},
        {30, 28, 16#FFFFFFA},
        {31, 28, 16#FFFFFFB},
        {32, 6, 16#14},
        {33, 10, 16#3F8},
        {34, 10, 16#3F9},
        {35, 12, 16#FFA},
        {36, 13, 16#1FF9},
        {37, 6, 16#15},
        {38, 8, 16#F8},
        {39, 11, 16#7FA},
        {40, 10, 16#3FA},
        {41, 10, 16#3FB},
        {42, 8, 16#F9},
        {43, 11, 16#7FB},
        {44, 8, 16#FA},
        {45, 6, 16#16},
        {46, 6, 16#17},
        {47, 6, 16#18},
        {48, 5, 16#0},
        {49, 5, 16#1},
        {50, 5, 16#2},
        {51, 6, 16#19},
        {52, 6, 16#1A},
        {53, 6, 16#1B},
        {54, 6, 16#1C},
        {55, 6, 16#1D},
        {56, 6, 16#1E},
        {57, 6, 16#1F},
        {58, 7, 16#5C},
        {59, 8, 16#FB},
        {60, 15, 16#7FFC},
        {61, 6, 16#20},
        {62, 12, 16#FFB},
        {63, 10, 16#3FC},
        {64, 13, 16#1FFA},
        {65, 6, 16#21},
        {66, 7, 16#5D},
        {67, 7, 16#5E},
        {68, 7, 16#5F},
        {69, 7, 16#60},
        {70, 7, 16#61},
        {71, 7, 16#62},
        {72, 7, 16#63},
        {73, 7, 16#64},
        {74, 7, 16#65},
        {75, 7, 16#66},
        {76, 7, 16#67},
        {77, 7, 16#68},
        {78, 7, 16#69},
        {79, 7, 16#6A},
        {80, 7, 16#6B},
        {81, 7, 16#6C},
        {82, 7, 16#6D},
        {83, 7, 16#6E},
        {84, 7, 16#6F},
        {85, 7, 16#70},
        {86, 7, 16#71},
        {87, 7, 16#72},
        {88, 8, 16#FC},
        {89, 7, 16#73},
        {90, 8, 16#FD},
        {91, 13, 16#1FFB},
        {92, 19, 16#7FFF0},
        {93, 13, 16#1FFC},
        {94, 14, 16#3FFC},
        {95, 6, 16#22},
        {96, 15, 16#7FFD},
        {97, 5, 16#3},
        {98, 6, 16#23},
        {99, 5, 16#4},
        {100, 6, 16#24},
        {101, 5, 16#5},
        {102, 6, 16#25},
        {103, 6, 16#26},
        {104, 6, 16#27},
        {105, 5, 16#6},
        {106, 7, 16#74},
        {107, 7, 16#75},
        {108, 6, 16#28},
        {109, 6, 16#29},
        {110, 6, 16#2A},
        {111, 5, 16#7},
        {112, 6, 16#2B},
        {113, 7, 16#76},
        {114, 6, 16#2C},
        {115, 5, 16#8},
        {116, 5, 16#9},
        {117, 6, 16#2D},
        {118, 7, 16#77},
        {119, 7, 16#78},
        {120, 7, 16#79},
        {121, 7, 16#7A},
        {122, 7, 16#7B},
        {123, 15, 16#7FFE},
        {124, 11, 16#7FC},
        {125, 14, 16#3FFD},
        {126, 13, 16#1FFD},
        {127, 28, 16#FFFFFFC},
        {128, 20, 16#FFFE6},
        {129, 22, 16#3FFFD2},
        {130, 20, 16#FFFE7},
        {131, 20, 16#FFFE8},
        {132, 22, 16#3FFFD3},
        {133, 22, 16#3FFFD4},
        {134, 22, 16#3FFFD5},
        {135, 23, 16#7FFFD9},
        {136, 22, 16#3FFFD6},
        {137, 23, 16#7FFFDA},
        {138, 23, 16#7FFFDB},
        {139, 23, 16#7FFFDC},
        {140, 23, 16#7FFFDD},
        {141, 23, 16#7FFFDE},
        {142, 24, 16#FFFFEB},
        {143, 23, 16#7FFFDF},
        {144, 24, 16#FFFFEC},
        {145, 24, 16#FFFFED},
        {146, 22, 16#3FFFD7},
        {147, 23, 16#7FFFE0},
        {148, 24, 16#FFFFEE},
        {149, 23, 16#7FFFE1},
        {150, 23, 16#7FFFE2},
        {151, 23, 16#7FFFE3},
        {152, 23, 16#7FFFE4},
        {153, 21, 16#1FFFDC},
        {154, 22, 16#3FFFD8},
        {155, 23, 16#7FFFE5},
        {156, 22, 16#3FFFD9},
        {157, 23, 16#7FFFE6},
        {158, 23, 16#7FFFE7},
        {159, 24, 16#FFFFEF},
        {160, 22, 16#3FFFDA},
        {161, 21, 16#1FFFDD},
        {162, 20, 16#FFFE9},
        {163, 22, 16#3FFFDB},
        {164, 22, 16#3FFFDC},
        {165, 23, 16#7FFFE8},
        {166, 23, 16#7FFFE9},
        {167, 21, 16#1FFFDE},
        {168, 23, 16#7FFFEA},
        {169, 22, 16#3FFFDD},
        {170, 22, 16#3FFFDE},
        {171, 24, 16#FFFFF0},
        {172, 21, 16#1FFFDF},
        {173, 22, 16#3FFFDF},
        {174, 23, 16#7FFFEB},
        {175, 23, 16#7FFFEC},
        {176, 21, 16#1FFFE0},
        {177, 21, 16#1FFFE1},
        {178, 22, 16#3FFFE0},
        {179, 21, 16#1FFFE2},
        {180, 23, 16#7FFFED},
        {181, 22, 16#3FFFE1},
        {182, 23, 16#7FFFEE},
        {183, 23, 16#7FFFEF},
        {184, 20, 16#FFFEA},
        {185, 22, 16#3FFFE2},
        {186, 22, 16#3FFFE3},
        {187, 22, 16#3FFFE4},
        {188, 23, 16#7FFFF0},
        {189, 22, 16#3FFFE5},
        {190, 22, 16#3FFFE6},
        {191, 23, 16#7FFFF1},
        {192, 26, 16#3FFFFE0},
        {193, 26, 16#3FFFFE1},
        {194, 20, 16#FFFEB},
        {195, 19, 16#7FFF1},
        {196, 22, 16#3FFFE7},
        {197, 23, 16#7FFFF2},
        {198, 22, 16#3FFFE8},
        {199, 25, 16#1FFFFEC},
        {200, 26, 16#3FFFFE2},
        {201, 26, 16#3FFFFE3},
        {202, 26, 16#3FFFFE4},
        {203, 27, 16#7FFFFDE},
        {204, 27, 16#7FFFFDF},
        {205, 26, 16#3FFFFE5},
        {206, 24, 16#FFFFF1},
        {207, 25, 16#1FFFFED},
        {208, 19, 16#7FFF2},
        {209, 21, 16#1FFFE3},
        {210, 26, 16#3FFFFE6},
        {211, 27, 16#7FFFFE0},
        {212, 27, 16#7FFFFE1},
        {213, 26, 16#3FFFFE7},
        {214, 27, 16#7FFFFE2},
        {215, 24, 16#FFFFF2},
        {216, 21, 16#1FFFE4},
        {217, 21, 16#1FFFE5},
        {218, 26, 16#3FFFFE8},
        {219, 26, 16#3FFFFE9},
        {220, 28, 16#FFFFFFD},
        {221, 27, 16#7FFFFE3},
        {222, 27, 16#7FFFFE4},
        {223, 27, 16#7FFFFE5},
        {224, 20, 16#FFFEC},
        {225, 24, 16#FFFFF3},
        {226, 20, 16#FFFED},
        {227, 21, 16#1FFFE6},
        {228, 22, 16#3FFFE9},
        {229, 21, 16#1FFFE7},
        {230, 21, 16#1FFFE8},
        {231, 23, 16#7FFFF3},
        {232, 22, 16#3FFFEA},
        {233, 22, 16#3FFFEB},
        {234, 25, 16#1FFFFEE},
        {235, 25, 16#1FFFFEF},
        {236, 24, 16#FFFFF4},
        {237, 24, 16#FFFFF5},
        {238, 26, 16#3FFFFEA},
        {239, 23, 16#7FFFF4},
        {240, 26, 16#3FFFFEB},
        {241, 27, 16#7FFFFE6},
        {242, 26, 16#3FFFFEC},
        {243, 26, 16#3FFFFED},
        {244, 27, 16#7FFFFE7},
        {245, 27, 16#7FFFFE8},
        {246, 27, 16#7FFFFE9},
        {247, 27, 16#7FFFFEA},
        {248, 27, 16#7FFFFEB},
        {249, 28, 16#FFFFFFE},
        {250, 27, 16#7FFFFEC},
        {251, 27, 16#7FFFFED},
        {252, 27, 16#7FFFFEE},
        {253, 27, 16#7FFFFEF},
        {254, 27, 16#7FFFFF0},
        {255, 26, 16#3FFFFEE},
        {256, 30, 16#3FFFFFFF}
    ].
