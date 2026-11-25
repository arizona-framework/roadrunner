-module(roadrunner_grpc_client).
-moduledoc """
A small gRPC client over HTTP/2, for tests, tooling and simple
service-to-service calls.

It speaks to any gRPC server, roadrunner's own included: the four call
kinds, metadata both ways, status codes, deadlines, cancellation and
message compression. It is not a full production client: see
[Limitations](#module-limitations) for what it leaves out.

## Connecting

`connect/3` opens one HTTP/2 connection. Without `tls` it speaks
cleartext HTTP/2 with prior knowledge (h2c), as gRPC clients do for an
insecure channel; with `tls` it speaks HTTP/2 over TLS and needs the
server to agree on `h2` through ALPN.

```erlang
{ok, Conn} = roadrunner_grpc_client:connect("localhost", 50051, #{}),
...
ok = roadrunner_grpc_client:close(Conn).
```

The connection is a process of its own, which multiplexes every call on
it. It belongs to the process that called `connect/3`: it closes when
that process exits. Any process may make calls on it meanwhile.

Options (`t:connect_opts/0`):

- `tls`: `ssl` client options; leave it out for cleartext h2c. The
  client adds `{alpn_advertised_protocols, [~"h2"]}` itself
- `codec`: the `roadrunner_grpc_codec` that turns messages into bytes
  and back, by default `roadrunner_grpc_codec_raw` (messages as bytes).
  Its subtype picks the `content-type`: `proto` sends
  `application/grpc`, any other `application/grpc+Subtype`
- `compression`: how calls compress their messages by default,
  `identity` (the default), `gzip` or `deflate`
- `max_message_size`: the largest response message, in bytes, both as
  it arrives and after it is decompressed; by default 4 MiB. A larger
  one ends the call with `RESOURCE_EXHAUSTED`
- `connect_timeout`: how long to wait for the connection, the TLS
  handshake and the server's first SETTINGS frame, in milliseconds;
  by default 5000
- `authority`: the `:authority` of every call, by default `Host:Port`
- `max_header_list_size`: the largest response header list (or trailer
  list) the client takes, counted as HTTP/2 counts it (each field's name
  and value plus 32 bytes); by default 64 KiB. The client tells the server
  (SETTINGS_MAX_HEADER_LIST_SIZE), and a larger list ends the call with
  `RESOURCE_EXHAUSTED`

A bad option raises `{invalid_grpc_opt, Key, Value}` or
`{unknown_grpc_opt, Key}`.

## Unary calls

`unary/4` sends one request and returns the one reply, with the
response's headers and trailers metadata:

```erlang
{ok, Reply, #{headers := Headers, trailers := Trailers}} =
    roadrunner_grpc_client:unary(Conn, ~"/helloworld.Greeter/SayHello", ~"world", #{
        timeout => 1000,
        metadata => [{~"x-request-id", ~"42"}, {~"x-trace-bin", <<1, 2, 3>>}]
    }).
```

A call that ends with a status other than `OK` returns
`{error, {grpc, Status, Message, Trailers}}`, `Status` an atom of
`t:roadrunner_grpc:status/0`:

```erlang
{error, {grpc, not_found, ~"no user 42", _Trailers}} =
    roadrunner_grpc_client:unary(Conn, ~"/users.Users/Get", ~"42", #{}).
```

Call options (`t:call_opts/0`):

- `input`, `output`: the message types, passed to the codec's
  `encode/2` and `decode/2`; the raw codec ignores them
- `metadata`: `{Name, Value}` pairs sent as request headers. A name
  ending in `-bin` carries bytes, sent as base64. Names are made of
  `0-9`, `a-z`, `_`, `-` and `.`, and cannot be one gRPC or HTTP/2 sets
  itself; other values are printable ASCII with no space at either end.
  Anything else raises `{invalid_metadata, Name}`
- `timeout`: the call's deadline, in milliseconds from now, or
  `infinity` (the default). It goes to the server as `grpc-timeout`,
  and the client ends the call itself when it passes: the call ends
  with `DEADLINE_EXCEEDED` and its stream is reset
- `compression`: `identity`, `gzip` or `deflate`, in place of the
  connection's
- `codec`: a codec in place of the connection's

## Streaming calls

`stream/3` starts a call of any kind and returns its stream. Send
requests with `send/2`, end them with `close_send/1`, and read
responses with `recv/1,2` until it returns the end of the call:

- `{ok, Message}`: the next response message
- `{eof, Trailers}`: the call ended with `OK`, with its trailers
  metadata
- `{error, Error}`: the call ended otherwise (see Errors)

A server stream:

```erlang
{ok, S} = roadrunner_grpc_client:stream(Conn, ~"/test.Numbers/Count", #{}),
ok = roadrunner_grpc_client:send(S, ~"3"),
ok = roadrunner_grpc_client:close_send(S),
{ok, ~"1"} = roadrunner_grpc_client:recv(S),
{ok, ~"2"} = roadrunner_grpc_client:recv(S),
{ok, ~"3"} = roadrunner_grpc_client:recv(S),
{eof, _Trailers} = roadrunner_grpc_client:recv(S).
```

A bidirectional stream, each request answered before the next goes out:

```erlang
{ok, S} = roadrunner_grpc_client:stream(Conn, ~"/test.Chat/Talk", #{timeout => 5000}),
ok = roadrunner_grpc_client:send(S, ~"hello"),
{ok, Answer} = roadrunner_grpc_client:recv(S, 1000),
ok = roadrunner_grpc_client:close_send(S),
{eof, _} = roadrunner_grpc_client:recv(S).
```

- `recv/2` waits at most its timeout: `{error, timeout}` then leaves
  the call running, to read again later. `recv/1` waits until the next
  message or the end of the call
- `headers/1,2` waits for the response headers and returns their
  metadata: `{ok, []}` when the server answered with the status alone
  (gRPC's Trailers-Only form), the call's error when it ended without
  any
- `send/3` with `#{compress => false}` sends one message uncompressed in
  a compressed call
- `send/2` returns once the message is on the wire, which waits for the
  server's flow control: a server that stops reading holds it until the
  call's `timeout`. It returns `{error, closed}` once the call is over
  (`recv/1` then tells how it ended) or after `close_send/1`
- `cancel/1` ends the call at once: the client resets its stream
  (`CANCEL`), and the server learns the call was cancelled
- once `recv/1` returned the end of the call, the stream is gone, and
  later reads return `{error, closed}`. Read every call to its end, or
  cancel it: a call ended but never read keeps its place on the
  connection
- read a stream from one process at a time: while a `recv` or `headers`
  waits, another one on the same stream returns `{error, busy}` at once
- if the process that started a call exits, the call is cancelled

## Errors

`{grpc, Status, Message, Trailers}` is a call that ended with a status
other than `OK`: the server's (with its `grpc-message`, decoded, and
trailers metadata), or one the client sets itself, with no trailers:

- `deadline_exceeded`: the call's `timeout` passed
- `cancelled`: the call was cancelled (`cancel/1`)
- `resource_exhausted`: a response message over `max_message_size`, or
  a response header list over `max_header_list_size`
- `internal`: a response gRPC does not allow: a message that does not
  decompress or decode, a stream that ended without trailers or in the
  middle of a message, a unary call with no reply or more than one (an
  `OK` status with no message, from whatever HTTP status, included), and
  HTTP `400`
- `unknown`: trailers with no `grpc-status`, or one gRPC does not define,
  and a response that is not `application/grpc`
- `unimplemented`, `unauthenticated`, `permission_denied`,
  `unavailable`: an answer that is not gRPC, by its HTTP status, as gRPC
  maps them (`404` is `unimplemented`; `502`, `503`, `504` and `429` are
  `unavailable`; any other is `unknown`). An answer that is not `200` but
  carries a `grpc-status` ends with that status instead. Interim (`1xx`)
  responses are skipped

The others come from the connection:

- `closed`: the connection closed before the call ended, or it has used
  all its stream ids (about a billion calls) and takes no new call
- `{goaway, Code}`: the server shut the connection down (HTTP/2 GOAWAY)
  before it took the call; safe to retry on a new connection
- `{reset, Code}`: the server reset the call's stream (HTTP/2
  RST_STREAM), `Code` an HTTP/2 error code such as `cancel`
- `{connection_error, Code}`: the server broke the HTTP/2 protocol, so
  the client closed the connection
- `timeout`: a `recv/2` or `headers/2` wait ran out; the call goes on
- `busy`: another `recv` or `headers` on the same stream is waiting

## TLS

```erlang
{ok, Conn} = roadrunner_grpc_client:connect("api.example.com", 443, #{
    tls => [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}]
}).
```

Without an ALPN agreement on `h2`, `connect/3` returns
`{error, h2_not_negotiated}`.

## Protocol Buffers

Give the call's message types to a Protocol Buffers codec, such as the
one in the
[`roadrunner_grpc_protobuf`](https://github.com/arizona-framework/roadrunner_grpc_protobuf)
package, as `codec` and `input`/`output`; its README shows how.

## Limitations

This client is meant for tests, tooling and simple calls. It does not do
what a production gRPC client does:

- no HTTP/3: HTTP/2 only, over TLS or cleartext h2c
- no reconnect or backoff: a closed connection stays closed; open a new
  one
- no keepalive pings: an idle connection a server or a network drops is
  only noticed by the next call
- no name resolution or load balancing: one connection to one address
- no retries, hedging or service config
- no connection pooling: one connection, with every call multiplexed on
  it, and no move to a new connection after a GOAWAY
- no client-side interceptors
- no client telemetry events
- fixed flow-control windows (1 MiB for each call, 4 MiB for the
  connection), with no tuning to the network
- response header lists are capped at `max_header_list_size` (64 KiB by
  default); interim (`1xx`) responses are skipped
- one reader per stream: a second `recv` or `headers` waiting on the same
  stream returns `{error, busy}`
- lenient on closed streams: frames the server sends on a stream that
  already ended are ignored, where RFC 9113 §5.1 lets a client treat some
  of them as an error (`STREAM_CLOSED`)
- one connection carries at most 2^30 calls, its HTTP/2 stream ids; past
  them new calls return `{error, closed}`
""".

-export([connect/3, close/1]).
-export([unary/3, unary/4]).
-export([stream/2, stream/3, send/2, send/3, close_send/1]).
-export([recv/1, recv/2, headers/1, headers/2, cancel/1]).

%% proc_lib entry point of the connection process.
-export([init/4]).

-export_type([
    conn/0,
    stream/0,
    connect_opts/0,
    call_opts/0,
    send_opts/0,
    encoding/0,
    h2_error_code/0,
    metadata/0,
    meta/0,
    error/0
]).

%% RFC 9113 §3.4 connection preface.
-define(PREFACE, ~"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").
-define(MAX_WINDOW, 16#7FFFFFFF).
-define(MAX_TABLE, 4096).
-define(MAX_MESSAGE, 4_194_304).
-define(CONNECT_TIMEOUT, 5000).
%% The longest `timeout`, the most a `receive` can wait (about 49 days).
-define(MAX_TIMEOUT, 16#FFFFFFFF).
%% The default SETTINGS_MAX_HEADER_LIST_SIZE the client advertises.
-define(MAX_HEADER_LIST, 65_536).
%% The highest stream id (RFC 9113 §5.1.1).
-define(MAX_STREAM_ID, 16#7FFFFFFF).

-define(END_STREAM, 16#01).
-define(END_HEADERS, 16#04).

-record(grpc_conn, {
    pid :: pid(),
    scheme :: binary(),
    authority :: binary(),
    codec :: module(),
    compression :: encoding(),
    max :: non_neg_integer(),
    user_agent :: binary()
}).

-record(grpc_stream, {
    pid :: pid(),
    ref :: reference(),
    codec :: module(),
    input :: term(),
    output :: term(),
    compression :: encoding(),
    max :: non_neg_integer()
}).

-doc "A connection, from `connect/3`.".
-opaque conn() :: #grpc_conn{}.
-doc "A call's stream, from `stream/3`.".
-opaque stream() :: #grpc_stream{}.

-doc "A message compression.".
-type encoding() :: identity | gzip | deflate.

-doc "`connect/3` options; see the module documentation.".
-type connect_opts() :: #{
    tls => [ssl:tls_client_option()],
    codec => module(),
    compression => encoding(),
    max_message_size => non_neg_integer(),
    connect_timeout => timeout(),
    authority => binary(),
    max_header_list_size => pos_integer()
}.

-doc "Call options; see the module documentation.".
-type call_opts() :: #{
    input => term(),
    output => term(),
    metadata => metadata(),
    timeout => timeout(),
    compression => encoding(),
    codec => module()
}.

-doc "`send/3` options: `compress => false` sends the message uncompressed.".
-type send_opts() :: #{compress => boolean()}.

-doc """
Metadata as `{Name, Value}` pairs, names lowercase; a `-bin` name's value
is plain bytes.
""".
-type metadata() :: [{Name :: binary(), Value :: binary()}].

-doc "A unary reply's response headers and trailers metadata.".
-type meta() :: #{headers := metadata(), trailers := metadata()}.

-doc "How a call can fail; see the module documentation's Errors.".
-type error() ::
    {grpc, roadrunner_grpc:status(), Message :: binary(), Trailers :: metadata()}
    | closed
    | timeout
    | busy
    | {goaway, h2_error_code()}
    | {reset, h2_error_code()}
    | {connection_error, h2_error_code()}.

-doc "An HTTP/2 error code (RFC 9113 §7), by name; one not named is its number.".
-type h2_error_code() ::
    no_error
    | protocol_error
    | internal_error
    | flow_control_error
    | settings_timeout
    | stream_closed
    | frame_size_error
    | refused_stream
    | cancel
    | compression_error
    | connect_error
    | enhance_your_calm
    | inadequate_security
    | http_1_1_required
    | non_neg_integer().

-include("roadrunner_grpc_client.hrl").

%% =============================================================================
%% Public API
%% =============================================================================

-doc """
Open a connection to a gRPC server. See the module documentation for the
options. Returns `{error, Reason}` when the connection fails: the socket's
or the TLS handshake's reason, `timeout` past `connect_timeout`,
`h2_not_negotiated` when TLS did not agree on `h2`, `closed` when the
server closed before its SETTINGS, or `{connection_error, protocol_error}`
when it answered with something other than SETTINGS.
""".
-spec connect(inet:hostname() | inet:ip_address() | binary(), inet:port_number(), connect_opts()) ->
    {ok, conn()} | {error, term()}.
connect(Host, Port, Opts) when is_map(Opts) ->
    ok = check_opts(Opts, fun connect_opt/2),
    Authority = opt(authority, Opts, authority(Host, Port)),
    UserAgent = user_agent(),
    Timeout = opt(connect_timeout, Opts, ?CONNECT_TIMEOUT),
    case proc_lib:start(?MODULE, init, [self(), Host, Port, Opts], Timeout) of
        {ok, Pid} ->
            {ok, #grpc_conn{
                pid = Pid,
                scheme = scheme(Opts),
                authority = Authority,
                codec = opt(codec, Opts, roadrunner_grpc_codec_raw),
                compression = opt(compression, Opts, identity),
                max = opt(max_message_size, Opts, ?MAX_MESSAGE),
                user_agent = UserAgent
            }};
        {error, _} = Error ->
            Error
    end.

-doc """
Close the connection: the calls still on it end with `closed`. Closing a
connection already closed does nothing.
""".
-spec close(conn()) -> ok.
close(#grpc_conn{pid = Pid}) ->
    _ = request(Pid, close, infinity, undefined),
    ok.

-doc "`unary/4` with no options.".
-spec unary(conn(), binary(), term()) -> {ok, term(), meta()} | {error, error()}.
unary(Conn, Path, Request) ->
    unary(Conn, Path, Request, #{}).

-doc """
A unary call to `Path` (`/package.Service/Method`): send `Request`, wait for
the one reply. Returns the reply with the response's headers and trailers
metadata, or the call's error.
""".
-spec unary(conn(), binary(), term(), call_opts()) ->
    {ok, term(), meta()} | {error, error()}.
unary(Conn, Path, Request, Opts) ->
    case open(Conn, Path, Opts, {value, Request}) of
        {ok, Stream} ->
            Headers =
                case headers(Stream) of
                    {ok, H} -> H;
                    {error, _} -> []
                end,
            unary_reply(Stream, Headers, recv(Stream), none);
        {error, _} = Error ->
            Error
    end.

-spec unary_reply(stream(), metadata(), Recv, none | {value, term()}) ->
    {ok, term(), meta()} | {error, error()}
when
    Recv :: {ok, term()} | {eof, metadata()} | {error, error()}.
unary_reply(Stream, Headers, {ok, Reply}, none) ->
    unary_reply(Stream, Headers, recv(Stream), {value, Reply});
unary_reply(Stream, _Headers, {ok, _}, {value, _}) ->
    abort(Stream, internal, ~"more than one response message for a unary call");
unary_reply(_Stream, Headers, {eof, Trailers}, {value, Reply}) ->
    {ok, Reply, #{headers => Headers, trailers => Trailers}};
unary_reply(_Stream, _Headers, {eof, Trailers}, none) ->
    {error, {grpc, internal, ~"no response message for a unary call", Trailers}};
unary_reply(_Stream, _Headers, {error, _} = Error, _Reply) ->
    Error.

-doc "`stream/3` with no options.".
-spec stream(conn(), binary()) -> {ok, stream()} | {error, error()}.
stream(Conn, Path) ->
    stream(Conn, Path, #{}).

-doc """
Start a call to `Path` (`/package.Service/Method`) of any kind, and return
its stream. Returns `{error, {goaway, Code}}` once the server shut the
connection down, and `{error, closed}` once it is closed.

When the server's `SETTINGS_MAX_CONCURRENT_STREAMS` is reached, the call
waits for a slot before it goes out; its `timeout` counts from now.
""".
-spec stream(conn(), binary(), call_opts()) -> {ok, stream()} | {error, error()}.
stream(Conn, Path, Opts) ->
    open(Conn, Path, Opts, none).

-doc "`send/3` with no options.".
-spec send(stream(), term()) -> ok | {error, closed}.
send(Stream, Message) ->
    send(Stream, Message, #{}).

-doc """
Send one request message, and return once it is on the wire. With
`#{compress => false}` the message goes out uncompressed, whatever the
call's compression. Returns `{error, closed}` once the call is over or
after `close_send/1`.
""".
-spec send(stream(), term(), send_opts()) -> ok | {error, closed}.
send(#grpc_stream{pid = Pid, ref = Ref} = Stream, Message, Opts) when is_map(Opts) ->
    ok = check_opts(Opts, fun send_opt/2),
    Frame = iolist_to_binary(frame_message(Stream, Message, Opts)),
    request(Pid, {send, Ref, Frame, false}, infinity, Ref).

-doc """
End the requests (HTTP/2 END_STREAM), as a client-streaming or
bidirectional call does when it has sent them all; the responses go on.
""".
-spec close_send(stream()) -> ok | {error, closed}.
close_send(#grpc_stream{pid = Pid, ref = Ref}) ->
    request(Pid, {send, Ref, <<>>, true}, infinity, Ref).

-doc "`recv/2` waiting for as long as it takes.".
-spec recv(stream()) -> {ok, term()} | {eof, metadata()} | {error, error()}.
recv(Stream) ->
    recv(Stream, infinity).

-doc """
The next response message, or the end of the call: `{eof, Trailers}` when
it ended `OK`, `{error, Error}` otherwise. `{error, timeout}` when nothing
came within `Timeout` milliseconds; the call goes on.
""".
-spec recv(stream(), timeout()) -> {ok, term()} | {eof, metadata()} | {error, error()}.
recv(#grpc_stream{pid = Pid, ref = Ref} = Stream, Timeout) ->
    case request(Pid, {recv, Ref, message}, Timeout, Ref) of
        {message, Encoding, Bytes} -> message(Encoding, Bytes, Stream);
        End -> End
    end.

-doc "`headers/2` waiting for as long as it takes.".
-spec headers(stream()) -> {ok, metadata()} | {error, error()}.
headers(Stream) ->
    headers(Stream, infinity).

-doc """
The response headers' metadata, once they arrive: `{ok, []}` when the
server answered with its status alone (Trailers-Only), the call's error
when it ended without headers. `{error, timeout}` when they did not come
within `Timeout` milliseconds.
""".
-spec headers(stream(), timeout()) -> {ok, metadata()} | {error, error()}.
headers(#grpc_stream{pid = Pid, ref = Ref}, Timeout) ->
    request(Pid, {recv, Ref, headers}, Timeout, Ref).

-doc """
Cancel the call: its stream is reset with `CANCEL` and the stream is gone.
Cancelling a call that ended does nothing.
""".
-spec cancel(stream()) -> ok.
cancel(#grpc_stream{pid = Pid, ref = Ref}) ->
    _ = request(Pid, {cancel, Ref}, infinity, Ref),
    ok.

%% =============================================================================
%% The caller's side
%% =============================================================================

%% Start a call: the request headers are built here, in the caller, and a
%% unary call's request goes along with them, its requests ended.
-spec open(conn(), binary(), call_opts(), none | {value, term()}) ->
    {ok, stream()} | {error, error()}.
open(
    #grpc_conn{pid = Pid, scheme = Scheme, authority = Authority, max = Max} = Conn,
    Path,
    Opts,
    Request
) when is_binary(Path), is_map(Opts) ->
    ok = check_opts(Opts, fun call_opt/2),
    #grpc_conn{codec = DefaultCodec, compression = DefaultCompression, user_agent = UserAgent} =
        Conn,
    Codec = opt(codec, Opts, DefaultCodec),
    Compression = opt(compression, Opts, DefaultCompression),
    Ref = make_ref(),
    Stream = #grpc_stream{
        pid = Pid,
        ref = Ref,
        codec = Codec,
        input = opt(input, Opts, undefined),
        output = opt(output, Opts, undefined),
        compression = Compression,
        max = Max
    },
    %% In gRPC's order (PROTOCOL-HTTP2): the call's definition, then its
    %% custom metadata; the connection puts `grpc-timeout` after `te`.
    Head = [
        {~":method", ~"POST"},
        {~":scheme", Scheme},
        {~":path", Path},
        {~":authority", Authority},
        {~"te", ~"trailers"}
    ],
    Tail = [
        {~"content-type", content_type(Codec:subtype())}
        | encoding_field(Compression, [
            {~"grpc-accept-encoding", roadrunner_grpc_compress:encodings()},
            {~"user-agent", UserAgent}
            | wire(opt(metadata, Opts, []))
        ])
    ],
    Out =
        case Request of
            none -> [];
            {value, Message} -> [iolist_to_binary(frame_message(Stream, Message, #{}))]
        end,
    case
        request(Pid, {open, Ref, {Head, Tail}, opt(timeout, Opts, infinity), Out}, infinity, Ref)
    of
        ok -> {ok, Stream};
        {error, _} = Error -> Error
    end.

-spec content_type(binary()) -> binary().
content_type(~"proto") -> ~"application/grpc";
content_type(Subtype) -> <<"application/grpc+", Subtype/binary>>.

-spec encoding_field(encoding(), metadata()) -> metadata().
encoding_field(identity, Metadata) -> Metadata;
encoding_field(Encoding, Metadata) -> [{~"grpc-encoding", atom_to_binary(Encoding)} | Metadata].

%% A request message, encoded, compressed as the call says, and framed.
-spec frame_message(stream(), term(), send_opts()) -> iodata().
frame_message(#grpc_stream{codec = Codec, input = Input, compression = Compression}, Message, Opts) ->
    Bytes = Codec:encode(Input, Message),
    case {Compression, Opts} of
        {identity, _} ->
            roadrunner_grpc_frame:encode(false, Bytes);
        {_, #{compress := false}} ->
            roadrunner_grpc_frame:encode(false, Bytes);
        {Encoding, _} ->
            roadrunner_grpc_frame:encode(true, roadrunner_grpc_compress:compress(Encoding, Bytes))
    end.

%% A response message as the connection handed it over: decompressed
%% within the size limit, then decoded. A message that does neither ends
%% the call.
-spec message(gzip | deflate | identity | unsupported, binary(), stream()) ->
    {ok, term()} | {error, error()}.
message(identity, Bytes, Stream) ->
    decode(Bytes, Stream);
message(Encoding, Bytes, #grpc_stream{max = Max} = Stream) when
    Encoding =:= gzip; Encoding =:= deflate
->
    case roadrunner_grpc_compress:decompress(Encoding, Bytes, Max) of
        {ok, Plain} ->
            decode(Plain, Stream);
        {error, too_large} ->
            abort(Stream, resource_exhausted, ~"decompressed message larger than max_message_size");
        {error, malformed} ->
            abort(Stream, internal, ~"message does not decompress")
    end;
message(unsupported, _Bytes, Stream) ->
    abort(Stream, internal, ~"compressed message without a supported grpc-encoding").

%% The codec's `decode/2` raises on bytes that hold no message: the
%% server's bytes are not to be trusted, so that ends the call.
-spec decode(binary(), stream()) -> {ok, term()} | {error, error()}.
decode(Bytes, #grpc_stream{codec = Codec, output = Output} = Stream) ->
    try Codec:decode(Output, Bytes) of
        Message -> {ok, Message}
    catch
        _:_ -> abort(Stream, internal, ~"message does not decode")
    end.

%% End the call from this side: reset its stream and give the error.
-spec abort(stream(), roadrunner_grpc:status(), binary()) -> {error, error()}.
abort(Stream, Status, Message) ->
    ok = cancel(Stream),
    {error, {grpc, Status, Message, []}}.

%% Ask the connection, and wait for its answer. When the wait runs out the
%% request is withdrawn; the connection then answers `withdrawn`, unless
%% its answer went out first, which is taken.
-spec request(pid(), term(), timeout(), reference() | undefined) -> term().
request(Pid, Request, Timeout, StreamRef) ->
    Mon = erlang:monitor(process, Pid),
    Pid ! {?MODULE, self(), Mon, Request},
    await(Pid, Mon, Timeout, StreamRef).

-spec await(pid(), reference(), timeout(), reference() | undefined) -> term().
await(Pid, Mon, Timeout, StreamRef) ->
    receive
        {Mon, Reply} ->
            erlang:demonitor(Mon, [flush]),
            reply(Reply);
        {'DOWN', Mon, process, _, _} ->
            {error, closed}
    after Timeout ->
        Pid ! {?MODULE, self(), Mon, {withdraw, StreamRef}},
        await(Pid, Mon, infinity, StreamRef)
    end.

-spec reply(term()) -> term().
reply(withdrawn) -> {error, timeout};
reply(Reply) -> Reply.

%% =============================================================================
%% Options
%% =============================================================================

-spec check_opts(map(), fun((term(), term()) -> boolean() | unknown)) -> ok.
check_opts(Opts, Check) ->
    maps:foreach(
        fun(Key, Value) ->
            case Check(Key, Value) of
                true -> ok;
                false -> error({invalid_grpc_opt, Key, Value});
                unknown -> error({unknown_grpc_opt, Key})
            end
        end,
        Opts
    ).

-spec connect_opt(term(), term()) -> boolean() | unknown.
connect_opt(tls, Value) -> is_list(Value);
connect_opt(codec, Value) -> is_atom(Value);
connect_opt(compression, Value) -> is_encoding(Value);
connect_opt(max_message_size, Value) -> is_integer(Value) andalso Value >= 0;
connect_opt(connect_timeout, Value) -> is_timeout(Value);
connect_opt(authority, Value) -> is_binary(Value);
connect_opt(max_header_list_size, Value) -> is_integer(Value) andalso Value > 0;
connect_opt(_Key, _Value) -> unknown.

-spec call_opt(term(), term()) -> boolean() | unknown.
call_opt(input, _Value) -> true;
call_opt(output, _Value) -> true;
call_opt(metadata, Value) -> is_list(Value);
call_opt(timeout, Value) -> is_timeout(Value);
call_opt(compression, Value) -> is_encoding(Value);
call_opt(codec, Value) -> is_atom(Value);
call_opt(_Key, _Value) -> unknown.

-spec send_opt(term(), term()) -> boolean() | unknown.
send_opt(compress, Value) -> is_boolean(Value);
send_opt(_Key, _Value) -> unknown.

-spec is_encoding(term()) -> boolean().
is_encoding(Value) ->
    Value =:= identity orelse Value =:= gzip orelse Value =:= deflate.

-spec is_timeout(term()) -> boolean().
is_timeout(Value) ->
    Value =:= infinity orelse
        (is_integer(Value) andalso Value >= 0 andalso Value =< ?MAX_TIMEOUT).

-spec opt(atom(), map(), term()) -> term().
opt(Key, Opts, Default) ->
    case Opts of
        #{Key := Value} -> Value;
        #{} -> Default
    end.

%% gRPC's User-Agent: `grpc-erlang-roadrunner/` and roadrunner's version.
-spec user_agent() -> binary().
user_agent() ->
    _ = application:load(roadrunner),
    {ok, Vsn} = application:get_key(roadrunner, vsn),
    iolist_to_binary(["grpc-erlang-roadrunner/", Vsn]).

-spec scheme(connect_opts()) -> binary().
scheme(#{tls := _}) -> ~"https";
scheme(#{}) -> ~"http".

-spec authority(inet:hostname() | inet:ip_address() | binary(), inet:port_number()) -> binary().
authority(Host, Port) ->
    iolist_to_binary([host_text(Host), $:, integer_to_binary(Port)]).

-spec host_text(inet:hostname() | inet:ip_address() | binary()) -> iodata().
host_text(Host) when is_binary(Host) -> Host;
host_text(Host) when is_atom(Host) -> atom_to_binary(Host);
host_text({_, _, _, _} = Ip) -> inet:ntoa(Ip);
host_text(Ip) when is_tuple(Ip) -> [$[, inet:ntoa(Ip), $]];
host_text(Host) -> Host.

%% =============================================================================
%% Metadata
%% =============================================================================

%% Request metadata as sent: a `-bin` value in base64, any other one
%% gRPC's ASCII-Value, under a name the call may set (gRPC's Header-Name,
%% and not one gRPC or HTTP/2 sets themselves).
-spec wire(metadata()) -> metadata().
wire(Metadata) ->
    [{own_name(Name), wire_value(Name, Value)} || {Name, Value} <- Metadata].

-spec own_name(binary()) -> binary().
own_name(Name) ->
    case
        Name =/= <<>> andalso is_metadata_name(Name) andalso
            not lists:member(Name, [
                ~"content-type",
                ~"content-length",
                ~"te",
                ~"user-agent",
                %% Connection-specific fields (RFC 9113 §8.2.2).
                ~"connection",
                ~"keep-alive",
                ~"proxy-connection",
                ~"transfer-encoding",
                ~"upgrade",
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

%% Response metadata: the headers less the ones HTTP/2 and gRPC use
%% themselves, a `-bin` value decoded from base64, each of its
%% comma-separated values one entry. A `-bin` value that is not base64 is
%% malformed.
-spec metadata(metadata()) -> {ok, metadata()} | {error, error()}.
metadata(Fields) ->
    try
        {ok, [Entry || {Name, Value} <- Fields, custom(Name), Entry <- values(Name, Value)]}
    catch
        throw:{?MODULE, Name} ->
            {error, {grpc, internal, <<"malformed binary metadata ", Name/binary>>, []}}
    end.

-spec custom(binary()) -> boolean().
custom(<<$:, _/binary>>) ->
    false;
custom(Name) ->
    not lists:member(Name, [
        ~"content-type",
        ~"grpc-status",
        ~"grpc-message",
        ~"grpc-encoding",
        ~"grpc-accept-encoding"
    ]).

-spec values(binary(), binary()) -> metadata().
values(Name, Value) ->
    case binary:longest_common_suffix([Name, ~"-bin"]) of
        4 -> [{Name, unbase64(Name, Part)} || Part <- binary:split(Value, ~",", [global])];
        _ -> [{Name, Value}]
    end.

-spec unbase64(binary(), binary()) -> binary().
unbase64(Name, Part) ->
    try
        base64:decode(roadrunner_bin:trim_ows(Part), #{padding => false})
    catch
        error:_ -> throw({?MODULE, Name})
    end.

%% =============================================================================
%% The connection process
%% =============================================================================

%% Connect, send the preface with the client's settings, and wait for the
%% server's SETTINGS before `connect/3` returns.
-doc false.
-spec init(
    pid(), inet:hostname() | inet:ip_address() | binary(), inet:port_number(), connect_opts()
) ->
    ok.
init(Owner, Host, Port, Opts) ->
    proc_lib:set_label({?MODULE, Host, Port}),
    MaxList = opt(max_header_list_size, Opts, ?MAX_HEADER_LIST),
    case open_socket(socket_host(Host), Port, Opts) of
        {ok, Socket} ->
            Settings = [{2, 0}, {4, ?STREAM_WINDOW}, {6, MaxList}],
            ok = roadrunner_transport:send(Socket, [
                ?PREFACE,
                roadrunner_http2_frame:encode({settings, 0, Settings}),
                roadrunner_http2_frame:encode({window_update, 0, ?CONN_WINDOW - ?DEFAULT_WINDOW})
            ]),
            handshake(Socket, Owner, Opts, MaxList, <<>>);
        {error, _} = Error ->
            proc_lib:init_ack(Error)
    end.

-spec socket_host(inet:hostname() | inet:ip_address() | binary()) ->
    inet:hostname() | inet:ip_address().
socket_host(Host) when is_binary(Host) -> binary_to_list(Host);
socket_host(Host) -> Host.

-spec open_socket(inet:hostname() | inet:ip_address(), inet:port_number(), connect_opts()) ->
    {ok, roadrunner_transport:socket()} | {error, term()}.
open_socket(Host, Port, #{tls := TlsOpts}) ->
    %% The client's own ALPN list: the call needs `h2`.
    Opts = [
        Opt
     || Opt <- TlsOpts, not (is_tuple(Opt) andalso element(1, Opt) =:= alpn_advertised_protocols)
    ],
    case
        ssl:connect(
            Host,
            Port,
            [binary, {active, false}, {nodelay, true}, {alpn_advertised_protocols, [~"h2"]} | Opts],
            infinity
        )
    of
        {ok, Socket} ->
            case ssl:negotiated_protocol(Socket) of
                {ok, ~"h2"} ->
                    {ok, {ssl, Socket}};
                _NotH2 ->
                    ok = ssl:close(Socket),
                    {error, h2_not_negotiated}
            end;
        {error, _} = Error ->
            Error
    end;
open_socket(Host, Port, _Opts) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}, {nodelay, true}], infinity) of
        {ok, Socket} -> {ok, {gen_tcp, Socket}};
        {error, _} = Error -> Error
    end.

%% RFC 9113 §3.4: the server's preface is a SETTINGS frame, first.
-spec handshake(roadrunner_transport:socket(), pid(), connect_opts(), pos_integer(), binary()) ->
    ok.
handshake(Socket, Owner, Opts, MaxList, Buf) ->
    case roadrunner_http2_frame:parse(Buf, ?MAX_FRAME) of
        {ok, {settings, 0, _Params}, _Rest} ->
            proc_lib:init_ack({ok, self()}),
            loop(
                frames(#state{
                    socket = Socket,
                    owner = erlang:monitor(process, Owner),
                    max = opt(max_message_size, Opts, ?MAX_MESSAGE),
                    max_list = MaxList,
                    buf = Buf,
                    enc = roadrunner_http2_hpack:new_encoder(?MAX_TABLE),
                    dec = roadrunner_http2_hpack:new_decoder(?MAX_TABLE)
                })
            );
        {more, _} ->
            case roadrunner_transport:recv(Socket, 0, infinity) of
                {ok, Data} ->
                    handshake(Socket, Owner, Opts, MaxList, <<Buf/binary, Data/binary>>);
                {error, _} ->
                    ok = roadrunner_transport:close(Socket),
                    proc_lib:init_ack({error, closed})
            end;
        _NotSettings ->
            _ = roadrunner_transport:send(Socket, goaway(protocol_error)),
            ok = roadrunner_transport:close(Socket),
            proc_lib:init_ack({error, {connection_error, protocol_error}})
    end.

%% A hand-written receive loop, as roadrunner's connection processes are.
%% It ends once the socket is closed and every call on it has been read to
%% its end, and closes the socket once a GOAWAY left no call on it.
-spec loop(#state{}) -> ok.
loop(#state{socket = closed, streams = Streams}) when map_size(Streams) =:= 0 ->
    ok;
loop(#state{socket = Socket, closing = Closing, ids = Ids} = State) when
    Socket =/= closed, Closing =/= none, map_size(Ids) =:= 0
->
    ok = roadrunner_transport:close(Socket),
    loop(State#state{socket = closed});
loop(#state{socket = Socket, owner = Owner, buf = Buf} = State) ->
    %% Socket messages count while the socket is open: one the client
    %% closed may have left some in the mailbox.
    receive
        {Tag, _, Data} when Socket =/= closed, (Tag =:= tcp orelse Tag =:= ssl) ->
            loop(frames(State#state{buf = <<Buf/binary, Data/binary>>}));
        {Tag, _} when Socket =/= closed, (Tag =:= tcp_closed orelse Tag =:= ssl_closed) ->
            loop(shutdown(closed, State));
        {Tag, _, _Reason} when Socket =/= closed, (Tag =:= tcp_error orelse Tag =:= ssl_error) ->
            loop(shutdown(closed, State));
        {?MODULE, _From, _Mon, close} = Close ->
            stop(handle(Close, State));
        {?MODULE, From, Mon, Request} ->
            loop(handle({?MODULE, From, Mon, Request}, State));
        {'DOWN', Owner, process, _, _} ->
            stop(State);
        {'DOWN', _, process, Pid, _} ->
            loop(owner_down(Pid, State));
        {timeout, Timer, {deadline, Ref}} ->
            loop(deadline(Ref, Timer, State));
        {system, From, Request} ->
            roadrunner_loop_sys:handle_system(Request, From, State, fun loop/1);
        {'$gen_call', From, _Request} ->
            ok = roadrunner_loop_sys:gen_call_unsupported(From),
            loop(State);
        _Other ->
            loop(State)
    end.

%% Close the connection, telling the server (RFC 9113 §6.8).
-spec stop(#state{}) -> ok.
stop(#state{socket = closed}) ->
    ok;
stop(#state{socket = Socket}) ->
    _ = roadrunner_transport:send(Socket, goaway(no_error)),
    roadrunner_transport:close(Socket).

-spec goaway(roadrunner_http2_frame:error_code()) -> iodata().
goaway(Code) ->
    %% The server opens no streams, so the last one processed is 0.
    roadrunner_http2_frame:encode({goaway, 0, Code, <<>>}).

-spec transmit(#state{}, iodata()) -> ok.
transmit(#state{socket = Socket}, Data) ->
    _ = roadrunner_transport:send(Socket, Data),
    ok.

%% The socket is gone: every call still running ends with `Error`, and the
%% ones ended stay to be read.
-spec shutdown(error(), #state{}) -> #state{}.
shutdown(Error, #state{socket = Socket, streams = Streams} = State) ->
    ok = roadrunner_transport:close(Socket),
    Ended =
        #{
            Ref => drop_out(S#stream{
                final = keep(Final, {error, Error}), local = closed, recv = closed
            })
         || Ref := #stream{final = Final} = S <- Streams, stop_timer(S) =:= ok
        },
    lists:foldl(
        fun deliver/2,
        State#state{
            socket = closed,
            streams = Ended,
            ids = #{},
            queue = queue:new(),
            continuation = none
        },
        maps:keys(Ended)
    ).

%% RFC 9113 §5.4.1: a connection error ends the connection with a GOAWAY
%% that says why.
-spec connection_error(roadrunner_http2_frame:error_code(), #state{}) -> #state{}.
connection_error(Code, State) ->
    ok = transmit(State, goaway(Code)),
    shutdown({connection_error, Code}, State).

%% =============================================================================
%% Requests from callers
%% =============================================================================

-spec handle({?MODULE, pid(), reference(), term()}, #state{}) -> #state{}.
handle({?MODULE, From, Mon, {open, Ref, Fields, Timeout, Out}}, State) ->
    case State of
        #state{closing = Closing} when Closing =/= none ->
            reply(From, Mon, {error, Closing}, State);
        #state{socket = closed} ->
            reply(From, Mon, {error, closed}, State);
        #state{streams = Streams, queue = Queue, owners = Owners} ->
            {Deadline, Timer} = deadline_at(Ref, Timeout),
            Stream = #stream{
                cfg = #call_cfg{
                    ref = Ref, owner = From, fields = Fields, deadline = Deadline, timer = Timer
                },
                local =
                    case Out of
                        [] -> open;
                        _ -> closing
                    end,
                out = queue:from_list([{Data, true, undefined} || Data <- Out])
            },
            From ! {Mon, ok},
            open_queued(State#state{
                streams = Streams#{Ref => Stream},
                queue = queue:in(Ref, Queue),
                owners = watch(From, Owners)
            })
    end;
handle({?MODULE, From, Mon, {send, Ref, Data, Fin}}, #state{streams = Streams} = State) ->
    case Streams of
        #{Ref := #stream{local = open, final = undefined, out = Out} = S} ->
            Local =
                case Fin of
                    true -> closing;
                    false -> open
                end,
            S1 = S#stream{local = Local, out = queue:in({Data, Fin, {From, Mon}}, Out)},
            flush_stream(Ref, State#state{streams = Streams#{Ref := S1}});
        #{} ->
            reply(From, Mon, {error, closed}, State)
    end;
handle({?MODULE, From, Mon, {recv, Ref, What}}, #state{streams = Streams} = State) ->
    case Streams of
        #{Ref := #stream{waiter = undefined} = S} ->
            deliver(Ref, State#state{
                streams = Streams#{Ref := S#stream{waiter = {What, From, Mon}}}
            });
        #{Ref := _} ->
            %% Another read of the stream is waiting already.
            reply(From, Mon, {error, busy}, State);
        #{} ->
            reply(From, Mon, {error, closed}, State)
    end;
handle({?MODULE, From, Mon, {withdraw, Ref}}, #state{streams = Streams} = State) ->
    %% The wait is still on: it ends `withdrawn`. Otherwise its answer went
    %% out already.
    case Streams of
        #{Ref := #stream{waiter = {_, From, Mon}} = S} ->
            reply(From, Mon, withdrawn, State#state{
                streams = Streams#{Ref := S#stream{waiter = undefined}}
            });
        #{} ->
            State
    end;
handle({?MODULE, From, Mon, {cancel, Ref}}, State) ->
    reply(From, Mon, ok, cancel_stream(Ref, State));
handle({?MODULE, From, Mon, close}, State) ->
    reply(From, Mon, ok, State).

-spec reply(pid(), reference(), term(), #state{}) -> #state{}.
reply(From, Mon, Reply, State) ->
    From ! {Mon, Reply},
    State.

%% Monitor each process that starts a call, once: its calls are cancelled
%% when it exits.
-spec watch(pid(), #{pid() => reference()}) -> #{pid() => reference()}.
watch(Pid, Owners) ->
    case Owners of
        #{Pid := _} -> Owners;
        #{} -> Owners#{Pid => erlang:monitor(process, Pid)}
    end.

-spec deadline_at(reference(), timeout()) -> {integer() | infinity, undefined | reference()}.
deadline_at(_Ref, infinity) ->
    {infinity, undefined};
deadline_at(Ref, Timeout) ->
    Timer = erlang:start_timer(Timeout, self(), {deadline, Ref}),
    {erlang:monotonic_time(millisecond) + Timeout, Timer}.

%% A call that ends stops its deadline's timer. One that fired already
%% left its message, which `deadline/3` drops: the call has its end.
-spec stop_timer(#stream{}) -> ok.
stop_timer(#stream{cfg = #call_cfg{timer = undefined}}) ->
    ok;
stop_timer(#stream{cfg = #call_cfg{timer = Timer}}) ->
    _ = erlang:cancel_timer(Timer),
    ok.

-spec owner_down(pid(), #state{}) -> #state{}.
owner_down(Pid, #state{streams = Streams, owners = Owners} = State) ->
    lists:foldl(
        fun cancel_stream/2,
        State#state{owners = maps:remove(Pid, Owners)},
        [Ref || Ref := #stream{cfg = #call_cfg{owner = Owner}} <- Streams, Owner =:= Pid]
    ).

-spec cancel_stream(reference(), #state{}) -> #state{}.
cancel_stream(Ref, #state{streams = Streams} = State) ->
    case Streams of
        #{Ref := _} ->
            #state{streams = Ended} =
                State1 = end_call(
                    Ref, {error, {grpc, cancelled, ~"cancelled by the client", []}}, cancel, State
                ),
            State1#state{streams = maps:remove(Ref, Ended)};
        #{} ->
            State
    end.

-spec deadline(reference(), reference(), #state{}) -> #state{}.
deadline(Ref, Timer, #state{streams = Streams} = State) ->
    case Streams of
        #{Ref := #stream{cfg = #call_cfg{timer = Timer}, final = undefined}} ->
            end_call(
                Ref, {error, {grpc, deadline_exceeded, ~"deadline exceeded", []}}, cancel, State
            );
        #{} ->
            State
    end.

%% =============================================================================
%% Opening streams and sending
%% =============================================================================

%% Open the queued calls the server's SETTINGS_MAX_CONCURRENT_STREAMS has
%% room for, in the order they started.
-spec open_queued(#state{}) -> #state{}.
open_queued(#state{closing = Closing} = State) when Closing =/= none ->
    State;
open_queued(#state{next_id = Next} = State) when Next > ?MAX_STREAM_ID ->
    %% The stream ids ran out: the connection takes no new call, and the
    %% ones waiting for a slot end `closed` (RFC 9113 §5.1.1).
    refuse_new(closed, [], State);
open_queued(#state{max_streams = Max, ids = Ids} = State) when map_size(Ids) >= Max ->
    State;
open_queued(#state{queue = Queue} = State) ->
    case queue:out(Queue) of
        {{value, Ref}, Rest} -> open_queued(start_stream(Ref, State#state{queue = Rest}));
        {empty, _} -> State
    end.

%% Send a call's HEADERS (and CONTINUATION frames past the server's
%% SETTINGS_MAX_FRAME_SIZE) on the next stream id, with its `grpc-timeout`
%% as of now, then the requests already queued.
-spec start_stream(reference(), #state{}) -> #state{}.
start_stream(
    Ref,
    #state{
        streams = Streams,
        ids = Ids,
        next_id = Id,
        enc = Enc,
        max_frame = MaxFrame,
        initial_window = Window
    } = State
) ->
    #{Ref := #stream{cfg = #call_cfg{fields = {Head, Tail}, deadline = Deadline}} = S} = Streams,
    %% Runs of the encoder make one block: the timeout, as of now, goes
    %% between the call's definition and the rest.
    {Block1, Enc1} = roadrunner_http2_hpack:encode(Head, Enc),
    {Block2, Enc2} = roadrunner_http2_hpack:encode(timeout_field(Deadline), Enc1),
    {Block3, Enc3} = roadrunner_http2_hpack:encode(Tail, Enc2),
    Block = iolist_to_binary([Block1, Block2, Block3]),
    ok = transmit(State, header_frames(Id, Block, MaxFrame)),
    S1 = S#stream{id = Id, send_window = Window},
    flush_stream(Ref, State#state{
        streams = Streams#{Ref := S1}, ids = Ids#{Id => Ref}, next_id = Id + 2, enc = Enc3
    }).

-spec timeout_field(integer() | infinity) -> metadata().
timeout_field(infinity) ->
    [];
timeout_field(Deadline) ->
    [{~"grpc-timeout", grpc_timeout(max(0, Deadline - erlang:monotonic_time(millisecond)))}].

%% gRPC's TimeoutValue is at most 8 digits: milliseconds while they fit,
%% else seconds, rounded up so the server's deadline never comes early.
-spec grpc_timeout(non_neg_integer()) -> binary().
grpc_timeout(Ms) when Ms =< 99_999_999 ->
    <<(integer_to_binary(Ms))/binary, "m">>;
grpc_timeout(Ms) ->
    <<(integer_to_binary((Ms + 999) div 1000))/binary, "S">>.

-spec header_frames(pos_integer(), binary(), pos_integer()) -> iodata().
header_frames(Id, Block, Max) when byte_size(Block) =< Max ->
    roadrunner_http2_frame:encode({headers, Id, ?END_HEADERS, undefined, Block});
header_frames(Id, Block, Max) ->
    <<Head:Max/binary, Rest/binary>> = Block,
    [
        roadrunner_http2_frame:encode({headers, Id, 0, undefined, Head})
        | continuation_frames(Id, Rest, Max)
    ].

-spec continuation_frames(pos_integer(), binary(), pos_integer()) -> iodata().
continuation_frames(Id, Block, Max) when byte_size(Block) =< Max ->
    [roadrunner_http2_frame:encode({continuation, Id, ?END_HEADERS, Block})];
continuation_frames(Id, Block, Max) ->
    <<Head:Max/binary, Rest/binary>> = Block,
    [
        roadrunner_http2_frame:encode({continuation, Id, 0, Head})
        | continuation_frames(Id, Rest, Max)
    ].

-spec flush_all(#state{}) -> #state{}.
flush_all(#state{streams = Streams} = State) ->
    lists:foldl(fun flush_stream/2, State, maps:keys(Streams)).

%% Send what a call has queued, as far as the stream's and the
%% connection's send windows let it (RFC 9113 §6.9), in frames of at most
%% the server's SETTINGS_MAX_FRAME_SIZE. Each `send/2` is answered once
%% its message is all on the wire.
-spec flush_stream(reference(), #state{}) -> #state{}.
flush_stream(Ref, #state{streams = Streams} = State) ->
    case Streams of
        #{Ref := #stream{id = Id} = S} when Id =/= undefined ->
            {S1, State1} = flush_out(S, State),
            State1#state{streams = Streams#{Ref := S1}};
        #{} ->
            State
    end.

-spec flush_out(#stream{}, #state{}) -> {#stream{}, #state{}}.
flush_out(
    #stream{id = Id, out = Out, send_window = StreamWindow} = S,
    #state{send_window = ConnWindow, max_frame = MaxFrame} = State
) ->
    case queue:out(Out) of
        {empty, _} ->
            {S, State};
        {{value, {<<>>, Fin, Ack}}, Rest} ->
            %% The END_STREAM of `close_send/1`, which no window holds back.
            ok = transmit(State, roadrunner_http2_frame:encode({data, Id, ?END_STREAM, <<>>})),
            ok = ack(Ack, ok),
            flush_out(S#stream{out = Rest, local = local_after(Fin, S)}, State);
        {{value, {Data, Fin, Ack}}, Rest} ->
            case min(min(StreamWindow, ConnWindow), MaxFrame) of
                Room when Room =< 0 ->
                    {S, State};
                Room when byte_size(Data) =< Room ->
                    Size = byte_size(Data),
                    ok = transmit(
                        State, roadrunner_http2_frame:encode({data, Id, end_stream(Fin), Data})
                    ),
                    ok = ack(Ack, ok),
                    flush_out(
                        S#stream{
                            out = Rest,
                            send_window = StreamWindow - Size,
                            local = local_after(Fin, S)
                        },
                        State#state{send_window = ConnWindow - Size}
                    );
                Room ->
                    <<Chunk:Room/binary, More/binary>> = Data,
                    ok = transmit(State, roadrunner_http2_frame:encode({data, Id, 0, Chunk})),
                    flush_out(
                        S#stream{
                            out = queue:in_r({More, Fin, Ack}, Rest),
                            send_window = StreamWindow - Room
                        },
                        State#state{send_window = ConnWindow - Room}
                    )
            end
    end.

-spec end_stream(boolean()) -> 0 | ?END_STREAM.
end_stream(true) -> ?END_STREAM;
end_stream(false) -> 0.

-spec local_after(boolean(), #stream{}) -> open | closing | closed.
local_after(true, _S) -> closed;
local_after(false, #stream{local = Local}) -> Local.

-spec ack(undefined | {pid(), reference()}, ok | {error, closed}) -> ok.
ack(undefined, _Reply) ->
    ok;
ack({From, Mon}, Reply) ->
    From ! {Mon, Reply},
    ok.

%% A call that ended drops what it had left to send: each `send/2`
%% waiting on it gets `{error, closed}`.
-spec drop_out(#stream{}) -> #stream{}.
drop_out(#stream{out = Out} = S) ->
    lists:foreach(
        fun({_Data, _Fin, Ack}) -> ok = ack(Ack, {error, closed}) end, queue:to_list(Out)
    ),
    S#stream{out = queue:new()}.

%% =============================================================================
%% Frames from the server
%% =============================================================================

-spec frames(#state{}) -> #state{}.
frames(#state{socket = closed} = State) ->
    State;
frames(#state{socket = Socket, buf = Buf} = State) ->
    case roadrunner_http2_frame:parse(Buf, ?MAX_FRAME) of
        {ok, Frame, Rest} ->
            frames(frame(Frame, State#state{buf = Rest}));
        {more, _} ->
            _ = roadrunner_transport:setopts(Socket, [{active, once}]),
            State;
        {error, frame_size_error} ->
            connection_error(frame_size_error, State);
        {error, _} ->
            connection_error(protocol_error, State)
    end.

-spec frame(roadrunner_http2_frame:frame(), #state{}) -> #state{}.
frame(Frame, #state{continuation = {Id, _, _, _}} = State) ->
    %% RFC 9113 §6.10: a header block in progress takes CONTINUATION
    %% frames of its stream and nothing else.
    case Frame of
        {continuation, Id, Flags, Fragment} -> continuation(Flags, Fragment, State);
        _ -> connection_error(protocol_error, State)
    end;
frame({settings, 0, Params}, State) ->
    settings(Params, State);
frame({settings, _Ack, _Params}, State) ->
    State;
frame({ping, 0, Data}, State) ->
    ok = transmit(State, roadrunner_http2_frame:encode({ping, 1, Data})),
    State;
frame({ping, _Ack, _Data}, State) ->
    State;
frame({goaway, LastId, Code, _Debug}, State) ->
    goaway(LastId, Code, State);
frame({window_update, 0, Increment}, #state{send_window = Window} = State) ->
    case Window + Increment of
        New when New > ?MAX_WINDOW -> connection_error(flow_control_error, State);
        New -> flush_all(State#state{send_window = New})
    end;
frame({window_update, Id, Increment}, #state{streams = Streams} = State) ->
    case lookup(Id, State) of
        {Ref, #stream{send_window = Window}} when Window + Increment > ?MAX_WINDOW ->
            stream_error(Ref, flow_control_error, ~"stream send window past its limit", State);
        {Ref, #stream{send_window = Window} = S} ->
            S1 = S#stream{send_window = Window + Increment},
            flush_stream(Ref, State#state{streams = Streams#{Ref := S1}});
        Closed ->
            on_closed(Closed, State)
    end;
frame({rst_stream, Id, Code}, State) ->
    case lookup(Id, State) of
        {Ref, _} -> end_call(Ref, {error, {reset, Code}}, none, State);
        Closed -> on_closed(Closed, State)
    end;
frame({headers, Id, Flags, _Priority, Fragment}, State) ->
    case Flags band ?END_HEADERS of
        0 ->
            State#state{
                continuation = {Id, Flags band ?END_STREAM =/= 0, Fragment, iolist_size(Fragment)}
            };
        _ ->
            header_block(Id, Flags band ?END_STREAM =/= 0, Fragment, State)
    end;
frame({data, Id, Flags, Body, FlowLen}, State) ->
    data(Id, Flags, Body, FlowLen, conn_credit(FlowLen, State));
frame({continuation, _, _, _}, State) ->
    %% A CONTINUATION with no header block in progress.
    connection_error(protocol_error, State);
frame({push_promise, _, _, _, _}, State) ->
    %% The client's SETTINGS_ENABLE_PUSH is 0 (RFC 9113 §8.4).
    connection_error(protocol_error, State);
frame(_PriorityOrUnknown, State) ->
    State.

%% The call a stream id belongs to, while the server may send on it:
%% `closed` for a stream that ended (frames on it are ignored) and `idle`
%% for one the client never opened (RFC 9113 §5.1).
-spec lookup(non_neg_integer(), #state{}) -> {reference(), #stream{}} | closed | idle.
lookup(Id, #state{ids = Ids, streams = Streams, next_id = Next}) ->
    case Ids of
        #{Id := Ref} ->
            #{Ref := S} = Streams,
            {Ref, S};
        #{} when Id rem 2 =:= 1, Id < Next ->
            closed;
        #{} ->
            idle
    end.

-spec on_closed(closed | idle, #state{}) -> #state{}.
on_closed(closed, State) -> State;
on_closed(idle, State) -> connection_error(protocol_error, State).

-spec settings([roadrunner_http2_frame:settings_param()], #state{}) -> #state{}.
settings([], State) ->
    %% RFC 9113 §6.5.3: acknowledge, then use what the new settings allow.
    ok = transmit(State, roadrunner_http2_frame:encode({settings, 1, []})),
    flush_all(open_queued(State));
settings([{2, Value} | _], State) when Value =/= 0 ->
    %% RFC 9113 §6.5.2: a server never enables push.
    connection_error(protocol_error, State);
settings([{4, Value} | _], State) when Value > ?MAX_WINDOW ->
    connection_error(flow_control_error, State);
settings([{5, Value} | _], State) when Value < ?MAX_FRAME; Value > 16#FFFFFF ->
    connection_error(protocol_error, State);
settings([{1, Value} | Rest], #state{enc = Enc} = State) ->
    settings(Rest, State#state{enc = table_size(min(Value, ?MAX_TABLE), Enc)});
settings([{3, Value} | Rest], State) ->
    settings(Rest, State#state{max_streams = Value});
settings([{4, Value} | Rest], #state{initial_window = Old, streams = Streams} = State) ->
    %% RFC 9113 §6.9.2: a new initial window moves every stream's send
    %% window by the change.
    Resized =
        #{
            Ref => S#stream{send_window = Window + Value - Old}
         || Ref := #stream{send_window = Window} = S <- Streams
        },
    case [W || _ := #stream{send_window = W} <- Resized, W > ?MAX_WINDOW] of
        [] -> settings(Rest, State#state{initial_window = Value, streams = Resized});
        _ -> connection_error(flow_control_error, State)
    end;
settings([{5, Value} | Rest], State) ->
    settings(Rest, State#state{max_frame = Value});
settings([_Other | Rest], State) ->
    settings(Rest, State).

-spec table_size(non_neg_integer(), roadrunner_http2_hpack:context()) ->
    roadrunner_http2_hpack:context().
table_size(Size, Enc) ->
    case roadrunner_http2_hpack:max_table_size(Enc) of
        Size -> Enc;
        _ -> roadrunner_http2_hpack:set_max_table_size(Size, Enc)
    end.

%% RFC 9113 §6.8: the calls on streams above the last one the server took
%% never ran, and no new call starts.
-spec goaway(non_neg_integer(), roadrunner_http2_frame:error_code(), #state{}) -> #state{}.
goaway(LastId, Code, #state{ids = Ids} = State) ->
    refuse_new({goaway, Code}, [Ref || Id := Ref <- Ids, Id > LastId], State).

%% The connection takes no new call: `Refs` and the calls waiting for a
%% slot end with `Error`, and so do the calls started from now on.
-spec refuse_new(error(), [reference()], #state{}) -> #state{}.
refuse_new(Error, Refs, #state{queue = Queue} = State) ->
    Refuse = fun(Ref, Acc) -> end_call(Ref, {error, Error}, none, Acc) end,
    lists:foldl(
        Refuse, lists:foldl(Refuse, State#state{closing = Error}, Refs), queue:to_list(Queue)
    ).

-spec continuation(non_neg_integer(), iodata(), #state{}) -> #state{}.
continuation(
    Flags, Fragment, #state{continuation = {Id, End, Block, Size}, max_list = MaxList} = State
) ->
    %% The most of one header block the client assembles: twice the header
    %% list size it advertised, as a block may encode a little larger than
    %% its list (Huffman coding can grow a string).
    case Size + iolist_size(Fragment) of
        New when New > 2 * MaxList ->
            connection_error(enhance_your_calm, State);
        _New when Flags band ?END_HEADERS =/= 0 ->
            header_block(Id, End, [Block, Fragment], State#state{continuation = none});
        New ->
            State#state{continuation = {Id, End, [Block, Fragment], New}}
    end.

%% A whole header block. It is decoded whatever stream it is on, as HPACK
%% state is the connection's (RFC 9113 §4.3).
-spec header_block(non_neg_integer(), boolean(), iodata(), #state{}) -> #state{}.
header_block(Id, End, Block, #state{dec = Dec} = State) ->
    case roadrunner_http2_hpack:decode(iolist_to_binary(Block), Dec) of
        {ok, Fields, Dec1} ->
            State1 = State#state{dec = Dec1},
            case lookup(Id, State1) of
                {Ref, S} -> header_list(Ref, S, End, Fields, State1);
                Closed -> on_closed(Closed, State1)
            end;
        {error, _} ->
            connection_error(compression_error, State)
    end.

%% RFC 9113 §6.5.2 / §10.5.1: a header list larger than the
%% SETTINGS_MAX_HEADER_LIST_SIZE the client advertised is malformed, so the
%% stream is reset (PROTOCOL_ERROR, §8.1.1) before its metadata is read,
%% and the call ends RESOURCE_EXHAUSTED, as a message over its limit does.
%% The list is sized as the setting counts it: name, value and 32 bytes a
%% field.
-spec header_list(reference(), #stream{}, boolean(), metadata(), #state{}) -> #state{}.
header_list(Ref, S, End, Fields, #state{max_list = MaxList} = State) ->
    case lists:sum([byte_size(N) + byte_size(V) + 32 || {N, V} <- Fields]) of
        Size when Size > MaxList ->
            Error = {grpc, resource_exhausted, ~"response header list larger than its limit", []},
            end_call(Ref, {error, Error}, protocol_error, State);
        _Size ->
            response_block(Ref, S, End, Fields, State)
    end.

%% The response headers, or its trailers. A first block that ends the
%% stream is gRPC's Trailers-Only response, the status alone.
-spec response_block(reference(), #stream{}, boolean(), metadata(), #state{}) -> #state{}.
response_block(Ref, #stream{recv = headers} = S, End, Fields, #state{streams = Streams} = State) ->
    case {response_kind(Fields), End} of
        {interim, false} ->
            %% RFC 9113 §8.1: an interim (1xx) response; the final one
            %% follows.
            State;
        {interim, true} ->
            stream_error(Ref, protocol_error, ~"interim response that ends the stream", State);
        {ok, true} ->
            S1 = S#stream{headers = []},
            server_end(Ref, S1, status(Fields), State#state{streams = Streams#{Ref := S1}});
        {ok, false} ->
            case metadata(Fields) of
                {ok, Metadata} ->
                    S1 = S#stream{
                        recv = body,
                        headers = Metadata,
                        encoding = receive_encoding(field(~"grpc-encoding", Fields))
                    },
                    deliver(Ref, State#state{streams = Streams#{Ref := S1}});
                {error, _} = Error ->
                    end_call(Ref, Error, cancel, State)
            end;
        {status, true} ->
            server_end(Ref, S, status(Fields), State);
        {status, false} ->
            end_call(Ref, status(Fields), cancel, State);
        {Error, true} ->
            server_end(Ref, S, {error, Error}, State);
        {Error, false} ->
            end_call(Ref, {error, Error}, cancel, State)
    end;
response_block(Ref, #stream{buf = <<>>} = S, true, Fields, State) ->
    server_end(Ref, S, status(Fields), State);
response_block(Ref, S, true, _Fields, State) ->
    server_end(
        Ref, S, {error, {grpc, internal, ~"stream ended in the middle of a message", []}}, State
    );
response_block(Ref, _S, false, _Fields, State) ->
    stream_error(Ref, protocol_error, ~"trailers that do not end the stream", State).

%% The server ended the stream. The call's requests end too: a stream
%% whose END_STREAM the client has not sent is reset (NO_ERROR).
-spec server_end(reference(), #stream{}, final(), #state{}) -> #state{}.
server_end(Ref, #stream{local = closed}, Final, State) ->
    end_call(Ref, Final, none, State);
server_end(Ref, _S, Final, State) ->
    end_call(Ref, Final, no_error, State).

%% `ok` for a gRPC response (HTTP status 200, a gRPC content type),
%% `interim` for a 1xx one, `status` for another HTTP status that carries a
%% `grpc-status` (which then wins), else the error gRPC maps the HTTP status
%% to (gRPC's http-grpc-status-mapping.md).
-spec response_kind(metadata()) -> ok | interim | status | error().
response_kind(Fields) ->
    case {field(~":status", Fields), field(~"content-type", Fields)} of
        {<<$1, _, _>>, _} ->
            interim;
        {~"200", <<"application/grpc", _/binary>>} ->
            ok;
        {~"200", _} ->
            {grpc, unknown, ~"response is not gRPC", []};
        {Status, _} ->
            case field(~"grpc-status", Fields) of
                <<>> -> {grpc, http_status(Status), <<"HTTP status ", Status/binary>>, []};
                _ -> status
            end
    end.

-spec http_status(binary()) -> roadrunner_grpc:status().
http_status(~"400") ->
    internal;
http_status(~"401") ->
    unauthenticated;
http_status(~"403") ->
    permission_denied;
http_status(~"404") ->
    unimplemented;
http_status(Status) when
    Status =:= ~"429"; Status =:= ~"502"; Status =:= ~"503"; Status =:= ~"504"
->
    unavailable;
http_status(_Status) ->
    unknown.

%% The call's end from its status block: `grpc-status` and its
%% percent-encoded `grpc-message` (gRPC's PROTOCOL-HTTP2). A missing or
%% unknown status is `UNKNOWN`.
-spec status(metadata()) -> final().
status(Fields) ->
    case metadata(Fields) of
        {ok, Metadata} ->
            case status_code(field(~"grpc-status", Fields)) of
                ok ->
                    {eof, Metadata};
                Status ->
                    Message = roadrunner_grpc_status:decode_message(field(~"grpc-message", Fields)),
                    {error, {grpc, Status, Message, Metadata}}
            end;
        {error, _} = Error ->
            Error
    end.

-spec status_code(binary()) -> roadrunner_grpc:status().
status_code(<<D>>) when D >= $0, D =< $9 -> roadrunner_grpc_status:name(D - $0);
status_code(<<$1, D>>) when D >= $0, D =< $6 -> roadrunner_grpc_status:name(10 + D - $0);
status_code(_Other) -> unknown.

%% What a message with the Compressed-Flag set was compressed with.
-spec receive_encoding(binary()) -> gzip | deflate | unsupported.
receive_encoding(~"gzip") -> gzip;
receive_encoding(~"deflate") -> deflate;
receive_encoding(_Other) -> unsupported.

-spec field(binary(), metadata()) -> binary().
field(Name, Fields) ->
    case lists:keyfind(Name, 1, Fields) of
        {_, Value} -> Value;
        false -> <<>>
    end.

%% The connection's receive window is credited back as DATA arrives: what
%% each call holds unread is bounded by its own stream window.
-spec conn_credit(non_neg_integer(), #state{}) -> #state{}.
conn_credit(FlowLen, #state{recv_window = Window} = State) ->
    case Window - FlowLen of
        Left when Left < ?CONN_WINDOW div 2 ->
            ok = transmit(
                State, roadrunner_http2_frame:encode({window_update, 0, ?CONN_WINDOW - Left})
            ),
            State#state{recv_window = ?CONN_WINDOW};
        Left ->
            State#state{recv_window = Left}
    end.

-spec data(non_neg_integer(), non_neg_integer(), binary(), non_neg_integer(), #state{}) ->
    #state{}.
data(Id, Flags, Body, FlowLen, #state{streams = Streams, max = Max} = State) ->
    case lookup(Id, State) of
        {Ref, #stream{recv = headers}} ->
            stream_error(Ref, protocol_error, ~"DATA before the response headers", State);
        {Ref, #stream{recv_window = Window}} when FlowLen > Window ->
            stream_error(Ref, flow_control_error, ~"DATA past the stream window", State);
        {Ref, #stream{recv_window = Window, buf = Buf} = S} ->
            S1 = S#stream{recv_window = Window - FlowLen, buf = <<Buf/binary, Body/binary>>},
            case deframe(S1, Max) of
                {ok, S2} when Flags band ?END_STREAM =/= 0 ->
                    server_end(
                        Ref,
                        S2,
                        {error, {grpc, internal, ~"stream ended without a status", []}},
                        State#state{streams = Streams#{Ref := S2}}
                    );
                {ok, S2} ->
                    deliver(Ref, State#state{streams = Streams#{Ref := refill(S2, State)}});
                {error, Error} ->
                    end_call(Ref, {error, Error}, cancel, State#state{streams = Streams#{Ref := S1}})
            end;
        Closed ->
            on_closed(Closed, State)
    end.

%% Take the whole messages off the stream's body.
-spec deframe(#stream{}, non_neg_integer()) -> {ok, #stream{}} | {error, error()}.
deframe(#stream{buf = Buf, msgs = Msgs, held = Held, encoding = Encoding} = S, Max) ->
    case roadrunner_grpc_frame:decode(Buf, Max) of
        {ok, Compressed, Message, Rest} ->
            Wire =
                case Compressed of
                    true -> {Encoding, Message};
                    false -> {identity, Message}
                end,
            deframe(
                S#stream{
                    buf = Rest,
                    msgs = queue:in(Wire, Msgs),
                    held = Held + 5 + byte_size(Message)
                },
                Max
            );
        more ->
            {ok, S};
        {error, message_too_large} ->
            {error, {grpc, resource_exhausted, ~"message larger than max_message_size", []}};
        {error, bad_compressed_flag} ->
            {error, {grpc, internal, ~"bad Compressed-Flag", []}}
    end.

%% Credit the stream's window back as its messages are read: once it is
%% half spent, back to its full size less what is held unread. A message
%% still arriving is credited as it comes (`max_message_size` bounds it),
%% so a message larger than the window never stalls.
-spec refill(#stream{}, #state{}) -> #stream{}.
refill(#stream{recv = body, id = Id, recv_window = Window, held = Held} = S, State) when
    Window < ?STREAM_WINDOW div 2, ?STREAM_WINDOW - Held > Window
->
    Increment = ?STREAM_WINDOW - Held - Window,
    ok = transmit(State, roadrunner_http2_frame:encode({window_update, Id, Increment})),
    S#stream{recv_window = Window + Increment};
refill(S, _State) ->
    S.

%% A stream error the client raises (RFC 9113 §5.4.2): the stream is reset
%% with `Code` and the call ends `INTERNAL`.
-spec stream_error(reference(), roadrunner_http2_frame:error_code(), binary(), #state{}) ->
    #state{}.
stream_error(Ref, Code, Message, State) ->
    end_call(Ref, {error, {grpc, internal, Message, []}}, Code, State).

%% =============================================================================
%% Ending calls and handing over what they read
%% =============================================================================

%% The call is over: it keeps the first end it got, its stream leaves the
%% wire (reset with `Rst` unless `none`), what it had to send is dropped,
%% and a slot frees for a queued call.
-spec end_call(reference(), final(), none | roadrunner_http2_frame:error_code(), #state{}) ->
    #state{}.
end_call(Ref, Final, Rst, #state{streams = Streams} = State) ->
    #{Ref := #stream{final = Kept} = S} = Streams,
    ok = stop_timer(S),
    State1 = leave_wire(S, Rst, State),
    S1 = drop_out(S#stream{final = keep(Kept, Final), local = closed, recv = closed}),
    deliver(Ref, open_queued(State1#state{streams = Streams#{Ref := S1}})).

-spec leave_wire(#stream{}, none | roadrunner_http2_frame:error_code(), #state{}) -> #state{}.
leave_wire(
    #stream{cfg = #call_cfg{ref = Ref}, id = undefined}, _Rst, #state{queue = Queue} = State
) ->
    State#state{queue = queue:delete(Ref, Queue)};
leave_wire(#stream{recv = closed}, _Rst, State) ->
    State;
leave_wire(#stream{id = Id}, Rst, #state{ids = Ids} = State) ->
    ok = rst(Id, Rst, State),
    State#state{ids = maps:remove(Id, Ids)}.

-spec rst(pos_integer(), none | roadrunner_http2_frame:error_code(), #state{}) -> ok.
rst(_Id, none, _State) ->
    ok;
rst(Id, Code, State) ->
    transmit(State, roadrunner_http2_frame:encode({rst_stream, Id, Code})).

-spec keep(final(), final()) -> final().
keep(undefined, Final) -> Final;
keep(Kept, _Final) -> Kept.

%% Answer a call's waiting `recv` or `headers`, when there is something to
%% answer. Once its end is read, the call is gone.
-spec deliver(reference(), #state{}) -> #state{}.
deliver(Ref, #state{streams = Streams} = State) ->
    case Streams of
        #{Ref := #stream{waiter = {headers, From, Mon}} = S} ->
            case headers_reply(S) of
                wait ->
                    State;
                Reply ->
                    From ! {Mon, Reply},
                    State#state{streams = Streams#{Ref := S#stream{waiter = undefined}}}
            end;
        #{Ref := #stream{waiter = {message, From, Mon}} = S} ->
            case message_reply(S) of
                wait ->
                    State;
                {Reply, #stream{final = delivered}} ->
                    From ! {Mon, Reply},
                    State#state{streams = maps:remove(Ref, Streams)};
                {Reply, S1} ->
                    From ! {Mon, Reply},
                    S2 = refill(S1#stream{waiter = undefined}, State),
                    State#state{streams = Streams#{Ref := S2}}
            end;
        #{} ->
            State
    end.

-spec headers_reply(#stream{}) -> wait | {ok, metadata()} | {error, error()}.
headers_reply(#stream{headers = Headers}) when Headers =/= undefined ->
    {ok, Headers};
headers_reply(#stream{final = {error, _} = Error}) ->
    Error;
headers_reply(#stream{final = {eof, _}}) ->
    %% An answer that carried its status alone and no headers to keep: a
    %% non-200 one with `grpc-status` 0.
    {ok, []};
headers_reply(_S) ->
    wait.

-spec message_reply(#stream{}) -> wait | {term(), #stream{}}.
message_reply(#stream{msgs = Msgs, held = Held, final = Final} = S) ->
    case queue:out(Msgs) of
        {{value, {Encoding, Bytes}}, Rest} ->
            {{message, Encoding, Bytes}, S#stream{msgs = Rest, held = Held - 5 - byte_size(Bytes)}};
        {empty, _} when Final =:= undefined ->
            wait;
        {empty, _} ->
            {Final, S#stream{final = delivered}}
    end.
