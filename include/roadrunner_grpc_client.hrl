%% The connection process's state for `roadrunner_grpc_client`, shared with
%% its test suite so tests can read and set it by field name.

%% RFC 9113 §6.5.2 / §6.9.2 defaults.
-define(DEFAULT_WINDOW, 65_535).
-define(MAX_FRAME, 16_384).
%% What the client lets the server send on each stream before it reads,
%% and on the connection.
-define(STREAM_WINDOW, 1_048_576).
-define(CONN_WINDOW, 4_194_304).

%% What a call's end is, as the connection keeps it until it is read.
-type final() ::
    undefined
    | {eof, roadrunner_grpc_client:metadata()}
    | {error, roadrunner_grpc_client:error()}
    | delivered.

%% A response message as the connection hands it over: how it is
%% compressed, and its bytes.
-type wire_message() :: {identity | gzip | deflate | unsupported, binary()}.

%% What a call holds from when it is made and never changes: its
%% reference and owner, its request headers, and its deadline and the
%% timer for it. Kept apart from `#stream{}` so each update of that
%% record, several per message, copies one field for all of them.
-record(call_cfg, {
    ref :: reference(),
    owner :: pid(),
    %% The request headers: the pseudo-headers and `te`, then the rest;
    %% `grpc-timeout` goes between them as the stream opens.
    fields :: {roadrunner_grpc_client:metadata(), roadrunner_grpc_client:metadata()},
    deadline :: integer() | infinity,
    timer :: undefined | reference()
}).

-record(stream, {
    %% The call's fixed settings, see `#call_cfg{}`.
    cfg :: #call_cfg{},
    id :: undefined | pos_integer(),
    %% The request side: `closing` once its END_STREAM is queued, `closed`
    %% once it is on the wire or the stream is reset.
    local = open :: open | closing | closed,
    %% The response side: waiting for the headers, reading the body, or
    %% over.
    recv = headers :: headers | body | closed,
    send_window = 0 :: integer(),
    out = queue:new() :: queue:queue({binary(), boolean(), undefined | {pid(), reference()}}),
    recv_window = ?STREAM_WINDOW :: integer(),
    buf = <<>> :: binary(),
    encoding = unsupported :: gzip | deflate | unsupported,
    msgs = queue:new() :: queue:queue(wire_message()),
    %% The bytes of the messages in `msgs`, which the client credits back
    %% to the server only as they are read.
    held = 0 :: non_neg_integer(),
    headers :: undefined | roadrunner_grpc_client:metadata(),
    final = undefined :: final(),
    waiter :: undefined | {headers | message, pid(), reference()}
}).

-record(state, {
    socket :: roadrunner_transport:socket() | closed,
    owner :: reference(),
    max :: non_neg_integer(),
    %% The SETTINGS_MAX_HEADER_LIST_SIZE the client advertised.
    max_list :: pos_integer(),
    buf = <<>> :: binary(),
    enc :: roadrunner_http2_hpack:context(),
    dec :: roadrunner_http2_hpack:context(),
    %% The server's settings.
    max_frame = ?MAX_FRAME :: pos_integer(),
    initial_window = ?DEFAULT_WINDOW :: non_neg_integer(),
    max_streams = infinity :: non_neg_integer() | infinity,
    %% The connection's windows: what the client may send, and what it
    %% lets the server send.
    send_window = ?DEFAULT_WINDOW :: integer(),
    recv_window = ?CONN_WINDOW :: integer(),
    next_id = 1 :: pos_integer(),
    streams = #{} :: #{reference() => #stream{}},
    %% The streams open on the wire, by id: those the server may still
    %% send on.
    ids = #{} :: #{pos_integer() => reference()},
    %% Streams waiting for a slot under the server's
    %% SETTINGS_MAX_CONCURRENT_STREAMS.
    queue = queue:new() :: queue:queue(reference()),
    owners = #{} :: #{pid() => reference()},
    continuation = none ::
        none | {pos_integer(), boolean(), iodata(), non_neg_integer()},
    %% Once the connection takes no new call, the error new calls get:
    %% `{goaway, Code}` after a GOAWAY, `closed` once stream ids ran out.
    closing = none :: none | roadrunner_grpc_client:error()
}).
