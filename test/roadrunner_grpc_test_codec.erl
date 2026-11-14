-module(roadrunner_grpc_test_codec).
-moduledoc false.

%% A codec for the `test` subtype: Erlang terms in the external format.

-behaviour(roadrunner_grpc_codec).

-export([subtype/0, encode/2, decode/2]).

subtype() -> ~"test".
encode(_Type, Term) -> term_to_binary(Term).
decode(_Type, Bytes) -> binary_to_term(Bytes, [safe]).
