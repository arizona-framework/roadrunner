%% A request's body reader in `body_buffering => manual` mode, carried on
%% the request under `body_reader`: `roadrunner_conn` builds it and reads
%% the body through it (`roadrunner_conn:consume_body_reader/2`), the
%% HTTP/1.1 connection loop drains what the handler left unread, and
%% `roadrunner_req` answers `has_body/1` and moves its deadline
%% (`set_body_timeout/2`). Matching it by field keeps those reads off a map
%% lookup. Private: not part of the roadrunner API, which reads the body
%% through `roadrunner_req:read_body/1,2` and `read_body_chunked/1`.
%%
%% `deadline` is when reading the body times out, in
%% `erlang:monotonic_time(millisecond)` units, or `infinity`; the recv
%% closure takes it, so `set_body_timeout/2` can move it. `id` tells a
%% reader apart, so a failed read ends this body only.

%% HTTP/1.1: the reader parses the body's framing off the socket.
-record(h1_body_reader, {
    framing :: roadrunner_http1:body_framing(),
    %% Bytes read off the socket and not yet parsed: the body's, then any
    %% pipelined next request's.
    buffered = <<>> :: binary(),
    bytes_read = 0 :: non_neg_integer(),
    %% Decoded body bytes parsed off the wire but not yet handed to the
    %% caller: a chunked body's payload across length-bounded reads.
    pending = <<>> :: binary(),
    %% Whether a chunked body's size-0 last chunk is parsed.
    done = false :: boolean(),
    recv :: fun((roadrunner_req:deadline()) -> {ok, binary()} | {error, term()}),
    deadline :: roadrunner_req:deadline(),
    %% The request's own deadline, which `set_body_timeout/2` leaves alone:
    %% what is left of the body once the response is out is drained by
    %% then at the latest.
    request_deadline :: integer(),
    id :: reference(),
    max :: roadrunner_router:body_limit(),
    %% Trailer-header limits `{max_header_line, max_header_block,
    %% max_header_count}` threaded to `roadrunner_http1:parse_chunk_part/4`.
    trailer_limits :: {pos_integer(), pos_integer(), pos_integer()},
    %% What the chunk a chunked body is partway through still lacks, `0`
    %% between chunks (`roadrunner_http1:parse_chunk_part/4`).
    chunk_left = 0 :: non_neg_integer(),
    %% Set while a 100 Continue is owed to a client holding its body back:
    %% the transport socket the first read sends it on, the minimum byte
    %% rate of the recv that read then starts, and the flag that has it
    %% sent once, by that read or by a streaming response starting first.
    continue = undefined :: {term(), non_neg_integer(), atomics:atomics_ref()} | undefined
}).

%% HTTP/2 and HTTP/3: the request's DATA is delimited by the stream itself.
%% The recv closure asks the connection for what has arrived, `buffered`
%% keeps what a length-bounded read left over, and `done` flips true with
%% the stream's end.
-record(stream_body_reader, {
    buffered = <<>> :: iodata(),
    bytes_read = 0 :: non_neg_integer(),
    done = false :: boolean(),
    recv :: fun((roadrunner_req:deadline()) -> {ok, iodata(), boolean()} | {error, term()}),
    deadline :: roadrunner_req:deadline(),
    id :: reference(),
    max :: roadrunner_router:body_limit(),
    %% Set while a 100 Continue is owed to a client holding its body back:
    %% the connection process and stream a streaming response asks for it
    %% before it starts.
    continue = undefined :: {pid(), pos_integer()} | undefined,
    %% The connection process and stream a read asks for DATA, on a body
    %% still arriving (`roadrunner_conn:demand_body/1`); `undefined` for a
    %% body that arrived whole.
    source = undefined :: {pid(), non_neg_integer()} | undefined
}).
