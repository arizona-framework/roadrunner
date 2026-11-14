-module(roadrunner_grpc_health).
-moduledoc """
gRPC's health service, `grpc.health.v1.Health` (gRPC's health-checking.md),
for load balancers and probes such as `grpc_health_probe`. Add it with
`roadrunner_grpc:routes(#{services => [...], health => true})`; it speaks
its own protobuf messages, whatever codecs the other services use.

The application sets each service's status with `set_status/2`, by the
service's full name, the empty name standing for the whole server, which
starts `serving`:

```erlang
ok = roadrunner_grpc_health:set_status(~"helloworld.Greeter", serving),
ok = roadrunner_grpc_health:set_status(~"", not_serving).
```

- `Check` answers a service's status, `NOT_FOUND` for one with none
- `List` answers every status set
- `Watch` sends a service's status at once and again at each change, until
  the client cancels; a service with no status is `SERVICE_UNKNOWN` until
  it gets one. A listener that drains sends `NOT_SERVING` and ends it.

The statuses live in a process roadrunner supervises; should it restart,
they start over (the server `serving`, the rest unset), and a `Watch` ends
with `UNAVAILABLE` so its client watches again.
""".

-behaviour(roadrunner_grpc_service).

-export([set_status/2]).
-export([name/0, rpcs/0, check/2, list/2, watch/2]).

%% HealthCheckResponse.ServingStatus values.
-define(SERVING, 1).
-define(NOT_SERVING, 2).
-define(SERVICE_UNKNOWN, 3).

-doc """
Set a service's status, by its full name (`~"package.Service"`), or the
server's with the empty name. `unknown` forgets it: `Check` then answers
`NOT_FOUND`. `Watch` calls on it are told at once.
""".
-spec set_status(binary(), serving | not_serving | unknown) -> ok.
set_status(Service, Status) when
    is_binary(Service), (Status =:= serving orelse Status =:= not_serving orelse Status =:= unknown)
->
    roadrunner_grpc_health_store:set(Service, Status).

-doc false.
-spec name() -> binary().
name() ->
    ~"grpc.health.v1.Health".

-doc false.
-spec rpcs() -> #{binary() => roadrunner_grpc_service:rpc()}.
rpcs() ->
    #{
        ~"Check" => #{function => check, kind => unary, input => request, output => response},
        ~"List" => #{function => list, kind => unary, input => request, output => response},
        ~"Watch" => #{
            function => watch, kind => server_stream, input => request, output => response
        }
    }.

-doc false.
-spec check(binary(), roadrunner_grpc:stream()) ->
    {reply, binary(), roadrunner_grpc:stream()}
    | {error, roadrunner_grpc:status(), binary(), roadrunner_grpc:stream()}.
check(Request, Stream) ->
    maybe
        {ok, Service} ?= roadrunner_grpc_health_proto:service(Request),
        Status = roadrunner_grpc_health_store:status(Service),
        true ?= Status =/= unknown orelse {unknown, Service},
        {reply, roadrunner_grpc_health_proto:response(serving_status(Status)), Stream}
    else
        malformed -> malformed(Stream);
        {unknown, Unknown} -> {error, not_found, <<"unknown service ", Unknown/binary>>, Stream}
    end.

-doc false.
-spec list(binary(), roadrunner_grpc:stream()) -> {reply, iodata(), roadrunner_grpc:stream()}.
list(_Request, Stream) ->
    Statuses = roadrunner_grpc_health_store:statuses(),
    {reply, roadrunner_grpc_health_proto:list([{S, serving_status(St)} || {S, St} <- Statuses]),
        Stream}.

-doc false.
-spec watch(binary(), roadrunner_grpc:stream()) ->
    {ok, roadrunner_grpc:stream()}
    | {error, roadrunner_grpc:status(), binary(), roadrunner_grpc:stream()}.
watch(Request, Stream) ->
    case roadrunner_grpc_health_proto:service(Request) of
        {ok, Service} ->
            %% The status comes back read with the watch taken, so each
            %% change told after is newer than what is sent first. The
            %% store is watched too: the statuses go with it.
            Store = monitor(process, roadrunner_grpc_health_store),
            Status = watch_status(roadrunner_grpc_health_store:watch(Service)),
            Watch = {Service, Store},
            watching(
                Watch,
                Status,
                roadrunner_grpc:send(roadrunner_grpc_health_proto:response(Status), Stream)
            );
        malformed ->
            malformed(Stream)
    end.

%% Send each change until the call is over: the client cancelled it or
%% went away (`roadrunner_grpc:cancelled/2`), the listener drains (the
%% service goes NOT_SERVING for it first, so a balancer moves away), or the
%% statuses went with their store (UNAVAILABLE: the client watches again).
-spec watching({binary(), reference()}, 1..3, roadrunner_grpc:stream()) ->
    {ok, roadrunner_grpc:stream()} | {error, unavailable, binary(), roadrunner_grpc:stream()}.
watching({Service, Store} = Watch, Sent, Stream) ->
    receive
        {roadrunner_grpc_health, Service, Changed} ->
            case watch_status(Changed) of
                Sent ->
                    watching(Watch, Sent, Stream);
                Status ->
                    watching(
                        Watch,
                        Status,
                        roadrunner_grpc:send(roadrunner_grpc_health_proto:response(Status), Stream)
                    )
            end;
        {roadrunner_drain, _Deadline} ->
            {ok, last(?NOT_SERVING, Sent, Stream)};
        {'DOWN', Store, process, _Pid, _Reason} ->
            {error, unavailable, ~"health statuses restarted", Stream};
        Other ->
            case roadrunner_grpc:cancelled(Other, Stream) of
                true -> {ok, Stream};
                false -> watching(Watch, Sent, Stream)
            end
    end.

%% A last status before the call ends, unless it was the one sent.
-spec last(1..3, 1..3, roadrunner_grpc:stream()) -> roadrunner_grpc:stream().
last(Status, Status, Stream) ->
    Stream;
last(_Status, ?SERVICE_UNKNOWN, Stream) ->
    %% A service with no status gets none at the end either, as gRPC's own
    %% servers leave it.
    Stream;
last(Status, _Sent, Stream) ->
    roadrunner_grpc:send(roadrunner_grpc_health_proto:response(Status), Stream).

-spec malformed(roadrunner_grpc:stream()) ->
    {error, internal, binary(), roadrunner_grpc:stream()}.
malformed(Stream) ->
    {error, internal, ~"request message does not decode", Stream}.

-spec watch_status(serving | not_serving | unknown) -> 1..3.
watch_status(unknown) -> ?SERVICE_UNKNOWN;
watch_status(Status) -> serving_status(Status).

-spec serving_status(serving | not_serving) -> 1..2.
serving_status(serving) -> ?SERVING;
serving_status(not_serving) -> ?NOT_SERVING.
