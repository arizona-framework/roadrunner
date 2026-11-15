-module(roadrunner_grpc).
-moduledoc """
gRPC services on roadrunner's HTTP/2 and HTTP/3 listeners.

`routes/1` turns `roadrunner_grpc_service` modules into routes, one per
service, under `/package.Service/:method`:

```erlang
roadrunner_listener:start_link(my_listener, #{
    port => 50051,
    protocols => [http2],
    body_buffering => manual,
    routes => roadrunner_grpc:routes(#{services => [greeter]})
}).
```

A call runs its method on the request's own process with a `t:stream/0`,
which `recv/1` reads the requests from and `send/2` writes the responses
to. The core moves bytes: the codec, picked by the request's
`content-type` from the route's `codecs`, turns them into messages
(`roadrunner_grpc_codec`). With no `codecs`, `roadrunner_grpc_codec_raw`
hands a method the bytes.

## Options

`routes/1` takes `services`, the service modules (or
`t:roadrunner_grpc_service:descriptor/0` maps, for a service built at
runtime), and passes the rest to every service's route; `init_route/1`
checks them when the routes compile, and a bad one stops the listener
from starting:

- `codecs`: the `roadrunner_grpc_codec` modules the services speak, by
  default `[roadrunner_grpc_codec_raw]`
- `max_message_size`: the largest request message, in bytes, by default
  4 MiB, compressed and decompressed alike; a larger one ends the call
  with `RESOURCE_EXHAUSTED`
- `send_compression`: how the response messages are compressed, `gzip`,
  `deflate` or by default `identity`, none (see Compression)
- `health`: `true` adds gRPC's health service (`roadrunner_grpc_health`)
  to the routes; by default `false`
- `reflection`: `true` adds gRPC's server reflection
  (`roadrunner_grpc_reflection`) to the routes; by default `false`
- `max_content_length`: the most a call's requests may add up to, in bytes,
  for `routes/1` to set on each route in place of the listener's (10 MiB
  by default); past it the call ends with `RESOURCE_EXHAUSTED` with
  `manual` buffering, and with `auto` the request is answered `413`, as
  the body is read before the call starts. A client or
  bidi stream that lives long can carry more than that over its life, so
  set it to what such a call may total

The health and reflection routes keep the defaults: the shared options
apply to the services' routes.

## Body buffering

With `body_buffering => manual` a call reads its requests as they come, so
client streams and bidi streams flow both ways; a dedicated gRPC listener
is the place for it. With `auto`, the default, the whole request body is
read before the method runs, which suits unary and server-streaming calls
and a client stream that fits `max_content_length`.

## What the client gets

A call answers `:status 200` and ends with the gRPC status in its
trailers: `OK` when the method returns normally, the status of an
`{error, Status, Message, Stream}`, `INTERNAL` when the method crashes.
A call that fails before any response is answered Trailers-Only, the
status in the response headers. The rest is answered as HTTP: `505` over
HTTP/1.1, `405` for a method other than `POST`, `415` for a
`content-type` none of the codecs speak, the router's `404` for an
unknown service, and `500` for response headers over the client's
SETTINGS_MAX_HEADER_LIST_SIZE. An unknown method of a known service is `UNIMPLEMENTED`,
as is a `grpc-encoding` other than `identity`, `gzip` and `deflate`.

A `grpc-timeout` is the call's deadline. A read still waiting then ends
the call with `DEADLINE_EXCEEDED`; a call still running a second later is
cancelled, as grpc-go and grpc-java do at the deadline: its stream is reset
(`RST_STREAM` with `CANCEL` over HTTP/2, `H3_REQUEST_CANCELLED` over
HTTP/3) and the method stops at its next write or read. Without a timeout
a call may run for as long as the client stays connected. With `auto` buffering the deadline counts from
when the body was read, a little after the client's.

## The method's process

`recv/1` waits for the next request, so a method cannot wait for other
messages at the same time; and the stream belongs to the call's process,
which is the one to `send/2`. A client that cancels the call (or goes
away) stops the method on its next write, quietly: there is no one left to
answer. A method that waits on messages of its own learns of it with
`cancelled/2`. A request that ends the call (too large, malformed, past its
deadline) is thrown out of `recv/1` to end the call with its status, so a
method should not catch everything around `recv/1`.

## Compression

A request's messages may be compressed with `gzip` or `deflate` (the zlib
structure, gRPC's compression.md), as its `grpc-encoding` says; one that
does not decompress ends the call with `INTERNAL`. A response says it reads
all three in `grpc-accept-encoding`. Its own messages are compressed with
the route's `send_compression`, or what `set_send_compression/2` picks for
the call, when the client's `grpc-accept-encoding` lists it, and sent as
they are otherwise; `send/3` with `#{compress => false}` sends one as it
is, to keep a secret out of a compressed stream. `recv_compressed/1` says
whether the message `recv/1` returned last came compressed, a unary or
server-streaming method's request among them.

## Events

A call emits `grpc_call_start` as it starts, then exactly one
`grpc_call_stop` or `grpc_call_exception` as it ends, to the node's
`roadrunner_event_handler`, which has their arguments.

## Metadata

`metadata/1` is the request's custom metadata, without the HTTP/2 and gRPC
headers; `set_headers/2` and `set_trailers/2` add the response's, with
names of `0-9`, `a-z`, `_`, `-` and `.` other than the ones gRPC sets
(`grpc-status`, say) and values of printable ASCII with no space at either
end; others raise, so the call ends `INTERNAL`.
A metadata name ending in `-bin` carries bytes: its value is base64 on the
wire and plain bytes here, both ways; a request's comma-separated values
are each an entry, and one that is not base64 ends the call with
`INTERNAL` before the method runs.
""".

-behaviour(roadrunner_handler).

-export([routes/1, init_route/1, handle/1]).
-export([recv/1, send/2, send/3, metadata/1, set_headers/2, set_trailers/2, deadline/1, peer/1]).
-export([set_send_compression/2, cancelled/2, recv_compressed/1]).
-export([reflection_index/1]).

-export_type([opts/0, status/0, stream/0, encoding/0]).

-define(MAX_MESSAGE_SIZE, 4194304).
%% Where the call's process keeps the response's body writer once it started.
-define(SEND_KEY, {?MODULE, send}).
%% Where it keeps the timer that cancels the call at its deadline, with
%% when a reset counts as the deadline's (`gone/0`).
-define(TIMER_KEY, {?MODULE, deadline_timer}).
%% A stream gone this close to the call's deadline, or later, is the
%% deadline's (`gone/0`). The deadline counts from when the call starts,
%% rounded up to a millisecond: after the request's way here, and after its
%% body was read with `auto` buffering, or the router and middlewares ran
%% with `manual`. A client that cancels as its own deadline passes
%% (grpc-go, grpc-java) has its reset here that much before roadrunner's
%% deadline, less the reset's own way. The slack covers that gap for a
%% call that starts as its request arrives (`manual` buffering, a body that
%% has not had to wait); a call whose body took longer to arrive than the
%% slack is reported `cancelled` instead.
-define(DEADLINE_SLACK, 50).
%% When `cancelled/2` told the method the call is over, which takes the
%% message that said so from the mailbox (`stream_gone/1`, `gone/0`).
-define(GONE_KEY, {?MODULE, gone}).
%% And the call's event span, the client's `grpc-encoding`, and the request
%% and response messages so far, counted and summed in bytes, until the call
%% ends (`call_ended/1`).
-define(CALL_KEY, {?MODULE, call}).
%% And its monitor of the connection (`cancelled/2`).
-define(CONN_KEY, {?MODULE, connection}).
%% How long after its deadline a call still running is cancelled. The
%% client stopped waiting at the deadline; the cancel ends the stream and
%% stops the method at its next write or read, after a read waiting at the
%% deadline had the time to answer.
-define(CANCEL_GRACE, 1000).
-define(OPTS, [service, codecs, max_message_size, send_compression, reflection]).

-doc """
The options `routes/1` takes: `services`, and the route options shared by
every service (see the moduledoc).
""".
-type opts() :: #{
    services := [module() | roadrunner_grpc_service:descriptor()],
    codecs => [module()],
    max_message_size => pos_integer(),
    max_content_length => non_neg_integer(),
    send_compression => encoding(),
    health => boolean(),
    reflection => boolean()
}.

-doc """
A gRPC status (gRPC's statuscodes.md), the codes 0 to 16 by name: `ok` is
0, `deadline_exceeded` 4, `unimplemented` 12, `internal` 13.
""".
-type status() ::
    ok
    | cancelled
    | unknown
    | invalid_argument
    | deadline_exceeded
    | not_found
    | already_exists
    | permission_denied
    | resource_exhausted
    | failed_precondition
    | aborted
    | out_of_range
    | unimplemented
    | internal
    | unavailable
    | data_loss
    | unauthenticated.

-record(route, {
    %% The service's full name, `package.Service`.
    name :: binary(),
    service :: module(),
    rpcs :: #{binary() => {atom(), roadrunner_grpc_service:kind(), term(), term()}},
    codecs :: #{binary() => module()},
    max_message_size :: pos_integer(),
    send_compression :: encoding(),
    %% What the reflection service answers from, on its own routes.
    reflection = undefined :: roadrunner_grpc_reflection:index() | undefined
}).

-record(stream, {
    req :: roadrunner_req:request(),
    codec :: module(),
    content_type :: binary(),
    input :: term(),
    output :: term(),
    max_message_size :: pos_integer(),
    deadline :: integer() | infinity,
    %% The monitor of the client's connection (`cancelled/2`).
    connection = undefined :: reference() | undefined,
    %% The request's custom metadata, `-bin` values decoded.
    metadata = [] :: roadrunner_http:headers(),
    %% Request bytes read and not yet a whole message.
    buffer = <<>> :: binary(),
    %% Whether the request body has ended.
    eof = false :: boolean(),
    %% Whether the message `recv/1` returned last came compressed.
    compressed = false :: boolean(),
    %% How the client compresses its messages (its `grpc-encoding`).
    recv_encoding = identity :: encoding(),
    %% How the response's messages are compressed, and the encodings the
    %% client reads (its `grpc-accept-encoding`).
    send_encoding = identity :: encoding(),
    accepted = [] :: [encoding()],
    headers = [] :: roadrunner_http:headers(),
    trailers = [] :: roadrunner_http:headers(),
    %% The response's body writer once its headers went out.
    send = undefined :: roadrunner_handler:send_fun() | undefined,
    %% Whether the call reports events: a handler other than the no-op one
    %% was set as it started. One that does not keeps no count, span or
    %% ending (`call/4`).
    events = false :: boolean()
}).

-opaque stream() :: #stream{}.

%% How a call ended with a status, or with none: for its events.
-type ending() :: {status(), binary(), roadrunner_event_handler:grpc_stop_reason()}.

-doc "How a message is compressed: `identity` (not), `gzip` or `deflate`.".
-type encoding() :: identity | gzip | deflate.

-doc """
The routes for `Opts`'s `services`, one per service, at
`/package.Service/:method`: `max_content_length` set on each route, the
other options its state.
""".
-spec routes(opts()) -> roadrunner_router:routes().
routes(#{services := Services} = Opts) when is_list(Services) ->
    Shared = maps:without([services, max_content_length, health, reflection], Opts),
    Limits = maps:with([max_content_length], Opts),
    Health = health_route(Opts),
    Health ++
        reflection_routes(Opts, Services, Health) ++
        [
            Limits#{
                path => <<"/", (service_name(Service, Services))/binary, "/:method">>,
                handler => ?MODULE,
                state => Shared#{service => Service}
            }
         || Service <- Services
        ];
routes(Opts) ->
    error({invalid_grpc_opts, Opts}).

%% The health service's route, with `health => true`: it speaks its own
%% protobuf messages, so it takes the raw codec whatever the services use.
-spec health_route(map()) -> roadrunner_router:routes().
health_route(#{health := true}) ->
    [
        #{
            path => <<"/", (roadrunner_grpc_health:name())/binary, "/:method">>,
            handler => ?MODULE,
            state => #{service => roadrunner_grpc_health}
        }
    ];
health_route(#{health := false}) ->
    [];
health_route(#{health := Other}) ->
    error({invalid_grpc_opt, health, Other});
health_route(#{}) ->
    [].

%% Reflection's routes, with `reflection => true`: its own two versions,
%% answering from every service the routes serve, the health service and
%% reflection itself among them. Like the health service, it takes the raw
%% codec.
-spec reflection_routes(map(), [term()], roadrunner_router:routes()) -> roadrunner_router:routes().
reflection_routes(#{reflection := true}, Services, Health) ->
    Own = roadrunner_grpc_reflection:services(),
    Described = Services ++ [Service || #{state := #{service := Service}} <- Health] ++ Own,
    [
        #{
            path => <<"/", Name/binary, "/:method">>,
            handler => ?MODULE,
            state => #{service => Service, reflection => Described}
        }
     || #{name := Name} = Service <- Own
    ];
reflection_routes(#{reflection := false}, _Services, _Health) ->
    [];
reflection_routes(#{reflection := Other}, _Services, _Health) ->
    error({invalid_grpc_opt, reflection, Other});
reflection_routes(#{}, _Services, _Health) ->
    [].

-spec service_name(term(), [term()]) -> binary().
service_name(#{name := Name, rpcs := Rpcs} = Service, Services) when is_map(Rpcs) ->
    case descriptor(Service) of
        true -> Name;
        false -> error({invalid_grpc_opt, services, Services})
    end;
service_name(Service, Services) ->
    maybe
        true ?= is_atom(Service),
        {module, Service} ?= code:ensure_loaded(Service),
        true ?= erlang:function_exported(Service, name, 0),
        true ?= erlang:function_exported(Service, rpcs, 0),
        Name = Service:name(),
        true ?= is_binary(Name),
        Name
    else
        _ -> error({invalid_grpc_opt, services, Services})
    end.

-doc """
Check a route's options when the routes compile and build its state: the
service's methods by name and the codecs by subtype. A bad option raises
`{unknown_grpc_opt, Key}` or `{invalid_grpc_opt, Key, Value}`, which stops
the listener from starting.
""".
-spec init_route(map()) -> #route{}.
init_route(#{service := Service} = Opts) ->
    ok = check_known_opts(Opts),
    {Name, Module, Rpcs} = service(Service),
    #route{
        name = Name,
        service = Module,
        rpcs = rpcs(Module, Rpcs),
        codecs = codecs(maps:get(codecs, Opts, [roadrunner_grpc_codec_raw])),
        max_message_size = max_message_size(Opts),
        send_compression = send_compression(Opts),
        reflection = reflection(Opts)
    };
init_route(Opts) ->
    error({invalid_grpc_opts, Opts}).

-spec check_known_opts(map()) -> ok.
check_known_opts(Opts) ->
    case [Key || Key <- maps:keys(Opts), not lists:member(Key, ?OPTS)] of
        [] -> ok;
        [Key | _] -> error({unknown_grpc_opt, Key})
    end.

%% The service's name, the module that holds the methods, and the methods: a
%% service module's own, or a descriptor's.
-spec service(term()) -> {binary(), module(), term()}.
service(Service) when is_atom(Service) ->
    ok = loaded(Service, Service),
    {module_name(Service), Service, Service:rpcs()};
service(#{module := Module, rpcs := Rpcs} = Service) ->
    case descriptor(Service) of
        true ->
            ok = loaded(Module, Service),
            #{name := Name} = Service,
            {Name, Module, Rpcs};
        false ->
            error({invalid_grpc_opt, service, Service})
    end;
service(Service) ->
    error({invalid_grpc_opt, service, Service}).

%% A service given as data: its name, module and methods, and maybe its
%% files (`roadrunner_grpc_service:descriptor/0`), nothing else.
-spec descriptor(map()) -> boolean().
descriptor(#{name := Name, module := Module} = Service) when is_binary(Name), is_atom(Module) ->
    case Service of
        #{files := Files} ->
            map_size(Service) =:= 4 andalso is_list(Files) andalso
                lists:all(fun erlang:is_binary/1, Files);
        #{} ->
            map_size(Service) =:= 3
    end;
descriptor(#{}) ->
    false.

%% The reflection service's index, on its routes: each service's name and
%% files, a module's from its `files/0`, a descriptor's from its `files`.
-spec reflection(map()) -> roadrunner_grpc_reflection:index() | undefined.
reflection(#{reflection := Services}) when is_list(Services) ->
    roadrunner_grpc_reflection:index([
        {service_name(Service, Services), Service, service_files(Service)}
     || Service <- Services
    ]);
reflection(#{reflection := Other}) ->
    error({invalid_grpc_opt, reflection, Other});
reflection(#{}) ->
    undefined.

-spec service_files(module() | roadrunner_grpc_service:descriptor()) -> term().
service_files(#{files := Files}) ->
    Files;
service_files(#{}) ->
    [];
service_files(Module) ->
    case erlang:function_exported(Module, files, 0) of
        true -> Module:files();
        false -> []
    end.

-spec module_name(module()) -> binary().
module_name(Service) ->
    case erlang:function_exported(Service, name, 0) andalso Service:name() of
        Name when is_binary(Name) -> Name;
        _ -> error({invalid_grpc_opt, service, Service})
    end.

-spec loaded(module(), term()) -> ok.
loaded(Module, Service) ->
    case code:ensure_loaded(Module) of
        {module, Module} -> ok;
        {error, _} -> error({invalid_grpc_opt, service, Service})
    end.

-spec rpcs(module(), term()) ->
    #{binary() => {atom(), roadrunner_grpc_service:kind(), term(), term()}}.
rpcs(Service, Rpcs) ->
    maps:map(
        fun
            (Name, #{function := Function, kind := Kind, input := In, output := Out} = Rpc) when
                is_atom(Function),
                (Kind =:= unary orelse Kind =:= server_stream orelse
                    Kind =:= client_stream orelse Kind =:= bidi_stream)
            ->
                case erlang:function_exported(Service, Function, arity(Kind)) of
                    true -> {Function, Kind, In, Out};
                    false -> error({invalid_grpc_opt, service, {Service, Name, Rpc}})
                end;
            (Name, Rpc) ->
                error({invalid_grpc_opt, service, {Service, Name, Rpc}})
        end,
        case Rpcs of
            #{} -> Rpcs;
            Other -> error({invalid_grpc_opt, service, {Service, Other}})
        end
    ).

-spec arity(roadrunner_grpc_service:kind()) -> 1 | 2.
arity(Kind) when Kind =:= unary; Kind =:= server_stream -> 2;
arity(_Kind) -> 1.

-spec codecs(term()) -> #{binary() => module()}.
codecs([_ | _] = Codecs) ->
    BySubtype = maps:from_list([{codec_subtype(Codec, Codecs), Codec} || Codec <- Codecs]),
    case map_size(BySubtype) =:= length(Codecs) of
        true -> BySubtype;
        false -> error({invalid_grpc_opt, codecs, Codecs})
    end;
codecs(Codecs) ->
    error({invalid_grpc_opt, codecs, Codecs}).

-spec codec_subtype(term(), [term()]) -> binary().
codec_subtype(Codec, Codecs) when is_atom(Codec) ->
    case code:ensure_loaded(Codec) =:= {module, Codec} andalso Codec:subtype() of
        Subtype when is_binary(Subtype) -> roadrunner_bin:ascii_lowercase(Subtype);
        _Other -> error({invalid_grpc_opt, codecs, Codecs})
    end;
codec_subtype(_Codec, Codecs) ->
    error({invalid_grpc_opt, codecs, Codecs}).

-spec send_compression(map()) -> encoding().
send_compression(#{send_compression := Encoding}) when
    Encoding =:= identity; Encoding =:= gzip; Encoding =:= deflate
->
    Encoding;
send_compression(#{send_compression := Encoding}) ->
    error({invalid_grpc_opt, send_compression, Encoding});
send_compression(#{}) ->
    identity.

-spec max_message_size(map()) -> pos_integer().
max_message_size(#{max_message_size := Size}) when is_integer(Size), Size > 0 ->
    Size;
max_message_size(#{max_message_size := Size}) ->
    error({invalid_grpc_opt, max_message_size, Size});
max_message_size(#{}) ->
    ?MAX_MESSAGE_SIZE.

-doc false.
-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    maybe
        ok ?= http2_or_later(roadrunner_req:version(Req)),
        ok ?= post(roadrunner_req:method(Req)),
        #route{} = Route = roadrunner_req:state(Req),
        {ok, ContentType, Codec} ?= codec(roadrunner_req:header(~"content-type", Req), Route),
        {{send, [], fun(R) -> call(R, ContentType, Codec, Route) end}, Req}
    else
        {http, Status, Headers} -> {{Status, Headers, <<>>}, Req}
    end.

-spec http2_or_later(roadrunner_http:version()) -> ok | {http, 505, roadrunner_http:headers()}.
http2_or_later({Major, _Minor}) when Major >= 2 -> ok;
http2_or_later(_Version) -> {http, 505, []}.

-spec post(binary()) -> ok | {http, 405, roadrunner_http:headers()}.
post(~"POST") -> ok;
post(_Method) -> {http, 405, [{~"allow", ~"POST"}]}.

%% `application/grpc` is the `proto` subtype; `application/grpc+Sub` names
%% its own, before any `;` parameters.
-spec codec(binary() | undefined, #route{}) ->
    {ok, binary(), module()} | {http, 415, roadrunner_http:headers()}.
codec(ContentType, #route{codecs = Codecs}) when is_binary(ContentType) ->
    %% Media types are matched without regard to case (RFC 9110 §8.3.1).
    case roadrunner_bin:ascii_lowercase(ContentType) of
        <<"application/grpc", Rest/binary>> ->
            Subtype = subtype(Rest),
            case Codecs of
                #{Subtype := Codec} -> {ok, response_content_type(Subtype, Rest), Codec};
                #{} -> {http, 415, []}
            end;
        _Other ->
            {http, 415, []}
    end;
codec(undefined, _Route) ->
    {http, 415, []}.

%% The response's `content-type`: the request's media type in lowercase,
%% without its parameters.
-spec response_content_type(binary(), binary()) -> binary().
response_content_type(Subtype, <<"+", _/binary>>) -> <<"application/grpc+", Subtype/binary>>;
response_content_type(_Subtype, _Rest) -> ~"application/grpc".

-spec subtype(binary()) -> binary() | invalid.
subtype(<<" ", Rest/binary>>) -> subtype(Rest);
subtype(<<"\t", Rest/binary>>) -> subtype(Rest);
subtype(<<>>) -> ~"proto";
subtype(<<";", _/binary>>) -> ~"proto";
subtype(<<"+", Sub/binary>>) -> roadrunner_bin:trim_ows(hd(binary:split(Sub, ~";")));
subtype(_Rest) -> invalid.

%% The call, on the request's process, between its `grpc_call_start` event
%% and the one that ends it. A call that ends in an exit or a raise reports
%% how it ended and goes on ending as it would. The handler is read once, as
%% the call starts: with the no-op one, the default, the call reports
%% nothing and keeps nothing for it.
-spec call(roadrunner_req:request(), binary(), module(), #route{}) -> roadrunner_req:request().
call(Req, ContentType, Codec, #route{name = Name, rpcs = Rpcs} = Route) ->
    #{~"method" := Method} = roadrunner_req:bindings(Req),
    Rpc =
        case Rpcs of
            #{Method := Found} -> Found;
            #{} -> undefined
        end,
    RecvEncoding = request_encoding(roadrunner_req:header(~"grpc-encoding", Req)),
    case roadrunner_event:enabled() of
        true ->
            Span = roadrunner_event:grpc_call_start(Req, Name, Method, rpc_kind(Rpc)),
            _ = put(?CALL_KEY, {Span, RecvEncoding, 0, 0, 0, 0}),
            try
                run_call(Req, ContentType, Codec, Route, Method, Rpc, RecvEncoding, true)
            catch
                Class:Reason:Stacktrace ->
                    ok = call_raised(Class, Reason, Stacktrace),
                    erlang:raise(Class, Reason, Stacktrace)
            end;
        false ->
            run_call(Req, ContentType, Codec, Route, Method, Rpc, RecvEncoding, false)
    end.

-spec rpc_kind({atom(), roadrunner_grpc_service:kind(), term(), term()} | undefined) ->
    roadrunner_grpc_service:kind() | undefined.
rpc_kind({_Function, Kind, _In, _Out}) -> Kind;
rpc_kind(undefined) -> undefined.

%% The call's checks ahead of the method, then the method, then the status
%% that ends it.
-spec run_call(
    roadrunner_req:request(),
    binary(),
    module(),
    #route{},
    binary(),
    {atom(), roadrunner_grpc_service:kind(), term(), term()} | undefined,
    encoding() | binary(),
    boolean()
) -> roadrunner_req:request().
run_call(Req, ContentType, Codec, #route{service = Service} = Route, Method, Rpc, Encoding, Events) ->
    Stream0 = #stream{
        req = Req,
        codec = Codec,
        content_type = ContentType,
        input = undefined,
        output = undefined,
        max_message_size = Route#route.max_message_size,
        deadline = infinity,
        events = Events
    },
    try
        {Function, Kind, In, Out} = rpc(Method, Rpc),
        RecvEncoding = recv_encoding(Encoding),
        Accepted = accepted(roadrunner_req:header(~"grpc-accept-encoding", Req)),
        Timeout = timeout(roadrunner_req:header(~"grpc-timeout", Req)),
        Stream = Stream0#stream{
            recv_encoding = RecvEncoding,
            accepted = Accepted,
            send_encoding = sendable(Route#route.send_compression, Accepted),
            metadata = request_metadata(roadrunner_req:headers(Req)),
            req = roadrunner_req:set_body_timeout(Timeout, Req),
            input = In,
            output = Out,
            deadline = deadline_after(Timeout, Req),
            connection = watch_connection(Req)
        },
        finish(run(Kind, Service, Function, Stream))
    catch
        throw:{?MODULE, Status, Message, Headers, Thrown} ->
            finish({error, Status, Message, add_headers(Headers, Thrown)});
        throw:{?MODULE, Status, Message, Headers} ->
            finish({error, Status, Message, add_headers(Headers, Stream0)})
    end.

-spec rpc(binary(), {atom(), roadrunner_grpc_service:kind(), term(), term()} | undefined) ->
    {atom(), roadrunner_grpc_service:kind(), term(), term()}.
rpc(Method, undefined) ->
    throw({?MODULE, unimplemented, <<"unknown method ", Method/binary>>, []});
rpc(_Method, Rpc) ->
    Rpc.

%% The client's `grpc-encoding`, as the call's events report it: one
%% roadrunner reads, or the header's value.
-spec request_encoding(binary() | undefined) -> encoding() | binary().
request_encoding(undefined) ->
    identity;
request_encoding(Value) ->
    case encoding(Value) of
        unknown -> Value;
        Known -> Known
    end.

%% A `grpc-encoding` roadrunner reads, or the call ends `UNIMPLEMENTED`
%% naming the ones it does (gRPC's compression.md).
-spec recv_encoding(encoding() | binary()) -> encoding().
recv_encoding(Encoding) when is_atom(Encoding) ->
    Encoding;
recv_encoding(Encoding) ->
    Supported = roadrunner_grpc_compress:encodings(),
    throw(
        {?MODULE, unimplemented,
            <<"unsupported grpc-encoding ", Encoding/binary, "; supported: ", Supported/binary>>,
            []}
    ).

-spec encoding(binary()) -> encoding() | unknown.
encoding(~"identity") -> identity;
encoding(~"gzip") -> gzip;
encoding(~"deflate") -> deflate;
encoding(_Other) -> unknown.

%% The encodings the client reads, from its `grpc-accept-encoding`.
-spec accepted(binary() | undefined) -> [encoding()].
accepted(undefined) ->
    [];
accepted(Value) ->
    [
        Encoding
     || Part <- binary:split(Value, ~",", [global]),
        Encoding <- [encoding(roadrunner_bin:trim_ows(Part))],
        Encoding =/= unknown
    ].

%% A response is compressed only with an encoding the client reads, and
%% sent as it is otherwise (gRPC's compression.md).
-spec sendable(encoding(), [encoding()]) ->
    encoding().
sendable(identity, _Accepted) ->
    identity;
sendable(Encoding, Accepted) ->
    case lists:member(Encoding, Accepted) of
        true -> Encoding;
        false -> identity
    end.

-spec timeout(binary() | undefined) -> non_neg_integer() | infinity.
timeout(undefined) ->
    infinity;
timeout(Value) ->
    case roadrunner_grpc_timeout:parse(Value) of
        {ok, Timeout} -> Timeout;
        error -> throw({?MODULE, internal, <<"malformed grpc-timeout ", Value/binary>>, []})
    end.

%% When the call's timeout runs out. A call still running a little after
%% (`?CANCEL_GRACE`, which leaves a read waiting at the deadline the time to
%% end the call with `DEADLINE_EXCEEDED`) is cancelled: the stream is reset
%% and the method stops at its next write or read. The timer is cancelled
%% when the call ends before (`ended/1`).
-spec deadline_after(non_neg_integer() | infinity, roadrunner_req:request()) ->
    integer() | infinity.
deadline_after(infinity, _Req) ->
    infinity;
deadline_after(Ms, Req) ->
    %% A call runs over HTTP/2 or HTTP/3 (`handle/1` answers HTTP/1.1 with
    %% 505), both of which can cancel a stream.
    {ok, Timer} = roadrunner_send_writer:cancel_after(Ms + ?CANCEL_GRACE, Req),
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    _ = put(?TIMER_KEY, {Timer, Deadline - ?DEADLINE_SLACK}),
    Deadline.

-spec add_headers(roadrunner_http:headers(), stream()) -> stream().
add_headers(Headers, #stream{headers = Own} = Stream) ->
    Stream#stream{headers = Headers ++ Own}.

%% Run the method. A crash is logged and answered `INTERNAL`: the client
%% gets a status, not a reset, and the log has the stack.
-spec run(roadrunner_grpc_service:kind(), module(), atom(), stream()) ->
    {ok, stream()} | {error, status(), binary(), stream()}.
run(Kind, Service, Function, Stream) ->
    try
        result(Kind, invoke(Kind, Service, Function, Stream))
    catch
        throw:{?MODULE, _, _, _, _} = Abort ->
            throw(Abort);
        exit:{shutdown, _} = Exit ->
            exit(Exit);
        exit:Gone when
            Gone =:= stream_reset;
            Gone =:= conn_down;
            is_tuple(Gone), element(1, Gone) =:= quic_conn_down
        ->
            %% The client cancelled the call or its connection went away: no
            %% one to answer, nothing to log.
            exit(Gone);
        Class:Reason:Stacktrace ->
            logger:error(
                #{
                    msg => grpc_method_crashed,
                    service => Service,
                    function => Function,
                    class => Class,
                    reason => Reason,
                    stacktrace => Stacktrace
                },
                #{domain => [roadrunner, grpc]}
            ),
            %% Reported as it is caught, ahead of the INTERNAL status, as a
            %% request's crash is ahead of its 500.
            ok = call_ended({exception, Class, Reason, Stacktrace}),
            {error, internal, ~"internal error", Stream}
    end.

%% What the method returned, checked against its kind; a unary or
%% client-streaming reply is sent here, so a codec that fails on it is
%% caught like a crash.
-spec result(roadrunner_grpc_service:kind(), term()) ->
    {ok, stream()} | {error, status(), binary(), stream()}.
result(Kind, {reply, Response, #stream{} = Stream}) when Kind =:= unary; Kind =:= client_stream ->
    {ok, send(Response, Stream)};
result(Kind, {ok, #stream{} = Stream}) when Kind =:= server_stream; Kind =:= bidi_stream ->
    {ok, Stream};
result(_Kind, {error, Status, Message, #stream{} = Stream}) when is_binary(Message) ->
    _ = roadrunner_grpc_status:code(Status),
    {error, Status, Message, Stream};
result(_Kind, Other) ->
    error({bad_return, Other}).

-spec invoke(roadrunner_grpc_service:kind(), module(), atom(), stream()) -> term().
invoke(Kind, Service, Function, Stream) when Kind =:= unary; Kind =:= server_stream ->
    {Request, Stream1} = only_request(Stream),
    Service:Function(Request, Stream1);
invoke(_Kind, Service, Function, Stream) ->
    Service:Function(Stream).

%% A unary or server-streaming call carries exactly one request message.
-spec only_request(stream()) -> {term(), stream()}.
only_request(Stream) ->
    case recv(Stream) of
        {ok, Request, Stream1} ->
            case recv(Stream1) of
                {eof, Stream2} -> {Request, Stream2};
                {ok, _More, Stream2} -> abort(internal, ~"more than one request message", Stream2)
            end;
        {eof, Stream1} ->
            abort(internal, ~"no request message", Stream1)
    end.

%% End the call: with trailers after a response that started, else
%% Trailers-Only, the status in the response headers.
-spec finish({ok, stream()} | {error, status(), binary(), stream()}) -> roadrunner_req:request().
finish({ok, Stream}) ->
    ended(finish(ok, <<>>, Stream));
finish({error, Status, Message, Stream}) ->
    ended(finish(Status, Message, Stream)).

%% The call ended as its status went out, or as the stream went away first.
-spec ended({ending(), roadrunner_req:request()}) -> roadrunner_req:request().
ended({Ending, Req}) ->
    ok = call_ended(Ending),
    _ = erase(?SEND_KEY),
    _ =
        case erase(?TIMER_KEY) of
            undefined -> ok;
            {Timer, _Deadline} -> erlang:cancel_timer(Timer, [{async, true}, {info, false}])
        end,
    _ =
        case erase(?CONN_KEY) of
            undefined -> true;
            Ref -> demonitor(Ref, [flush])
        end,
    Req.

%% The call ending with `Status`, which the client gets.
-spec status_ending(status(), binary()) -> ending().
status_ending(ok, Message) -> {ok, Message, normal};
status_ending(Status, Message) -> {Status, Message, error}.

%% Whether the client cancelled the call, or its connection went away,
%% before a status that goes out one way (Trailers-Only), which no one
%% would then read: `cancelled/2` said so to the method, or the message
%% that says so waits in the mailbox.
-spec stream_gone(stream()) -> boolean().
stream_gone(#stream{connection = Ref}) ->
    get(?GONE_KEY) =/= undefined orelse
        receive
            {h2_stream_reset, _StreamId} -> true;
            {roadrunner_stream_reset, _StreamId} -> true;
            {'DOWN', Ref, process, _Pid, _Reason} -> true
        after 0 -> false
        end.

%% A call stopped with no gRPC status: before a response, the client reads
%% the HTTP status (a 500) as `UNKNOWN`; after one, a stream that ends
%% without trailers as `INTERNAL`.
-spec stopped_ending() -> ending().
stopped_ending() ->
    case get(?SEND_KEY) of
        undefined -> {unknown, <<>>, stopped};
        {_Send, _Encoding} -> {internal, <<>>, stopped}
    end.

%% How a call that exits or raises ended. An exit of the call's own, the
%% client cancelling, its connection gone, a write or read that failed with
%% it, is no crash; nor is a stop on purpose (`{shutdown, _}`), the method's
%% or the call's when its response headers are too large for the client.
-spec call_raised(error | exit | throw, term(), erlang:stacktrace()) -> ok.
call_raised(exit, {shutdown, {grpc_send, TooLarge}}, _Stacktrace) when
    TooLarge =:= header_list_too_large; TooLarge =:= field_section_too_large
->
    call_ended(stopped_ending());
call_raised(exit, {shutdown, {Op, _Reason}}, _Stacktrace) when
    Op =:= grpc_send; Op =:= grpc_recv
->
    call_ended(gone());
call_raised(exit, {shutdown, _Reason}, _Stacktrace) ->
    call_ended(stopped_ending());
call_raised(exit, Gone, _Stacktrace) when
    Gone =:= stream_reset;
    Gone =:= conn_down;
    is_tuple(Gone), element(1, Gone) =:= quic_conn_down
->
    call_ended(gone());
call_raised(Class, Reason, Stacktrace) ->
    call_ended({exception, Class, Reason, Stacktrace}).

%% A call whose stream went away before its status: from `?DEADLINE_SLACK`
%% ahead of its deadline on, the deadline's (whether roadrunner or the
%% client reset it then); before, the client cancelled it or its connection
%% went away. When it went away is when `cancelled/2` told the method, or
%% else when the call finds out (a write or read that fails, a reset in the
%% mailbox), which may be later than the reset came in.
-spec gone() -> ending().
gone() ->
    At =
        case erase(?GONE_KEY) of
            undefined -> erlang:monotonic_time(millisecond);
            Told -> Told
        end,
    case get(?TIMER_KEY) of
        {_Timer, Reached} when At >= Reached -> {deadline_exceeded, <<>>, deadline};
        _ -> {cancelled, <<>>, cancelled}
    end.

%% Emit the event that ends the call, once: the first to end it takes its
%% span, so a crash already reported is not reported again as the call
%% then ends.
-spec call_ended(ending() | {exception, error | exit | throw, term(), erlang:stacktrace()}) ->
    ok.
call_ended(Ending) ->
    case erase(?CALL_KEY) of
        {Span, RecvEncoding, Received, ReceivedBytes, Sent, SentBytes} ->
            Messages = {Received, ReceivedBytes, Sent, SentBytes},
            Encodings = {RecvEncoding, sent_encoding()},
            case Ending of
                {exception, Class, Reason, Stacktrace} ->
                    roadrunner_event:grpc_call_exception(
                        Span, Class, Reason, Stacktrace, Messages, Encodings
                    );
                {Status, Message, Reason} ->
                    roadrunner_event:grpc_call_stop(
                        Span, Status, Message, Reason, Messages, Encodings
                    )
            end;
        undefined ->
            ok
    end.

%% The response messages' encoding: the one their headers announced, or
%% `identity` when no response started.
-spec sent_encoding() -> encoding().
sent_encoding() ->
    case get(?SEND_KEY) of
        {_Send, Encoding} -> Encoding;
        undefined -> identity
    end.

-spec count_received(stream(), non_neg_integer()) -> ok.
count_received(#stream{events = false}, _Bytes) ->
    ok;
count_received(#stream{events = true}, Bytes) ->
    {Span, Encoding, Received, ReceivedBytes, Sent, SentBytes} = get(?CALL_KEY),
    _ = put(?CALL_KEY, {Span, Encoding, Received + 1, ReceivedBytes + Bytes, Sent, SentBytes}),
    ok.

%% A framed message's bytes, read off its prefix.
-spec count_sent(stream(), iodata()) -> ok.
count_sent(#stream{events = false}, _Frame) ->
    ok;
count_sent(#stream{events = true}, [<<_Flag, Bytes:32>>, _Message]) ->
    {Span, Encoding, Received, ReceivedBytes, Sent, SentBytes} = get(?CALL_KEY),
    _ = put(?CALL_KEY, {Span, Encoding, Received, ReceivedBytes, Sent + 1, SentBytes + Bytes}),
    ok.

%% Monitor the client's connection for the call (`cancelled/2`). A call
%% runs over HTTP/2 or HTTP/3 (`handle/1` answers HTTP/1.1 with 505), both of
%% which can be monitored.
-spec watch_connection(roadrunner_req:request()) -> reference().
watch_connection(Req) ->
    {ok, Ref} = roadrunner_send_writer:monitor_connection(Req),
    _ = put(?CONN_KEY, Ref),
    Ref.

-doc """
Whether `Message`, one the method's process received, says the call is
over: the client cancelled it (its stream reset) or its connection went
away. A method that waits on messages of its own, such as a server stream
pushing events, checks each one with it and returns when it is `true`, as
there is no one left to answer:

```erlang
events(Stream) ->
    receive
        {event, Data} ->
            events(roadrunner_grpc:send(Data, Stream));
        Other ->
            case roadrunner_grpc:cancelled(Other, Stream) of
                true -> {ok, Stream};
                false -> events(Stream)
            end
    end.
```
""".
-spec cancelled(term(), stream()) -> boolean().
cancelled({h2_stream_reset, _StreamId}, Stream) ->
    gone_now(Stream);
cancelled({roadrunner_stream_reset, _StreamId}, Stream) ->
    gone_now(Stream);
cancelled({'DOWN', Ref, process, _Pid, _Reason}, #stream{connection = Ref} = Stream) ->
    gone_now(Stream);
cancelled(_Message, _Stream) ->
    false.

%% The call is over: its events say so whatever the method returns next.
-spec gone_now(stream()) -> true.
gone_now(#stream{events = false}) ->
    true;
gone_now(#stream{events = true}) ->
    _ = put(?GONE_KEY, erlang:monotonic_time(millisecond)),
    true.

-spec finish(status(), binary(), stream()) -> {ending(), roadrunner_req:request()}.
finish(Status, Message, #stream{send = undefined} = Stream) ->
    %% The method may have started the response on a stream it then lost,
    %% crashing or aborting: the writer is kept where the call can find it.
    case get(?SEND_KEY) of
        undefined -> trailers_only(Status, Message, Stream);
        {Send, _Encoding} -> finish(Status, Message, Stream#stream{send = Send})
    end;
finish(Status, Message, #stream{send = Send, req = Req} = Stream) ->
    %% A stream the client reset or lost fails this write, which waits on
    %% the connection.
    ok = written(Send(<<>>, {fin, status_headers(Status, Message, Stream)})),
    {status_ending(Status, Message), Req}.

%% A call that ends before any response: the status in the response
%% headers, a single HEADERS frame that ends the stream. It goes one way,
%% so a stream already reset or lost does not fail it: what the call's
%% events report is found out first, by a call that reports them.
-spec trailers_only(status(), binary(), stream()) -> {ending(), roadrunner_req:request()}.
trailers_only(Status, Message, #stream{req = Req, events = Events} = Stream) ->
    Ending =
        case Events andalso stream_gone(Stream) of
            true -> gone();
            false -> status_ending(Status, Message)
        end,
    Headers = response_headers(Stream) ++ status_headers(Status, Message, Stream),
    ok = written(roadrunner_send:reply(200, Headers, <<>>, Req)),
    {Ending, Req}.

%% A write that could not go out (the client is gone, say) stops the call.
-spec written(ok | {error, term()}) -> ok.
written(ok) -> ok;
written({error, Reason}) -> stopped(Reason).

-spec stopped(term()) -> no_return().
stopped(Reason) ->
    exit({shutdown, {grpc_send, Reason}}).

-spec response_headers(stream()) -> roadrunner_http:headers().
response_headers(#stream{content_type = ContentType, headers = Headers, send_encoding = Encoding}) ->
    [
        {~"content-type", ContentType},
        {~"grpc-accept-encoding", roadrunner_grpc_compress:encodings()}
        | encoding_header(Encoding, Headers)
    ].

-spec encoding_header(encoding(), roadrunner_http:headers()) ->
    roadrunner_http:headers().
encoding_header(identity, Headers) -> Headers;
encoding_header(Encoding, Headers) -> [{~"grpc-encoding", atom_to_binary(Encoding)} | Headers].

-spec status_headers(status(), binary(), stream()) -> roadrunner_http:headers().
status_headers(Status, Message, #stream{trailers = Trailers}) ->
    Code = integer_to_binary(roadrunner_grpc_status:code(Status)),
    case Message of
        <<>> ->
            [{~"grpc-status", Code} | Trailers];
        _ ->
            [
                {~"grpc-status", Code},
                {~"grpc-message", roadrunner_grpc_status:encode_message(Message)}
                | Trailers
            ]
    end.

-spec abort(status(), binary(), stream()) -> no_return().
abort(Status, Message, Stream) ->
    throw({?MODULE, Status, Message, [], Stream}).

-doc """
The next request message, or `eof` once the client's requests have ended.
A message too large, malformed or cut short ends the call (with
`RESOURCE_EXHAUSTED` or `INTERNAL`), and the call's `grpc-timeout`
running out while it waits with `DEADLINE_EXCEEDED`.
""".
-spec recv(stream()) -> {ok, term(), stream()} | {eof, stream()}.
recv(#stream{buffer = Buffer, max_message_size = Max} = Stream) ->
    case roadrunner_grpc_frame:decode(Buffer, Max) of
        {ok, false, Bytes, Rest} ->
            Message = decode(Bytes, Stream),
            ok = count_received(Stream, byte_size(Bytes)),
            {ok, Message, Stream#stream{buffer = Rest, compressed = false}};
        {ok, true, _Bytes, _Rest} when Stream#stream.recv_encoding =:= identity ->
            abort(internal, ~"compressed message without a grpc-encoding to read it", Stream);
        {ok, true, Compressed, Rest} ->
            Message = decode(decompressed(Compressed, Stream), Stream),
            ok = count_received(Stream, byte_size(Compressed)),
            {ok, Message, Stream#stream{buffer = Rest, compressed = true}};
        {error, message_too_large} ->
            abort(resource_exhausted, ~"request message too large", Stream);
        {error, bad_compressed_flag} ->
            abort(internal, ~"malformed request message", Stream);
        more ->
            read_more(Stream)
    end.

-spec decompressed(binary(), stream()) -> binary().
decompressed(Compressed, #stream{recv_encoding = Encoding, max_message_size = Max} = Stream) ->
    case roadrunner_grpc_compress:decompress(Encoding, Compressed, Max) of
        {ok, Bytes} -> Bytes;
        {error, too_large} -> abort(resource_exhausted, ~"request message too large", Stream);
        {error, malformed} -> abort(internal, ~"request message does not decompress", Stream)
    end.

-spec decode(binary(), stream()) -> term().
decode(Bytes, #stream{codec = Codec, input = In} = Stream) ->
    try
        Codec:decode(In, Bytes)
    catch
        _:_ -> abort(internal, ~"request message does not decode", Stream)
    end.

%% Read what the next message still lacks: the rest of its 5-byte prefix,
%% or of the message the prefix announced.
-spec read_more(stream()) -> {ok, term(), stream()} | {eof, stream()}.
read_more(#stream{eof = true, buffer = <<>>} = Stream) ->
    {eof, Stream};
read_more(#stream{eof = true} = Stream) ->
    abort(internal, ~"request message cut short", Stream);
read_more(#stream{req = Req, buffer = Buffer} = Stream) ->
    case read_body(Buffer, Req) of
        {more, Bytes, Req1} ->
            recv(Stream#stream{req = Req1, buffer = append(Buffer, Bytes)});
        {ok, Bytes, Req1} ->
            recv(Stream#stream{req = Req1, buffer = append(Buffer, Bytes), eof = true});
        {error, request_timeout} ->
            abort(deadline_exceeded, ~"deadline exceeded", Stream);
        {error, content_length_too_large} ->
            abort(resource_exhausted, ~"request body over the route's max_content_length", Stream);
        {error, Reason} ->
            exit({shutdown, {grpc_recv, Reason}})
    end.

%% Between messages, read what has arrived, which for a small call is the
%% whole message and the end of the requests at once; partway through one,
%% read what it still lacks, so a large message is gathered in one read
%% instead of growing the buffer DATA by DATA.
-spec read_body(binary(), roadrunner_req:request()) ->
    {ok | more, iodata(), roadrunner_req:request()} | {error, term()}.
read_body(<<>>, Req) ->
    roadrunner_req:read_body_chunked(Req);
read_body(Buffer, Req) ->
    roadrunner_req:read_body(Req, #{length => missing(Buffer)}).

-spec append(binary(), iodata()) -> binary().
append(<<>>, Bytes) -> iolist_to_binary(Bytes);
append(Buffer, Bytes) -> <<Buffer/binary, (iolist_to_binary(Bytes))/binary>>.

-spec missing(binary()) -> pos_integer().
missing(<<_Flag, Len:32, Message/binary>>) -> Len - byte_size(Message);
missing(Partial) -> 5 - byte_size(Partial).

-doc """
Send a response message, the response's headers going first with the
first one. A client that went away stops the call.
""".
-spec send(term(), stream()) -> stream().
send(Message, Stream) ->
    send(Message, Stream, #{}).

-doc """
`send/2`, with `#{compress => false}` sending this message uncompressed
whatever the call's compression (`set_send_compression/2`): gRPC's way to
keep a message with a secret out of a compressed stream (BEAST/CRIME).
""".
-spec send(term(), stream(), #{compress => boolean()}) -> stream().
send(Message, #stream{codec = Codec, output = Out} = Stream0, Opts) ->
    Bytes = Codec:encode(Out, Message),
    #stream{send = Send, send_encoding = Encoding} = Stream = started(Stream0),
    Frame =
        case {Encoding, Opts} of
            {identity, _} ->
                roadrunner_grpc_frame:encode(false, Bytes);
            {_, #{compress := false}} ->
                roadrunner_grpc_frame:encode(false, Bytes);
            {_, _} ->
                roadrunner_grpc_frame:encode(
                    true, roadrunner_grpc_compress:compress(Encoding, Bytes)
                )
        end,
    ok = written(Send(Frame, nofin)),
    ok = count_sent(Stream, Frame),
    Stream.

%% The response's headers go out once: a stream copy from before the first
%% send still finds the writer the call keeps, and the encoding its headers
%% announced, which every message after follows.
-spec started(stream()) -> stream().
started(#stream{req = Req, send_encoding = Encoding} = Stream) ->
    case get(?SEND_KEY) of
        undefined ->
            case roadrunner_send:stream(200, response_headers(Stream), Req) of
                {ok, Send} ->
                    _ = put(?SEND_KEY, {Send, Encoding}),
                    Stream#stream{send = Send};
                {error, Reason} ->
                    stopped(Reason)
            end;
        {Send, Announced} ->
            Stream#stream{send = Send, send_encoding = Announced}
    end.

-doc """
The request's custom metadata: its headers less the ones HTTP/2 and gRPC
use themselves (`content-type`, `te`, `user-agent`, `host` and every
`grpc-*` name, which the protocol reserves). A `-bin` value is decoded from
base64, each of its comma-separated values one entry.
""".
-spec metadata(stream()) -> roadrunner_http:headers().
metadata(#stream{metadata = Metadata}) ->
    Metadata.

%% Read the custom metadata once, as the call starts: a `-bin` value that is
%% not base64 ends the call with `INTERNAL`, ahead of the method.
-spec request_metadata(roadrunner_http:headers()) -> roadrunner_http:headers().
request_metadata(Headers) ->
    lists:flatmap(
        fun({Name, Value}) ->
            case custom(Name) of
                true -> metadata_values(Name, Value);
                false -> []
            end
        end,
        Headers
    ).

-spec custom(binary()) -> boolean().
custom(<<"grpc-", _/binary>>) -> false;
custom(Name) -> not lists:member(Name, [~"content-type", ~"te", ~"user-agent", ~"host"]).

%% gRPC's PROTOCOL-HTTP2: binary headers are split on "," before decoding.
-spec metadata_values(binary(), binary()) -> roadrunner_http:headers().
metadata_values(Name, Value) ->
    case binary:longest_common_suffix([Name, ~"-bin"]) of
        4 -> [{Name, unbase64(Name, Part)} || Part <- binary:split(Value, ~",", [global])];
        _ -> [{Name, Value}]
    end.

-spec unbase64(binary(), binary()) -> binary().
unbase64(Name, Part) ->
    try
        base64:decode(roadrunner_bin:trim_ows(Part), #{padding => false})
    catch
        error:_ -> throw({?MODULE, internal, <<"malformed binary metadata ", Name/binary>>, []})
    end.

-doc """
Add response headers, before the first response message goes out; a
`-bin` name's value is given as bytes and sent as base64.
""".
-spec set_headers(roadrunner_http:headers(), stream()) -> stream().
set_headers(Headers, #stream{headers = Own} = Stream) ->
    case get(?SEND_KEY) of
        undefined -> Stream#stream{headers = Own ++ wire(Headers)};
        _Send -> error(headers_already_sent)
    end.

-doc """
Compress the call's response messages with `Encoding` (`gzip` or
`deflate`), or not (`identity`), in place of the route's
`send_compression`; before the first response message, as the response's
headers say it. An encoding the client did not list in its
`grpc-accept-encoding` is not used: the messages go out uncompressed.
""".
-spec set_send_compression(encoding(), stream()) -> stream().
set_send_compression(Encoding, #stream{accepted = Accepted} = Stream) when
    Encoding =:= identity; Encoding =:= gzip; Encoding =:= deflate
->
    case get(?SEND_KEY) of
        undefined -> Stream#stream{send_encoding = sendable(Encoding, Accepted)};
        _Send -> error(headers_already_sent)
    end.

-doc """
Whether the message `recv/1` returned last came compressed, for a method
that checks how its client sends (gRPC's interop tests ask a server to);
`false` before the first.
""".
-spec recv_compressed(stream()) -> boolean().
recv_compressed(#stream{compressed = Compressed}) ->
    Compressed.

-doc """
Add trailers, sent after the status when the call ends; a `-bin` name's
value is given as bytes and sent as base64.
""".
-spec set_trailers(roadrunner_http:headers(), stream()) -> stream().
set_trailers(Trailers, #stream{trailers = Own} = Stream) ->
    Stream#stream{trailers = Own ++ wire(Trailers)}.

-spec wire(roadrunner_http:headers()) -> roadrunner_http:headers().
wire(Headers) ->
    [{own_name(Name), wire_value(Name, Value)} || {Name, Value} <- Headers].

%% A metadata name of the call's own: gRPC's Header-Name (one or more of
%% `0-9`, `a-z`, `_`, `-` and `.`, so lowercase and no pseudo-header), and
%% not one gRPC or HTTP/2 sets themselves.
-spec own_name(binary()) -> binary().
own_name(Name) ->
    case
        Name =/= <<>> andalso is_metadata_name(Name) andalso
            not lists:member(Name, [
                ~"content-type",
                ~"content-length",
                ~"te",
                ~"grpc-status",
                ~"grpc-message",
                ~"grpc-encoding",
                ~"grpc-accept-encoding",
                ~"grpc-timeout",
                ~"grpc-message-type"
            ])
    of
        true -> Name;
        false -> error({invalid_metadata, Name})
    end.

-spec is_metadata_name(binary()) -> boolean().
is_metadata_name(<<C, Rest/binary>>) when
    (C >= $a andalso C =< $z) orelse (C >= $0 andalso C =< $9) orelse
        C =:= $_ orelse C =:= $- orelse C =:= $.
->
    is_metadata_name(Rest);
is_metadata_name(<<>>) ->
    true;
is_metadata_name(_) ->
    false.

%% A value as sent: a `-bin` one in base64, any other gRPC's ASCII-Value
%% (printable ASCII, space included) with no space at either end (RFC 9113
%% §8.2.1).
-spec wire_value(binary(), binary()) -> binary().
wire_value(Name, Value) ->
    case binary:longest_common_suffix([Name, ~"-bin"]) of
        4 -> base64:encode(Value, #{padding => false});
        _ -> ascii_value(Name, Value)
    end.

-spec ascii_value(binary(), binary()) -> binary().
ascii_value(Name, Value) ->
    case is_ascii_value(Value) of
        true -> Value;
        false -> error({invalid_metadata, Name})
    end.

-spec is_ascii_value(binary()) -> boolean().
is_ascii_value(<<$\s, _/binary>>) -> false;
is_ascii_value(Value) -> is_printable(Value).

-spec is_printable(binary()) -> boolean().
is_printable(<<$\s>>) -> false;
is_printable(<<C, Rest/binary>>) when C >= 16#20, C =< 16#7E -> is_printable(Rest);
is_printable(<<>>) -> true;
is_printable(_) -> false.

-doc """
When the call's `grpc-timeout` runs out, in `erlang:monotonic_time(millisecond)`,
or `infinity` without one.
""".
-spec deadline(stream()) -> integer() | infinity.
deadline(#stream{deadline = Deadline}) ->
    Deadline.

%% The reflection service's index, from its route.
-doc false.
-spec reflection_index(stream()) -> roadrunner_grpc_reflection:index().
reflection_index(#stream{req = Req}) ->
    #route{reflection = Index} = roadrunner_req:state(Req),
    Index.

-doc "The client's address.".
-spec peer(stream()) -> {inet:ip_address(), inet:port_number()} | undefined.
peer(#stream{req = Req}) ->
    roadrunner_req:peer(Req).
