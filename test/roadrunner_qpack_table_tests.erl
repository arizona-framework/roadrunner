-module(roadrunner_qpack_table_tests).

-include_lib("eunit/include/eunit.hrl").

-define(T, roadrunner_qpack_table).

%% A table with capacity `Capacity` set (and advertised).
table(Capacity) ->
    {ok, Table} = ?T:set_capacity(Capacity, ?T:new(Capacity)),
    Table.

insert(Name, Value, Table) ->
    {ok, Table1} = ?T:insert(Name, Value, Table),
    Table1.

new_table_is_empty_test() ->
    Table = ?T:new(4096),
    ?assertEqual(0, ?T:insert_count(Table)),
    ?assertEqual(0, ?T:capacity(Table)),
    ?assertEqual(4096, ?T:max_capacity(Table)),
    ?assertEqual(128, ?T:max_entries(Table)),
    ?assertEqual(error, ?T:relative(0, Table)),
    ?assertEqual(error, ?T:absolute(0, Table)).

max_entries_rounds_down_test() ->
    %% RFC 9204 §4.5.1.1: MaxEntries = floor(MaxTableCapacity / 32).
    ?assertEqual(3, ?T:max_entries(?T:new(100))),
    ?assertEqual(0, ?T:max_entries(?T:new(31))).

capacity_over_the_advertised_maximum_test() ->
    %% RFC 9204 §4.3.1.
    ?assertEqual({error, capacity_exceeded}, ?T:set_capacity(4097, ?T:new(4096))),
    ?assertMatch({ok, _}, ?T:set_capacity(4096, ?T:new(4096))).

insert_before_any_capacity_test() ->
    %% The initial capacity is 0 (§3.2.2), so nothing fits until the encoder
    %% sets one.
    ?assertEqual({error, entry_too_large}, ?T:insert(~"a", ~"b", ?T:new(4096))).

insert_and_lookup_test() ->
    Table = insert(~"b", ~"2", insert(~"a", ~"1", table(4096))),
    ?assertEqual(2, ?T:insert_count(Table)),
    %% Relative 0 is the newest (§3.2.5); absolute 0 the first insert (§3.2.4).
    ?assertEqual({ok, {~"b", ~"2"}}, ?T:relative(0, Table)),
    ?assertEqual({ok, {~"a", ~"1"}}, ?T:relative(1, Table)),
    ?assertEqual(error, ?T:relative(2, Table)),
    ?assertEqual({ok, {~"a", ~"1"}}, ?T:absolute(0, Table)),
    ?assertEqual({ok, {~"b", ~"2"}}, ?T:absolute(1, Table)),
    ?assertEqual(error, ?T:absolute(2, Table)).

insert_evicts_oldest_test() ->
    %% Each entry is 1 + 1 + 32 = 34 bytes (§3.2.1): a 68-byte table holds
    %% two, and a third evicts the oldest (§3.2.2).
    Table = insert(~"c", ~"3", insert(~"b", ~"2", insert(~"a", ~"1", table(68)))),
    ?assertEqual(3, ?T:insert_count(Table)),
    ?assertEqual(error, ?T:absolute(0, Table)),
    ?assertEqual({ok, {~"b", ~"2"}}, ?T:absolute(1, Table)),
    ?assertEqual({ok, {~"c", ~"3"}}, ?T:absolute(2, Table)),
    ?assertEqual(error, ?T:relative(2, Table)).

insert_exactly_the_capacity_test() ->
    %% An entry the size of the whole table fits, evicting everything else.
    Table = insert(~"bb", ~"", insert(~"a", ~"", table(34))),
    ?assertEqual(error, ?T:absolute(0, Table)),
    ?assertEqual({ok, {~"bb", ~""}}, ?T:absolute(1, Table)).

insert_larger_than_capacity_test() ->
    ?assertEqual({error, entry_too_large}, ?T:insert(~"abc", ~"", table(34))).

insert_copies_its_strings_test() ->
    %% The entry does not keep the larger binary its strings came from.
    Chunk = binary:copy(~"x", 1000),
    <<Name:1/binary, _/binary>> = Chunk,
    {ok, {Stored, _}} = ?T:relative(0, insert(Name, ~"", table(4096))),
    ?assertEqual(~"x", Stored),
    ?assertEqual(1, binary:referenced_byte_size(Stored)).

lower_capacity_evicts_test() ->
    %% RFC 9204 §4.3.1 / §3.2.2: a smaller capacity evicts from the oldest;
    %% 0 clears the table, which can be restored after.
    Table = insert(~"b", ~"2", insert(~"a", ~"1", table(4096))),
    {ok, One} = ?T:set_capacity(34, Table),
    ?assertEqual(error, ?T:absolute(0, One)),
    ?assertEqual({ok, {~"b", ~"2"}}, ?T:absolute(1, One)),
    {ok, Empty} = ?T:set_capacity(0, One),
    ?assertEqual(error, ?T:relative(0, Empty)),
    {ok, Restored} = ?T:set_capacity(4096, Empty),
    ?assertEqual({ok, {~"c", ~"3"}}, ?T:absolute(2, insert(~"c", ~"3", Restored))).

increments_and_acknowledgments_test() ->
    %% RFC 9204 §2.1.4 / §4.4.3: an increment covers the inserts the
    %% encoder has not heard of, and a Section Acknowledgment already told
    %% it of the ones up to its Required Insert Count.
    Table = insert(~"b", ~"2", insert(~"a", ~"1", table(4096))),
    {2, Told} = ?T:take_increment(Table),
    ?assertMatch({0, _}, ?T:take_increment(Told)),
    Three = insert(~"c", ~"3", insert(~"d", ~"4", Told)),
    Acked = ?T:acknowledge(3, Three),
    ?assertMatch({1, _}, ?T:take_increment(Acked)),
    %% An acknowledgment below what the encoder knows changes nothing.
    ?assertMatch({2, _}, ?T:take_increment(?T:acknowledge(1, Three))).
