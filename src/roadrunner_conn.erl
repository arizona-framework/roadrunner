-module(roadrunner_conn).
-moduledoc """
Public connection-process API and pure helpers.

`start/2` spawns the per-connection process (`roadrunner_conn_statem` —
a `gen_statem` whose named states `awaiting_shoot |
reading_request | reading_body | dispatching | finishing` make the
request lifecycle visible to `sys:get_state/1`, `sys:trace/2`, and
observer's process inspector). The other public functions are
pure-ish helpers that the gen_statem composes into its state
callbacks; many are also called directly from `roadrunner_req` (manual
body buffering) and from `roadrunner_conn_tests.erl`'s closure-driven
unit tests.

Per-connection behavior — keep-alive (capped by
`max_keep_alive_request`, idle-bound by `keep_alive_timeout`),
`Expect: 100-continue`, HEAD body suppression, anti-Slowloris rate
check (`minimum_bytes_per_second`), the five handler return shapes
(`{Status, Headers, Body}`, `{stream, ...}`, `{loop, ...}`,
`{sendfile, ...}`, `{websocket, ...}`) — lives in
`roadrunner_conn_statem` and the response-shape-specific modules
(`roadrunner_stream_response`, `roadrunner_loop_response`,
`roadrunner_ws_session`).

The 4xx/5xx error responses (400 on parse failure, 408 on
first-request silence, 413 on oversized bodies, 500 on handler
crashes) are emitted via the `send_*/1` helpers exported here. Idle
keep-alive timeouts and slow-client rate violations close the
connection silently — no response to a peer that wasn't going to
read it anyway.
""".

-export([
    start/2,
    parse_loop/2,
    read_body/4,
    peer/1,
    try_acquire_slot/1,
    release_slot/1,
    consume_body_state/2,
    join_drain_group/1
]).
%% Internal helpers shared with `roadrunner_conn_statem`. Marked `-doc false`
%% individually so they stay invisible to the public API surface but
%% are still reachable across the module boundary. They live here
%% (rather than inside the statem module) because the closure-driven
%% unit tests in `roadrunner_conn_tests.erl` exercise the body-state
%% machinery directly through these functions.
-export([
    make_recv/3,
    body_framing/1,
    generate_request_id/0,
    generate_request_id/1,
    set_request_logger_metadata/1,
    maybe_send_continue/3,
    refine_conn_label/2,
    scheme/1,
    make_body_state/4,
    drain_body/1,
    keep_alive_decision/2,
    send_request_timeout/1,
    send_bad_request/1,
    send_payload_too_large/1,
    drain_oversized_body/3,
    send_internal_error/1,
    send_not_found/1,
    resolve_handler/2,
    route_middlewares/1,
    response_status/1,
    response_kind/1,
    response_body_for/2
]).

-export_type([proto_opts/0, dispatch/0, body_state/0]).

-type dispatch() ::
    {handler, module()}
    | {router, ListenerName :: atom()}.

-type proto_opts() :: #{
    dispatch := dispatch(),
    middlewares := roadrunner_middleware:middleware_list(),
    max_content_length := non_neg_integer(),
    request_timeout := non_neg_integer(),
    keep_alive_timeout := non_neg_integer(),
    max_keep_alive_request := pos_integer(),
    max_clients := pos_integer(),
    client_counter := atomics:atomics_ref(),
    requests_counter := atomics:atomics_ref(),
    minimum_bytes_per_second := non_neg_integer(),
    body_buffering := auto | manual,
    listener_name => atom(),
    %% Conn-process implementation. Default `statem` dispatches to
    %% `roadrunner_conn_statem` (gen_statem). Set to `loop` to route
    %% through `roadrunner_conn_loop`'s tail-recursive variant —
    %% wire-equivalent, lower variance, in-progress per the perf plan.
    conn_impl => loop | statem
}.

%% Opaque body-read state attached to the request in manual buffering
%% mode. `roadrunner_req:read_body/1,2` consumes from this state; the conn
%% owns the recv closure and tracks how much remains.
%%
%% `pending` holds decoded body bytes that have been parsed off the
%% wire but not yet handed to the caller — used for chunked framing
%% to absorb a chunk's payload across multiple length-bounded calls.
%% `done` flips true once the size-0 last chunk is parsed.
-type body_state() :: #{
    framing := none | chunked | {content_length, non_neg_integer()},
    buffered := binary(),
    bytes_read := non_neg_integer(),
    pending := binary(),
    done := boolean(),
    recv := fun(() -> {ok, binary()} | {error, term()}),
    max := non_neg_integer()
}.

-doc """
Spawn an unlinked connection process for the accepted `Socket` and the
shared `ProtoOpts` (handler module, body limits, ...).

Backed by `roadrunner_conn_statem` — a `gen_statem` whose named states
(`awaiting_shoot | reading_request | reading_body | dispatching |
finishing`) make the request lifecycle visible to `sys:get_state/1`,
`sys:trace/2`, and observer's process inspector. The legacy
recursive spine is gone.

The caller (typically `roadrunner_acceptor`) must transfer socket
ownership via `roadrunner_transport:controlling_process/2` and then
send the process the atom `shoot` to release it.
""".
-spec start(roadrunner_transport:socket(), proto_opts()) -> {ok, pid()}.
start(Socket, ProtoOpts) when is_map(ProtoOpts) ->
    case maps:get(conn_impl, ProtoOpts, statem) of
        statem ->
            {ok, _Pid} = roadrunner_conn_statem:start(Socket, ProtoOpts);
        loop ->
            {ok, _Pid} = roadrunner_conn_loop:start(Socket, ProtoOpts)
    end.

-doc """
Join the per-listener `pg` group so `roadrunner_listener:drain/2` can
broadcast a `{roadrunner_drain, Deadline}` notification to the calling
process. `pg` removes the caller automatically when the process
exits. The `pg` scope is started by `roadrunner_sup`; in tests that
drive `roadrunner_listener:start_link/2` directly without starting the
application, the scope is absent and the join is silently skipped
— drain will simply not see those conns.

Shared by `roadrunner_conn:start/2` and `roadrunner_conn_statem:init/1` so
both implementations reach the drain group through a single
covered code path.
""".
-spec join_drain_group(atom()) -> ok.
join_drain_group(undefined) ->
    ok;
join_drain_group(Name) ->
    case whereis(pg) of
        undefined -> ok;
        _ -> pg:join({roadrunner_drain, Name}, self())
    end.

-doc """
Try to bump the live-connection counter under `max_clients`. Returns
`true` on success (caller may proceed to spawn a conn), `false` if
the cap is already met (caller must close the accepted socket).

The check is racy by a small amount: between increment and rollback
multiple acceptors may briefly observe a count slightly above the
cap, but the count is corrected immediately by the rollback. The
overshoot is at most `num_acceptors - 1` — bounded and harmless.

## Slot leak under abnormal exits

The slot is released by `roadrunner_conn_statem:terminate/3` on every
normal exit path (handler crash, parse error, drain stop, peer
close). Under `exit(Pid, kill)` — sent by a supervisor or by an
operator using `recon:proc_count/2`-style cleanup — the runtime
skips `terminate/3` per OTP semantics, so the slot is **leaked**
for the lifetime of the listener process. This is bounded:
`max_clients` accepted connections each leak at most one slot
under killing, and the listener restart resets the counter. If
leaks become a real concern under chaos-test conditions, add a
periodic reaper that compares `pg:get_members({roadrunner_drain, _})`
against the live counter and reconciles the difference.
""".
-spec try_acquire_slot(proto_opts()) -> boolean().
try_acquire_slot(#{client_counter := Ref, max_clients := Max}) ->
    case atomics:add_get(Ref, 1, 1) of
        N when N =< Max ->
            true;
        _ ->
            atomics:sub(Ref, 1, 1),
            false
    end.

-doc "Decrement the live-connection counter — paired with `try_acquire_slot/1`.".
-spec release_slot(proto_opts()) -> ok.
release_slot(#{client_counter := Ref}) ->
    _ = atomics:sub(Ref, 1, 1),
    ok.

-doc false.
-spec refine_conn_label(
    proto_opts(), {inet:ip_address(), inet:port_number()} | undefined
) -> ok.
refine_conn_label(ProtoOpts, Peer) ->
    ListenerName = maps:get(listener_name, ProtoOpts, undefined),
    proc_lib:set_label({roadrunner_conn, ListenerName, Peer}),
    ok.

%% 64 random bits in lowercase hex — collision-resistant for billions of
%% requests, short enough to embed in log lines.
%%
%% Two arities. `/0` is stateless (each call goes through the CSPRNG NIF)
%% — used by `roadrunner_conn_statem` and any caller that doesn't carry
%% per-conn state. `/1` accepts a per-conn buffer of pre-generated random
%% bytes and returns `{RequestId, NewBuffer}` — caller threads the
%% buffer through its own state. The conn_loop variant uses `/1` to
%% amortize the NIF call: one `crypto:strong_rand_bytes/1` per ~32
%% requests instead of one per request. Each 8-byte slice still
%% carries a full 64 bits of independent entropy — the batch boundary
%% doesn't reduce randomness.
-doc false.
-spec generate_request_id() -> binary().
generate_request_id() ->
    binary:encode_hex(crypto:strong_rand_bytes(8), lowercase).

-define(REQ_ID_BATCH_BYTES, 256).

-doc false.
-spec generate_request_id(binary()) -> {binary(), binary()}.
generate_request_id(<<Slice:8/binary, Rest/binary>>) ->
    {binary:encode_hex(Slice, lowercase), Rest};
generate_request_id(_Empty) ->
    %% Buffer drained (or never initialized) — refill with one NIF call.
    <<Slice:8/binary, Rest/binary>> = crypto:strong_rand_bytes(?REQ_ID_BATCH_BYTES),
    {binary:encode_hex(Slice, lowercase), Rest}.

%% Replaces (not merges) the conn process's logger metadata so a
%% keep-alive request never inherits the previous request's correlation.
-doc false.
-spec set_request_logger_metadata(roadrunner_http1:request()) -> ok.
set_request_logger_metadata(#{
    request_id := RequestId,
    method := Method,
    target := Target,
    peer := Peer
}) ->
    logger:set_process_metadata(#{
        request_id => RequestId,
        method => Method,
        path => Target,
        peer => Peer
    }).

%% Build a recv closure with a single overall deadline plus a rolling
%% rate check. `gen_tcp:recv` with a negative timeout is undefined, so
%% we cap at 0 — which makes gen_tcp return `{error, timeout}`
%% immediately when the deadline has passed. Any timeout here is, by
%% construction, the request_timeout.
%%
%% Rate enforcement (anti-Slowloris): track total bytes received and
%% time since the first recv. After a 1-second grace, require the
%% running average to meet `MinRate` bytes/sec, otherwise return
%% `{error, slow_client}`. The state is a per-conn atomics ref — no
%% cross-process contention.
-doc false.
-spec make_recv(roadrunner_transport:socket(), integer(), non_neg_integer()) ->
    fun(() -> {ok, binary()} | {error, request_timeout | slow_client | term()}).
make_recv(Socket, Deadline, MinRate) ->
    Bytes = atomics:new(1, [{signed, false}]),
    Start = erlang:monotonic_time(millisecond),
    fun() ->
        Now = erlang:monotonic_time(millisecond),
        Remaining = max(0, Deadline - Now),
        case roadrunner_transport:recv(Socket, 0, Remaining) of
            {ok, Data} ->
                Total = atomics:add_get(Bytes, 1, byte_size(Data)),
                case rate_ok(Now - Start, Total, MinRate) of
                    true -> {ok, Data};
                    false -> {error, slow_client}
                end;
            {error, timeout} ->
                {error, request_timeout};
            {error, _} = E ->
                E
        end
    end.

%% A 1-second grace lets a slow handshake / TLS session start without
%% being misclassified. After that, the running average must meet the
%% minimum or the client is dropped. `MinRate = 0` falls through and
%% always passes — the inequality `Total * 1000 >= 0` is trivially true.
-spec rate_ok(integer(), non_neg_integer(), non_neg_integer()) -> boolean().
rate_ok(ElapsedMs, _Total, _MinRate) when ElapsedMs =< 1000 -> true;
rate_ok(ElapsedMs, Total, MinRate) -> Total * 1000 >= MinRate * ElapsedMs.

-doc false.
-spec peer(roadrunner_transport:socket()) -> {inet:ip_address(), inet:port_number()} | undefined.
peer(Socket) ->
    case roadrunner_transport:peername(Socket) of
        {ok, Peer} -> Peer;
        {error, _} -> undefined
    end.

-doc false.
-spec scheme(roadrunner_transport:socket()) -> http | https.
scheme({gen_tcp, _}) -> http;
scheme({ssl, _}) -> https;
scheme({fake, _}) -> http.

-doc false.
-spec resolve_handler(dispatch(), roadrunner_http1:request()) ->
    {ok, module(), roadrunner_router:bindings(), term()} | not_found.
resolve_handler({handler, Mod}, _Req) ->
    {ok, Mod, #{}, undefined};
resolve_handler({router, ListenerName}, Req) ->
    %% Routes are stored in `persistent_term` by `roadrunner_listener` so
    %% the lookup is O(1) and `roadrunner_listener:reload_routes/2` can
    %% atomically swap the table without bouncing the listener.
    Compiled = persistent_term:get({roadrunner_routes, ListenerName}),
    roadrunner_router:match(roadrunner_req:path(Req), Compiled).

-doc false.
-spec read_body(
    roadrunner_http1:request(),
    binary(),
    fun(() -> {ok, binary()} | {error, term()}),
    non_neg_integer()
) ->
    {ok, Body :: binary(), Leftover :: binary()}
    | {error,
        content_length_too_large
        | bad_content_length
        | bad_transfer_encoding
        | term()}.
read_body(Req, Buffered, RecvFun, MaxCL) ->
    case body_framing(Req) of
        none ->
            %% Per RFC 7230 §3.3.3: a request without `Content-Length`
            %% or `Transfer-Encoding` has a zero-length message body.
            %% Any leftover bytes in `Buffered` belong to a pipelined
            %% next request — preserve them as `Leftover` so the conn
            %% can feed them into the next `reading_request` parse.
            {ok, <<>>, Buffered};
        chunked ->
            read_chunked(Buffered, RecvFun, MaxCL, 0);
        {content_length, N} when N > MaxCL ->
            {error, content_length_too_large};
        {content_length, N} ->
            read_body_until(N, Buffered, RecvFun);
        {error, _} = Err ->
            Err
    end.

%% RFC 9110 §10.1.1: when a request carries `Expect: 100-continue` and
%% we're about to read a body, send `HTTP/1.1 100 Continue` so clients
%% that gate body transmission on this signal don't stall. We only do
%% this if no body bytes have already arrived in the buffer — once we
%% see body data the client clearly didn't wait, and the 100 line is
%% redundant.
-doc false.
-spec maybe_send_continue(roadrunner_transport:socket(), roadrunner_http1:request(), binary()) ->
    ok.
maybe_send_continue(Socket, Req, Buffered) ->
    case Buffered =:= ~"" andalso has_continue_expectation(Req) of
        true ->
            _ = roadrunner_transport:send(Socket, ~"HTTP/1.1 100 Continue\r\n\r\n"),
            ok;
        false ->
            ok
    end.

-spec has_continue_expectation(roadrunner_http1:request()) -> boolean().
has_continue_expectation(#{cached_decisions := #{expects_continue := EC}}) ->
    EC;
has_continue_expectation(Req) ->
    %% Manually-built request maps (tests, middleware) skip the parse-time
    %% precompute — fall back to the lowercase-and-compare path.
    case roadrunner_req:header(~"expect", Req) of
        undefined -> false;
        Value -> roadrunner_bin:ascii_lowercase(Value) =:= ~"100-continue"
    end.

-doc false.
-spec make_body_state(
    none | chunked | {content_length, non_neg_integer()},
    binary(),
    fun(() -> {ok, binary()} | {error, term()}),
    non_neg_integer()
) -> body_state().
make_body_state(Framing, Buffered, Recv, Max) ->
    #{
        framing => Framing,
        buffered => Buffered,
        bytes_read => 0,
        pending => <<>>,
        done => false,
        recv => Recv,
        max => Max
    }.

-doc false.
-spec body_framing(roadrunner_http1:request()) ->
    none
    | chunked
    | {content_length, non_neg_integer()}
    | {error, bad_content_length | bad_transfer_encoding}.
body_framing(#{cached_decisions := #{is_chunked := true}}) ->
    chunked;
body_framing(#{cached_decisions := #{has_transfer_encoding := true}}) ->
    %% Non-chunked Transfer-Encoding (e.g. `gzip`). Rejected per
    %% RFC 9112 §6.1 — we only support identity and chunked.
    {error, bad_transfer_encoding};
body_framing(#{cached_decisions := #{content_length := CL}}) ->
    %% No Transfer-Encoding header. `parse_request/1`'s `check_framing/1`
    %% already rejected TE+CL combos and inconsistent multi-CL, so the
    %% cached Content-Length is the body framing.
    case CL of
        none -> none;
        {ok, N} -> {content_length, N};
        {error, _} = Err -> Err
    end;
body_framing(Req) ->
    %% Manually-built request maps without cached_decisions — full path.
    case roadrunner_req:header(~"transfer-encoding", Req) of
        undefined ->
            case content_length(Req) of
                none -> none;
                {ok, N} -> {content_length, N};
                {error, _} = Err -> Err
            end;
        Value ->
            %% RFC 9110 §10.1.4: transfer-coding names are
            %% case-insensitive. Accept `chunked`, `Chunked`,
            %% `CHUNKED` etc. (clients in the wild send all variants).
            case roadrunner_bin:ascii_lowercase(Value) of
                ~"chunked" -> chunked;
                _ -> {error, bad_transfer_encoding}
            end
    end.

-spec read_body_until(
    non_neg_integer(),
    binary(),
    fun(() -> {ok, binary()} | {error, term()})
) ->
    {ok, binary(), binary()} | {error, term()}.
read_body_until(N, Acc, _RecvFun) when byte_size(Acc) >= N ->
    <<Body:N/binary, Leftover/binary>> = Acc,
    {ok, Body, Leftover};
read_body_until(N, Acc, RecvFun) ->
    case RecvFun() of
        {ok, Data} -> read_body_until(N, <<Acc/binary, Data/binary>>, RecvFun);
        {error, _} = E -> E
    end.

%% Read chunks until the size-0 last-chunk, concatenating decoded data
%% into the result. Caps the accumulated body at MaxCL — a malicious
%% client cannot stream unbounded chunked bytes past the configured
%% limit. Body recursion: each call returns the body of the remaining
%% chunks, the current call prepends its own data on the way out.
-spec read_chunked(
    binary(),
    fun(() -> {ok, binary()} | {error, term()}),
    non_neg_integer(),
    non_neg_integer()
) ->
    {ok, binary(), binary()} | {error, content_length_too_large | term()}.
read_chunked(Buf, RecvFun, MaxCL, Decoded) ->
    case roadrunner_http1:parse_chunk(Buf) of
        {ok, last, _Trailers, Leftover} ->
            %% Bytes after the size-0 last-chunk + trailer block are
            %% pipelined-next-request leftover; thread them up so the
            %% conn can feed them into the next parse.
            {ok, <<>>, Leftover};
        {ok, Data, Rest} ->
            NewDecoded = Decoded + byte_size(Data),
            if
                NewDecoded > MaxCL ->
                    {error, content_length_too_large};
                true ->
                    case read_chunked(Rest, RecvFun, MaxCL, NewDecoded) of
                        {ok, More, Leftover} ->
                            {ok, <<Data/binary, More/binary>>, Leftover};
                        {error, _} = E ->
                            E
                    end
            end;
        {more, _} ->
            case RecvFun() of
                {ok, More} ->
                    read_chunked(<<Buf/binary, More/binary>>, RecvFun, MaxCL, Decoded);
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% Read and discard whatever the handler left in the manual-mode
%% `body_state`, returning any post-body leftover bytes that belong
%% to a pipelined next request. Called only on the 4-tuple response
%% path; `roadrunner_conn_statem`'s finishing state threads `Leftover`
%% forward into the next `reading_request` parse so pipelined
%% clients get their N+1 request seen.
-doc false.
-spec drain_body(roadrunner_http1:request()) -> {ok, binary()} | {error, term()}.
drain_body(#{body_state := BS}) ->
    case consume_body_state(BS, all) of
        {ok, _Bytes, #{buffered := Leftover}} -> {ok, Leftover};
        {error, _} = E -> E
    end;
drain_body(_Req) ->
    %% No body_state means the handler hand-built `Req2` without using
    %% manual-mode plumbing. Nothing to drain, no pipelined leftover
    %% to surface.
    {ok, <<>>}.

-doc """
Consume bytes from a manual-mode `body_state()`. Returns either the
final tail (`{ok, Bytes, NewState}` — the body has been fully drained)
or a partial chunk (`{more, Bytes, NewState}` — more is still pending).
Used by `roadrunner_req:read_body/1,2`; not part of the public API.

`Mode` is `all` (drain to end) or `{length, N}` (read up to `N`
bytes — content-length framing only; chunked falls through to a
full read).
""".
-spec consume_body_state(body_state(), all | next_chunk | {length, non_neg_integer()}) ->
    {ok, binary(), body_state()}
    | {more, binary(), body_state()}
    | {error, term()}.
consume_body_state(#{framing := none} = BS, _Mode) ->
    %% Per RFC 7230 §3.3.3: no framing means the body is empty.
    %% Any `buffered` bytes are pipelined-next-request leftovers —
    %% preserve them in the body_state's `buffered` field so
    %% `roadrunner_conn_statem`'s finishing state can thread them into
    %% the next `reading_request` parse for full pipelining support.
    {ok, <<>>, BS};
consume_body_state(
    #{framing := {content_length, N}, bytes_read := Read} = BS, _Mode
) when Read >= N ->
    {ok, <<>>, BS};
consume_body_state(
    #{
        framing := {content_length, N},
        bytes_read := Read,
        buffered := Buf,
        recv := Recv,
        max := Max
    } = BS,
    Mode
) ->
    Remaining = N - Read,
    Want =
        case Mode of
            all -> Remaining;
            next_chunk -> Remaining;
            {length, L} -> min(Remaining, L)
        end,
    case Want > Max of
        true ->
            {error, content_length_too_large};
        false ->
            case fill_n(Want, Buf, Recv) of
                {ok, Bytes, NewBuf} ->
                    NewRead = Read + byte_size(Bytes),
                    NewState = BS#{buffered := NewBuf, bytes_read := NewRead},
                    case NewRead >= N of
                        true -> {ok, Bytes, NewState};
                        false -> {more, Bytes, NewState}
                    end;
                {error, _} = E ->
                    E
            end
    end;
consume_body_state(#{framing := chunked} = BS, all) ->
    %% Drain everything left: any pending decoded bytes plus all
    %% remaining chunks, accumulated in one return.
    chunked_collect(BS, infinity, []);
consume_body_state(#{framing := chunked} = BS, {length, N}) ->
    chunked_collect(BS, N, []);
consume_body_state(#{framing := chunked} = BS, next_chunk) ->
    next_chunk(BS).
%% Non-chunked framing (none, content_length) is handled by the
%% earlier clauses above — `next_chunk` is treated as a full drain
%% inside those, since there are no chunk boundaries to honor.

%% Pull decoded chunked-body bytes out of `BS` until either `Want`
%% bytes are collected or the body is fully drained. `Want` is either
%% `infinity` (drain to end — caller asked for `all`) or a positive
%% integer (caller asked for `{length, N}`). Returns `{ok, Bytes, BS2}`
%% when no more body remains, `{more, Bytes, BS2}` when bytes were
%% returned but the body is not yet exhausted, or `{error, Reason}`.
-spec chunked_collect(body_state(), infinity | non_neg_integer(), [binary()]) ->
    {ok, binary(), body_state()}
    | {more, binary(), body_state()}
    | {error, term()}.
chunked_collect(#{pending := Pending} = BS, Want, Acc) when
    Want =/= infinity, byte_size(Pending) >= Want
->
    %% Pending alone satisfies the request — no need to look at the
    %% wire. The body may or may not have more bytes; we always tag
    %% `more` here and let the next call detect end-of-body via the
    %% `done` clause below.
    <<Take:Want/binary, RestPending/binary>> = Pending,
    Out = iolist_to_binary(lists:reverse([Take | Acc])),
    {more, Out, BS#{pending := RestPending}};
chunked_collect(#{pending := Pending} = BS, Want, Acc) when byte_size(Pending) > 0 ->
    %% Take everything pending, then try to fill more from the wire.
    NewWant =
        case Want of
            infinity -> infinity;
            N -> N - byte_size(Pending)
        end,
    chunked_collect(BS#{pending := <<>>}, NewWant, [Pending | Acc]);
chunked_collect(#{done := true} = BS, _Want, Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc)), BS};
chunked_collect(#{buffered := Buf, recv := Recv, max := Max, bytes_read := Read} = BS, Want, Acc) ->
    case roadrunner_http1:parse_chunk(Buf) of
        {ok, Data, Rest} ->
            NewRead = Read + byte_size(Data),
            case NewRead > Max of
                true ->
                    {error, content_length_too_large};
                false ->
                    BS2 = BS#{buffered := Rest, bytes_read := NewRead, pending := Data},
                    chunked_collect(BS2, Want, Acc)
            end;
        {ok, last, _Trailers, Rest} ->
            chunked_collect(BS#{buffered := Rest, done := true}, Want, Acc);
        {more, _} ->
            case Recv() of
                {ok, More} ->
                    chunked_collect(BS#{buffered := <<Buf/binary, More/binary>>}, Want, Acc);
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% Pull exactly one decoded chunk out of a chunked body_state. Pending
%% bytes (left over from a length-bounded read) are returned first; if
%% pending is empty, parse the next wire chunk. End-of-body returns
%% `{ok, <<>>, BS}`.
-spec next_chunk(body_state()) ->
    {ok, binary(), body_state()}
    | {more, binary(), body_state()}
    | {error, term()}.
next_chunk(#{pending := Pending} = BS) when byte_size(Pending) > 0 ->
    {more, Pending, BS#{pending := <<>>}};
next_chunk(#{done := true} = BS) ->
    {ok, <<>>, BS};
next_chunk(#{buffered := Buf, recv := Recv, max := Max, bytes_read := Read} = BS) ->
    case roadrunner_http1:parse_chunk(Buf) of
        {ok, Data, Rest} ->
            NewRead = Read + byte_size(Data),
            case NewRead > Max of
                true ->
                    {error, content_length_too_large};
                false ->
                    {more, Data, BS#{buffered := Rest, bytes_read := NewRead}}
            end;
        {ok, last, _Trailers, Rest} ->
            {ok, <<>>, BS#{buffered := Rest, done := true}};
        {more, _} ->
            case Recv() of
                {ok, More} ->
                    next_chunk(BS#{buffered := <<Buf/binary, More/binary>>});
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

-spec fill_n(non_neg_integer(), binary(), fun(() -> {ok, binary()} | {error, term()})) ->
    {ok, binary(), binary()} | {error, term()}.
fill_n(N, Buf, _Recv) when byte_size(Buf) >= N ->
    <<Bytes:N/binary, Rest/binary>> = Buf,
    {ok, Bytes, Rest};
fill_n(N, Buf, Recv) ->
    case Recv() of
        {ok, More} -> fill_n(N, <<Buf/binary, More/binary>>, Recv);
        {error, _} = E -> E
    end.

-spec content_length(roadrunner_http1:request()) ->
    none | {ok, non_neg_integer()} | {error, bad_content_length}.
content_length(Req) ->
    case roadrunner_req:header(~"content-length", Req) of
        undefined ->
            none;
        Bin ->
            try binary_to_integer(Bin) of
                N when N >= 0 -> {ok, N};
                _ -> {error, bad_content_length}
            catch
                _:_ -> {error, bad_content_length}
            end
    end.

-doc false.
-spec parse_loop(binary(), fun(() -> {ok, binary()} | {error, term()})) ->
    {ok, roadrunner_http1:request(), binary()} | {error, term()}.
parse_loop(Buf, RecvFun) ->
    case roadrunner_http1:parse_request(Buf) of
        {ok, Req, Rest} ->
            {ok, Req, Rest};
        {more, _} ->
            case RecvFun() of
                {ok, Data} -> parse_loop(<<Buf/binary, Data/binary>>, RecvFun);
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

%% Order matters — `{websocket, _, _}` is a 3-tuple too, so the
%% atom-tagged variants must precede the buffered catch-all.
-doc false.
-spec response_status(roadrunner_handler:response()) -> roadrunner_http1:status().
response_status({stream, Status, _, _}) -> Status;
response_status({loop, Status, _, _}) -> Status;
response_status({sendfile, Status, _, _}) -> Status;
response_status({websocket, _, _}) -> 101;
response_status({Status, _, _}) when is_integer(Status) -> Status.

-doc false.
-spec response_kind(roadrunner_handler:response()) ->
    buffered | stream | loop | sendfile | websocket.
response_kind({stream, _, _, _}) -> stream;
response_kind({loop, _, _, _}) -> loop;
response_kind({sendfile, _, _, _}) -> sendfile;
response_kind({websocket, _, _}) -> websocket;
response_kind({_, _, _}) -> buffered.

-doc false.
-spec route_middlewares(roadrunner_http1:request()) -> roadrunner_middleware:middleware_list().
route_middlewares(Req) ->
    case roadrunner_req:route_opts(Req) of
        #{middlewares := Mws} -> Mws;
        _ -> []
    end.

%% RFC 9110 §9.3.2: a response to HEAD must not include a message body.
%% Headers (including Content-Length) stay as the handler set them, so
%% the framing matches what GET would have returned.
-doc false.
-spec response_body_for(roadrunner_http1:request(), iodata()) -> iodata().
response_body_for(Req, Body) ->
    case roadrunner_req:method(Req) of
        ~"HEAD" -> ~"";
        _ -> Body
    end.

%% HTTP/1.0 default close. HTTP/1.1 keep-alive unless either side
%% set Connection: close.
-doc false.
-spec keep_alive_decision(roadrunner_http1:request(), roadrunner_http1:headers()) ->
    keep_alive | close.
%% Common-case fast path: HTTP/1.1, parser-cached request `Connection`
%% empty, response has no `connection` header → `keep_alive` directly.
%% Skips the lowercase + has_token dance entirely. Most production
%% hello/echo responses hit this path.
keep_alive_decision(
    #{
        version := {1, 1},
        cached_decisions := #{connection_lower := <<>>}
    } = Req,
    RespHeaders
) when is_list(RespHeaders) ->
    case lists:keymember(~"connection", 1, RespHeaders) of
        false -> keep_alive;
        true -> keep_alive_decision_full(Req, RespHeaders)
    end;
keep_alive_decision(Req, RespHeaders) ->
    keep_alive_decision_full(Req, RespHeaders).

-spec keep_alive_decision_full(roadrunner_http1:request(), roadrunner_http1:headers()) ->
    keep_alive | close.
keep_alive_decision_full(Req, RespHeaders) ->
    ReqConn = req_connection_lower(Req),
    RespConn = roadrunner_bin:ascii_lowercase(resp_connection_token(RespHeaders)),
    ReqClose = has_token(ReqConn, ~"close"),
    RespClose = has_token(RespConn, ~"close"),
    case roadrunner_req:version(Req) of
        {1, 0} ->
            %% RFC 7230 §6.1: HTTP/1.0 default is close, but
            %% `Connection: keep-alive` from client opts in (so long
            %% as the response doesn't force close).
            ReqKA = has_token(ReqConn, ~"keep-alive"),
            case ReqKA andalso not RespClose of
                true -> keep_alive;
                false -> close
            end;
        {1, 1} ->
            case ReqClose orelse RespClose of
                true -> close;
                false -> keep_alive
            end
    end.

%% Returns the request's `Connection` header value, lowercased. Reads from
%% `cached_decisions` when present (parser populates it once per request)
%% and falls back to a per-call lowercase for manually-built request maps.
-spec req_connection_lower(roadrunner_http1:request()) -> binary().
req_connection_lower(#{cached_decisions := #{connection_lower := V}}) ->
    V;
req_connection_lower(Req) ->
    case roadrunner_req:header(~"connection", Req) of
        undefined -> ~"";
        V -> roadrunner_bin:ascii_lowercase(V)
    end.

-spec resp_connection_token(roadrunner_http1:headers()) -> binary().
resp_connection_token(Headers) ->
    case header_value(~"connection", Headers) of
        undefined -> ~"";
        V -> V
    end.

-spec has_token(binary(), binary()) -> boolean().
has_token(Value, Token) ->
    binary:match(Value, Token) =/= nomatch.

-spec header_value(binary(), roadrunner_http1:headers()) -> binary() | undefined.
header_value(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, V} -> V;
        false -> undefined
    end.

-doc false.
-spec send_bad_request(roadrunner_transport:socket()) -> ok | {error, term()}.
send_bad_request(Socket) ->
    Resp = roadrunner_http1:response(
        400,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    roadrunner_transport:send(Socket, Resp).

%% Drain up to `2 * MaxCL` bytes from the socket (counting the
%% already-buffered bytes), discarding them. Used to flush an
%% oversized in-flight body off the wire so the peer can read the
%% 413 we're about to send before we close. Bounded by `2 * MaxCL`
%% (memory) and a 1-second per-recv timeout (wall-clock) so a slow
%% peer can't pin us indefinitely.
-doc false.
-spec drain_oversized_body(binary(), roadrunner_transport:socket(), non_neg_integer()) -> ok.
drain_oversized_body(Buffered, Socket, MaxCL) ->
    Cap = 2 * MaxCL,
    drain_oversized_loop(Socket, byte_size(Buffered), Cap).

-spec drain_oversized_loop(
    roadrunner_transport:socket(), non_neg_integer(), non_neg_integer()
) -> ok.
drain_oversized_loop(_Socket, Read, Cap) when Read >= Cap ->
    ok;
drain_oversized_loop(Socket, Read, Cap) ->
    case roadrunner_transport:recv(Socket, 0, 1000) of
        {ok, Data} ->
            drain_oversized_loop(Socket, Read + byte_size(Data), Cap);
        {error, _} ->
            ok
    end.

-spec send_payload_too_large(roadrunner_transport:socket()) -> ok | {error, term()}.
send_payload_too_large(Socket) ->
    Resp = roadrunner_http1:response(
        413,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    roadrunner_transport:send(Socket, Resp).

-doc false.
-spec send_not_found(roadrunner_transport:socket()) -> ok | {error, term()}.
send_not_found(Socket) ->
    Resp = roadrunner_http1:response(
        404,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    roadrunner_transport:send(Socket, Resp).

-doc false.
-spec send_request_timeout(roadrunner_transport:socket()) -> ok | {error, term()}.
send_request_timeout(Socket) ->
    Resp = roadrunner_http1:response(
        408,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    roadrunner_transport:send(Socket, Resp).

-doc false.
-spec send_internal_error(roadrunner_transport:socket()) -> ok | {error, term()}.
send_internal_error(Socket) ->
    Resp = roadrunner_http1:response(
        500,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    roadrunner_transport:send(Socket, Resp).
