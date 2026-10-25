-module(roadrunner_qpack_table).
-moduledoc false.

%% The QPACK decoder's dynamic table (RFC 9204 §3.2) for one HTTP/3
%% connection: the entries the peer's encoder inserted through its encoder
%% stream, the capacity it set, and how many inserts this side has told it
%% about (the Known Received Count, §2.1.4), which drives the Insert Count
%% Increment instructions sent back on the decoder stream (§4.4.3).
%%
%% Entries sit in a tuple, newest at element 1, as in
%% `roadrunner_http2_hpack`'s table: a lookup is `element/2`, and an insert
%% or an eviction copies a tuple of at most `capacity / 32` entries. The
%% entry with absolute index `A` (§3.2.4, the first insert being 0) is at
%% position `Inserted - A`, so the position of an entry grows as newer
%% entries arrive while its absolute index stays put.
%%
%% Pure: the wire format (encoder instructions, field sections) is
%% `roadrunner_qpack`'s, which calls in here for the table state.

-export([new/1]).
-export([set_capacity/2, insert/3, relative/2, absolute/2]).
-export([insert_count/1, max_capacity/1, capacity/1, max_entries/1]).
-export([acknowledge/2, take_increment/1]).

-export_type([t/0]).

-record(qpack_table, {
    %% Entries, newest at element 1.
    entries = {} :: tuple(),
    %% Entry count, always `tuple_size(entries)`.
    count = 0 :: non_neg_integer(),
    %% Sum of `byte_size(Name) + byte_size(Value) + 32` per entry (§3.2.1).
    size = 0 :: non_neg_integer(),
    %% The capacity the encoder set (§3.2.2), 0 until it sets one.
    capacity = 0 :: non_neg_integer(),
    %% SETTINGS_QPACK_MAX_TABLE_CAPACITY as this side advertised it (§3.2.3).
    max_capacity :: non_neg_integer(),
    %% Total inserts and duplicates so far: the Insert Count (§2.1.2), and
    %% one past the absolute index of the newest entry.
    inserted = 0 :: non_neg_integer(),
    %% The Known Received Count the encoder holds (§2.1.4): what Insert
    %% Count Increments and Section Acknowledgments have told it so far.
    known = 0 :: non_neg_integer()
}).

-opaque t() :: #qpack_table{}.

-doc false.
-spec new(non_neg_integer()) -> t().
new(MaxCapacity) ->
    #qpack_table{max_capacity = MaxCapacity}.

%% Set Dynamic Table Capacity (§4.3.1): over the advertised maximum is an
%% error; a lower capacity evicts the oldest entries until the table fits.
-doc false.
-spec set_capacity(non_neg_integer(), t()) -> {ok, t()} | {error, capacity_exceeded}.
set_capacity(Capacity, #qpack_table{max_capacity = Max}) when Capacity > Max ->
    {error, capacity_exceeded};
set_capacity(Capacity, Table) ->
    {ok, evict_to(Capacity, Table#qpack_table{capacity = Capacity})}.

%% Add an entry (§3.2.2): the oldest entries are evicted until it fits, and
%% one larger than the whole capacity is an error. The name and value are
%% copied so the table does not keep the encoder-stream chunk they were
%% sliced from alive.
-doc false.
-spec insert(binary(), binary(), t()) -> {ok, t()} | {error, entry_too_large}.
insert(Name, Value, #qpack_table{capacity = Capacity} = Table) ->
    EntrySize = byte_size(Name) + byte_size(Value) + 32,
    case EntrySize > Capacity of
        true ->
            {error, entry_too_large};
        false ->
            #qpack_table{entries = Entries, count = Count, size = Size, inserted = Inserted} =
                Evicted = evict_to(Capacity - EntrySize, Table),
            Entry = {binary:copy(Name), binary:copy(Value)},
            {ok, Evicted#qpack_table{
                entries = erlang:insert_element(1, Entries, Entry),
                count = Count + 1,
                size = Size + EntrySize,
                inserted = Inserted + 1
            }}
    end.

%% The entry an encoder instruction names by relative index (§3.2.5): 0 is
%% the newest entry.
-doc false.
-spec relative(non_neg_integer(), t()) -> {ok, {binary(), binary()}} | error.
relative(Index, #qpack_table{entries = Entries, count = Count}) when Index < Count ->
    {ok, element(Index + 1, Entries)};
relative(_Index, _Table) ->
    error.

%% The entry with absolute index `Index` (§3.2.4), or `error` when it was
%% evicted or not inserted yet.
-doc false.
-spec absolute(non_neg_integer(), t()) -> {ok, {binary(), binary()}} | error.
absolute(Index, #qpack_table{entries = Entries, count = Count, inserted = Inserted}) when
    Index < Inserted, Inserted - Index =< Count
->
    {ok, element(Inserted - Index, Entries)};
absolute(_Index, _Table) ->
    error.

-doc false.
-spec insert_count(t()) -> non_neg_integer().
insert_count(#qpack_table{inserted = Inserted}) ->
    Inserted.

-doc false.
-spec max_capacity(t()) -> non_neg_integer().
max_capacity(#qpack_table{max_capacity = Max}) ->
    Max.

-doc false.
-spec capacity(t()) -> non_neg_integer().
capacity(#qpack_table{capacity = Capacity}) ->
    Capacity.

%% MaxEntries (§4.5.1.1): how many entries the advertised maximum capacity
%% can hold at the smallest entry size of 32.
-doc false.
-spec max_entries(t()) -> non_neg_integer().
max_entries(#qpack_table{max_capacity = Max}) ->
    Max div 32.

%% A Section Acknowledgment for a section with this Required Insert Count
%% raises the encoder's Known Received Count to it (§2.1.4), so a later
%% Insert Count Increment must not count those inserts again.
-doc false.
-spec acknowledge(non_neg_integer(), t()) -> t().
acknowledge(RequiredInsertCount, #qpack_table{known = Known} = Table) when
    RequiredInsertCount > Known
->
    Table#qpack_table{known = RequiredInsertCount};
acknowledge(_RequiredInsertCount, Table) ->
    Table.

%% The Insert Count Increment that brings the encoder's Known Received
%% Count up to every insert processed so far (§4.4.3), 0 when it already
%% knows of them all (an increment of 0 is an error, so none is sent).
-doc false.
-spec take_increment(t()) -> {non_neg_integer(), t()}.
take_increment(#qpack_table{inserted = Inserted, known = Known} = Table) ->
    {Inserted - Known, Table#qpack_table{known = Inserted}}.

%% Evict the oldest entries until the table's size is at most `Target`.
-spec evict_to(non_neg_integer(), t()) -> t().
evict_to(Target, #qpack_table{size = Size} = Table) when Size =< Target ->
    Table;
evict_to(Target, #qpack_table{entries = Entries, count = Count, size = Size} = Table) ->
    {Name, Value} = element(Count, Entries),
    evict_to(Target, Table#qpack_table{
        entries = erlang:delete_element(Count, Entries),
        count = Count - 1,
        size = Size - byte_size(Name) - byte_size(Value) - 32
    }).
