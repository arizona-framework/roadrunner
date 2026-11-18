-module(roadrunner_test_proto_opts).

%% Build and read the connection options record (`#proto_opts{}`) in tests
%% from a map of field => value: fields left out keep the record's
%% defaults, and an unknown field fails the test.

-include("../include/roadrunner_proto_opts.hrl").

-export([new/1, set/2, get/2, to_map/1]).

-spec new(#{atom() => term()}) -> #proto_opts{}.
new(Fields) ->
    set(Fields, #proto_opts{}).

-spec set(#{atom() => term()}, #proto_opts{}) -> #proto_opts{}.
set(Fields, ProtoOpts) ->
    maps:fold(
        fun(Field, Value, Acc) -> setelement(index(Field), Acc, Value) end, ProtoOpts, Fields
    ).

-spec get(atom(), #proto_opts{}) -> term().
get(Field, ProtoOpts) ->
    element(index(Field), ProtoOpts).

-spec to_map(#proto_opts{}) -> #{atom() => term()}.
to_map(#proto_opts{} = ProtoOpts) ->
    maps:from_list(lists:zip(record_info(fields, proto_opts), tl(tuple_to_list(ProtoOpts)))).

index(Field) ->
    index(Field, record_info(fields, proto_opts), 2).

index(Field, [Field | _], I) -> I;
index(Field, [_ | Rest], I) -> index(Field, Rest, I + 1);
index(Field, [], _I) -> error({unknown_proto_opts_field, Field}).
