-module(roadrunner_grpc_unexported_service).
-moduledoc false.

-behaviour(roadrunner_grpc_service).

-export([name/0, rpcs/0]).

name() -> ~"test.Unexported".
rpcs() -> #{~"Gone" => #{function => gone, kind => unary, input => in, output => out}}.
