-module(roadrunner_grpc_bad_service).
-moduledoc false.

-behaviour(roadrunner_grpc_service).

-export([name/0, rpcs/0]).

name() -> ~"test.Bad".
rpcs() -> #{~"Bad" => #{kind => sideways}}.
