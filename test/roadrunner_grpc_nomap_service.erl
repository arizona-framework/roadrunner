-module(roadrunner_grpc_nomap_service).
-moduledoc false.

-behaviour(roadrunner_grpc_service).

-export([name/0, rpcs/0]).

name() -> ~"test.NoMap".
rpcs() -> [].
