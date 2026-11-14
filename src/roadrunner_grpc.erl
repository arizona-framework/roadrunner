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

`routes/1` takes `services`, the service modules, and passes the rest to
every service's route; `init_route/1` checks them when the routes compile,
and a bad one stops the listener from starting:

- `codecs`: the `roadrunner_grpc_codec` modules the services speak, by
  default `[roadrunner_grpc_codec_raw]`
- `max_message_size`: the largest request message, in bytes, by default
  4 MiB, compressed and decompressed alike; a larger one ends the call
  with `RESOURCE_EXHAUSTED`
- `send_compression`: how the response messages are compressed, `gzip`,
  `deflate` or by default `identity`, none (see Compression)
- `max_content_length`: the most a call's requests may add up to, in bytes,
  for `routes/1` to set on each route in place of the listener's (10 MiB
  by default); past it the call ends with `RESOURCE_EXHAUSTED` with
  `manual` buffering, and with `auto` the request is answered `413`, as
  the body is read before the call starts. A client or
  bidi stream that lives long can carry more than that over its life, so
  set it to what such a call may total

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
unknown service, and `500` when a response header the method set cannot
be sent (a CR or LF in its value). An unknown method of a known service
is `UNIMPLEMENTED`, as is a `grpc-encoding` other than `identity`, `gzip`
and `deflate`.

A `grpc-timeout` is the call's deadline. A read still waiting then ends
the call with `DEADLINE_EXCEEDED`; a call still running a second later is
cancelled, as grpc-go does at the deadline: its stream is reset
(`RST_STREAM` with `CANCEL` over HTTP/2, `H3_REQUEST_CANCELLED` over
HTTP/3) and the method stops at its next write or read. Without a timeout
a call may run for as long as the client stays connected. With `auto` buffering the deadline counts from
when the body was read, a little after the client's.

## The method's process

`recv/1` waits for the next request, so a method cannot wait for other
messages at the same time; and the stream belongs to the call's process,
which is the one to `send/2`. A client that cancels the call (or goes
away) stops the method on its next write, quietly: there is no one left to
answer. A request that ends the call (too large, malformed, past its
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
is, to keep a secret out of a compressed stream.

## Metadata

`metadata/1` is the request's custom metadata, without the HTTP/2 and gRPC
headers; `set_headers/2` and `set_trailers/2` add the response's, with
lowercase names other than the ones gRPC sets (`grpc-status`, say), which
raise. A metadata name ending in `-bin` carries bytes: its value is base64
on the wire and plain bytes here, both ways; a request's comma-separated
values are each an entry, and one that is not base64 ends the call with
`INTERNAL` before the method runs.
""".

-behaviour(roadrunner_handler).

-export([routes/1, init_route/1, handle/1]).
-export([recv/1, send/2, send/3, metadata/1, set_headers/2, set_trailers/2, deadline/1, peer/1]).
-export([set_send_compression/2]).

-export_type([opts/0, status/0, stream/0, encoding/0]).

-define(MAX_MESSAGE_SIZE, 4194304).
%% Where the call's process keeps the response's body writer once it started.
-define(SEND_KEY, {?MODULE, send}).
%% Where it keeps the timer that cancels the call at its deadline.
-define(TIMER_KEY, {?MODULE, deadline_timer}).
%% How long after its deadline a call still running is cancelled. The
%% client stopped waiting at the deadline; the cancel ends the stream and
%% stops the method at its next write or read, after a read waiting at the
%% deadline had the time to answer.
-define(CANCEL_GRACE, 1000).
-define(OPTS, [service, codecs, max_message_size, send_compression]).

-doc """
The options `routes/1` takes: `services`, and the route options shared by
every service (see the moduledoc).
""".
-type opts() :: #{
    services := [module()],
    codecs => [module()],
    max_message_size => pos_integer(),
    max_content_length => non_neg_integer()
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
    service :: module(),
    rpcs :: #{binary() => {atom(), roadrunner_grpc_service:kind(), term(), term()}},
    codecs :: #{binary() => module()},
    max_message_size :: pos_integer(),
    send_compression :: encoding()
}).

-record(stream, {
    req :: roadrunner_req:request(),
    codec :: module(),
    content_type :: binary(),
    input :: term(),
    output :: term(),
    max_message_size :: pos_integer(),
    deadline :: integer() | infinity,
    %% The request's custom metadata, `-bin` values decoded.
    metadata = [] :: roadrunner_http:headers(),
    %% Request bytes read and not yet a whole message.
    buffer = <<>> :: binary(),
    %% Whether the request body has ended.
    eof = false :: boolean(),
    %% How the client compresses its messages (its `grpc-encoding`).
    recv_encoding = identity :: encoding(),
    %% How the response's messages are compressed, and the encodings the
    %% client reads (its `grpc-accept-encoding`).
    send_encoding = identity :: encoding(),
    accepted = [] :: [encoding()],
    headers = [] :: roadrunner_http:headers(),
    trailers = [] :: roadrunner_http:headers(),
    %% The response's body writer once its headers went out.
    send = undefined :: roadrunner_handler:send_fun() | undefined
}).

-opaque stream() :: #stream{}.

-doc "How a message is compressed: `identity` (not), `gzip` or `deflate`.".
-type encoding() :: identity | gzip | deflate.

-doc """
The routes for `Opts`'s `services`, one per service, at
`/package.Service/:method`: `max_content_length` set on each route, the
other options its state.
""".
-spec routes(opts()) -> roadrunner_router:routes().
routes(#{services := Services} = Opts) when is_list(Services) ->
    Shared = maps:without([services, max_content_length], Opts),
    Limits = maps:with([max_content_length], Opts),
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

-spec service_name(term(), [term()]) -> binary().
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
init_route(#{service := Service} = Opts) when is_atom(Service) ->
    ok = check_known_opts(Opts),
    case code:ensure_loaded(Service) of
        {module, Service} -> ok;
        {error, _} -> error({invalid_grpc_opt, service, Service})
    end,
    #route{
        service = Service,
        rpcs = rpcs(Service),
        codecs = codecs(maps:get(codecs, Opts, [roadrunner_grpc_codec_raw])),
        max_message_size = max_message_size(Opts),
        send_compression = send_compression(Opts)
    };
init_route(#{service := Service}) ->
    error({invalid_grpc_opt, service, Service});
init_route(Opts) ->
    error({invalid_grpc_opts, Opts}).

-spec check_known_opts(map()) -> ok.
check_known_opts(Opts) ->
    case [Key || Key <- maps:keys(Opts), not lists:member(Key, ?OPTS)] of
        [] -> ok;
        [Key | _] -> error({unknown_grpc_opt, Key})
    end.

-spec rpcs(module()) -> #{binary() => {atom(), roadrunner_grpc_service:kind(), term(), term()}}.
rpcs(Service) ->
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
        case Service:rpcs() of
            Rpcs when is_map(Rpcs) -> Rpcs;
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

%% The call, on the request's process: its checks ahead of the method,
%% then the method, then the status that ends it.
-spec call(roadrunner_req:request(), binary(), module(), #route{}) -> roadrunner_req:request().
call(Req, ContentType, Codec, #route{service = Service, rpcs = Rpcs} = Route) ->
    #{~"method" := Method} = roadrunner_req:bindings(Req),
    Stream0 = #stream{
        req = Req,
        codec = Codec,
        content_type = ContentType,
        input = undefined,
        output = undefined,
        max_message_size = Route#route.max_message_size,
        deadline = infinity
    },
    try
        {Function, Kind, In, Out} = rpc(Method, Rpcs),
        RecvEncoding = recv_encoding(roadrunner_req:header(~"grpc-encoding", Req)),
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
            deadline = deadline_after(Timeout, Req)
        },
        finish(run(Kind, Service, Function, Stream))
    catch
        throw:{?MODULE, Status, Message, Headers, Thrown} ->
            finish({error, Status, Message, add_headers(Headers, Thrown)});
        throw:{?MODULE, Status, Message, Headers} ->
            finish({error, Status, Message, add_headers(Headers, Stream0)})
    end.

-spec rpc(binary(), map()) -> {atom(), roadrunner_grpc_service:kind(), term(), term()}.
rpc(Method, Rpcs) ->
    case Rpcs of
        #{Method := Rpc} -> Rpc;
        #{} -> throw({?MODULE, unimplemented, <<"unknown method ", Method/binary>>, []})
    end.

%% The client's `grpc-encoding`: one roadrunner reads, or the call ends
%% `UNIMPLEMENTED` naming the ones it does (gRPC's compression.md).
-spec recv_encoding(binary() | undefined) -> encoding().
recv_encoding(undefined) ->
    identity;
recv_encoding(Encoding) ->
    case encoding(Encoding) of
        unknown ->
            Supported = roadrunner_grpc_compress:encodings(),
            throw(
                {?MODULE, unimplemented,
                    <<"unsupported grpc-encoding ", Encoding/binary, "; supported: ",
                        Supported/binary>>,
                    []}
            );
        Known ->
            Known
    end.

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
%% and the method stops at its next write or read. The timer is cancelled when the call ends before
%% (`ended/1`).
-spec deadline_after(non_neg_integer() | infinity, roadrunner_req:request()) ->
    integer() | infinity.
deadline_after(infinity, _Req) ->
    infinity;
deadline_after(Ms, Req) ->
    %% A call runs over HTTP/2 or HTTP/3 (`handle/1` answers HTTP/1.1 with
    %% 505), both of which can cancel a stream.
    {ok, Timer} = roadrunner_send_writer:cancel_after(Ms + ?CANCEL_GRACE, Req),
    _ = put(?TIMER_KEY, Timer),
    erlang:monotonic_time(millisecond) + Ms.

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

-spec ended(roadrunner_req:request()) -> roadrunner_req:request().
ended(Req) ->
    _ = erase(?SEND_KEY),
    _ =
        case erase(?TIMER_KEY) of
            undefined -> ok;
            Timer -> erlang:cancel_timer(Timer, [{async, true}, {info, false}])
        end,
    Req.

-spec finish(status(), binary(), stream()) -> roadrunner_req:request().
finish(Status, Message, #stream{send = undefined} = Stream) ->
    %% The method may have started the response on a stream it then lost,
    %% crashing or aborting: the writer is kept where the call can find it.
    case get(?SEND_KEY) of
        undefined -> trailers_only(Status, Message, Stream);
        {Send, _Encoding} -> finish(Status, Message, Stream#stream{send = Send})
    end;
finish(Status, Message, #stream{send = Send, req = Req} = Stream) ->
    ok = written(Send(<<>>, {fin, status_headers(Status, Message, Stream)})),
    Req.

%% A call that ends before any response: the status in the response
%% headers, a single HEADERS frame that ends the stream.
-spec trailers_only(status(), binary(), stream()) -> roadrunner_req:request().
trailers_only(Status, Message, #stream{req = Req} = Stream) ->
    Headers = response_headers(Stream) ++ status_headers(Status, Message, Stream),
    ok = written(roadrunner_send:reply(200, Headers, <<>>, Req)),
    Req.

%% A write that could not go out stops the call: the client is gone, or a
%% header the connection refused (a CR or LF in a value) has the response
%% answered `500` in its place.
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
            {ok, decode(Bytes, Stream), Stream#stream{buffer = Rest}};
        {ok, true, _Bytes, _Rest} when Stream#stream.recv_encoding =:= identity ->
            abort(internal, ~"compressed message without a grpc-encoding to read it", Stream);
        {ok, true, Compressed, Rest} ->
            Bytes = decompressed(Compressed, Stream),
            {ok, decode(Bytes, Stream), Stream#stream{buffer = Rest}};
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
    case roadrunner_req:read_body(Req, #{length => missing(Buffer)}) of
        {more, Bytes, Req1} ->
            recv(Stream#stream{
                req = Req1, buffer = <<Buffer/binary, (iolist_to_binary(Bytes))/binary>>
            });
        {ok, Bytes, Req1} ->
            recv(Stream#stream{
                req = Req1, buffer = <<Buffer/binary, (iolist_to_binary(Bytes))/binary>>, eof = true
            });
        {error, request_timeout} ->
            abort(deadline_exceeded, ~"deadline exceeded", Stream);
        {error, content_length_too_large} ->
            abort(resource_exhausted, ~"request body over the route's max_content_length", Stream);
        {error, Reason} ->
            exit({shutdown, {grpc_recv, Reason}})
    end.

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

-doc "Add trailers, sent after the status when the call ends.".
-spec set_trailers(roadrunner_http:headers(), stream()) -> stream().
set_trailers(Trailers, #stream{trailers = Own} = Stream) ->
    Stream#stream{trailers = Own ++ wire(Trailers)}.

-spec wire(roadrunner_http:headers()) -> roadrunner_http:headers().
wire(Headers) ->
    [{own_name(Name), wire_value(Name, Value)} || {Name, Value} <- Headers].

%% A metadata name of the call's own: lowercase (RFC 9113 §8.2.1) and not one
%% gRPC or HTTP/2 sets themselves.
-spec own_name(binary()) -> binary().
own_name(<<":", _/binary>> = Name) ->
    error({invalid_metadata, Name});
own_name(Name) ->
    case
        roadrunner_bin:ascii_lowercase(Name) =:= Name andalso
            not lists:member(Name, [
                ~"content-type",
                ~"content-length",
                ~"te",
                ~"grpc-status",
                ~"grpc-message",
                ~"grpc-encoding",
                ~"grpc-accept-encoding",
                ~"grpc-timeout"
            ])
    of
        true -> Name;
        false -> error({invalid_metadata, Name})
    end.

-spec wire_value(binary(), binary()) -> binary().
wire_value(Name, Value) ->
    case binary:longest_common_suffix([Name, ~"-bin"]) of
        4 -> base64:encode(Value, #{padding => false});
        _ -> Value
    end.

-doc """
When the call's `grpc-timeout` runs out, in `erlang:monotonic_time(millisecond)`,
or `infinity` without one.
""".
-spec deadline(stream()) -> integer() | infinity.
deadline(#stream{deadline = Deadline}) ->
    Deadline.

-doc "The client's address.".
-spec peer(stream()) -> {inet:ip_address(), inet:port_number()} | undefined.
peer(#stream{req = Req}) ->
    roadrunner_req:peer(Req).
