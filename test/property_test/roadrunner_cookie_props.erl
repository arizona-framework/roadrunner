-module(roadrunner_cookie_props).
-moduledoc """
Property-based tests for `roadrunner_cookie:parse/1`.

The parser is documented as lenient (cowboy parity) — it must never
crash on adversarial input, no matter how malformed. These properties
exercise that contract: any binary input produces a list of
well-formed `{Name, Value}` pairs.
""".

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct_property_test.hrl").

%% No matter what bytes the client sends, the parser returns a list.
prop_parse_never_crashes() ->
    ?FORALL(
        B,
        binary(),
        is_list(roadrunner_cookie:parse(B))
    ).

%% Every entry is `{NonEmptyBinary, Binary}` with no `;` leaking into
%% either name or value. Names are also free of leading/trailing OWS
%% (we trim before validating).
prop_parse_returns_well_formed_pairs() ->
    ?FORALL(
        B,
        binary(),
        lists:all(fun is_well_formed_pair/1, roadrunner_cookie:parse(B))
    ).

is_well_formed_pair({Name, Value}) when
    is_binary(Name), is_binary(Value), Name =/= <<>>
->
    binary:match(Name, ~";") =:= nomatch andalso
        binary:match(Value, ~";") =:= nomatch andalso
        not has_leading_ows(Name) andalso
        not has_trailing_ows(Name);
is_well_formed_pair(_) ->
    false.

has_leading_ows(<<C, _/binary>>) when C =:= $\s; C =:= $\t -> true;
has_leading_ows(_) -> false.

has_trailing_ows(<<>>) ->
    false;
has_trailing_ows(B) ->
    case binary:at(B, byte_size(B) - 1) of
        C when C =:= $\s; C =:= $\t -> true;
        _ -> false
    end.
