-module(cactus_conn).
-moduledoc """
HTTP/1.1 connection process — one per accepted TCP/TLS connection.

Reads bytes off the transport, drives `cactus_http1:parse_request/1`
incrementally, dispatches to the configured `cactus_handler` (either
directly or via `cactus_router`), and writes the response back.

Supports HTTP/1.1 keep-alive (capped by `max_keep_alive_request`,
idle-bound by `keep_alive_timeout`), the four handler return shapes
(`{Status, Headers, Body}`, `{stream, ...}`, `{loop, ...}`,
`{websocket, ...}`), `Expect: 100-continue`, HEAD body suppression,
and a per-conn anti-Slowloris rate check (`minimum_bytes_per_second`).

Sends `400 Bad Request` on parse failure, `408` on first-request
silence, `413` on oversized bodies, and `500` on handler crashes.
Idle keep-alive timeouts and slow-client rate violations close the
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
    consume_body_state/2
]).

-export_type([proto_opts/0, dispatch/0, body_state/0]).

-type dispatch() ::
    {handler, module()}
    | {router, ListenerName :: atom()}.

-type proto_opts() :: #{
    dispatch := dispatch(),
    middlewares := cactus_middleware:middleware_list(),
    max_content_length := non_neg_integer(),
    request_timeout := non_neg_integer(),
    keep_alive_timeout := non_neg_integer(),
    max_keep_alive_request := pos_integer(),
    max_clients := pos_integer(),
    client_counter := atomics:atomics_ref(),
    requests_counter := atomics:atomics_ref(),
    minimum_bytes_per_second := non_neg_integer(),
    body_buffering := auto | manual,
    listener_name => atom()
}.

%% Opaque body-read state attached to the request in manual buffering
%% mode. `cactus_req:read_body/1,2` consumes from this state; the conn
%% owns the recv closure and tracks how much remains.
%%
%% `pending` holds decoded body bytes that have been parsed off the
%% wire but not yet handed to the caller — used for chunked framing
%% to absorb a chunk's payload across multiple length-bounded calls.
%% `done` flips true once the size-0 last chunk is parsed.
-opaque body_state() :: #{
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

The caller (typically `cactus_acceptor`) must transfer socket
ownership via `cactus_transport:controlling_process/2` and then
send the process the atom `shoot` to release it.
""".
-spec start(cactus_transport:socket(), proto_opts()) -> {ok, pid()}.
start(Socket, ProtoOpts) when is_map(ProtoOpts) ->
    ListenerName = maps:get(listener_name, ProtoOpts, undefined),
    Pid = proc_lib:spawn(fun() ->
        %% Initial label — `Peer` isn't available yet because the socket
        %% transfer hasn't happened. `serve/2` refines once peername is
        %% known so `observer` shows `{cactus_conn, ListenerName, Peer}`.
        proc_lib:set_label({cactus_conn, ListenerName}),
        join_drain_group(ListenerName),
        try
            receive
                shoot -> serve_lifecycle(Socket, ProtoOpts, ListenerName)
            end
        after
            release_slot(ProtoOpts)
        end
    end),
    {ok, Pid}.

%% Bracket the per-conn lifetime with `[cactus, listener, accept]` /
%% `[cactus, listener, conn_close]` telemetry. The accept event lets
%% subscribers count incoming connections; the conn_close event reports
%% the connection's wall-clock duration and how many keep-alive requests
%% it served.
-spec serve_lifecycle(cactus_transport:socket(), proto_opts(), atom()) -> ok.
serve_lifecycle(Socket, ProtoOpts, ListenerName) ->
    Peer = peer(Socket),
    StartMono = cactus_telemetry:listener_accept(#{
        listener_name => ListenerName, peer => Peer
    }),
    Count = serve(Socket, ProtoOpts, Peer),
    cactus_telemetry:listener_conn_close(StartMono, #{
        listener_name => ListenerName, peer => Peer, requests_served => Count
    }),
    ok.

%% Join the per-listener `pg` group so `cactus_listener:drain/2` can
%% broadcast a `{cactus_drain, Deadline}` notification to every active
%% conn. `pg` removes us automatically when this process exits. The
%% `pg` scope is started by `cactus_sup`; in tests that drive
%% `cactus_listener:start_link/2` directly without starting the
%% application, the scope is absent and we silently skip the join —
%% drain will simply not see those conns.
-spec join_drain_group(atom()) -> ok.
join_drain_group(undefined) ->
    ok;
join_drain_group(Name) ->
    case whereis(pg) of
        undefined -> ok;
        _ -> pg:join({cactus_drain, Name}, self())
    end.

-doc """
Try to bump the live-connection counter under `max_clients`. Returns
`true` on success (caller may proceed to spawn a conn), `false` if
the cap is already met (caller must close the accepted socket).

The check is racy by a small amount: between increment and rollback
multiple acceptors may briefly observe a count slightly above the
cap, but the count is corrected immediately by the rollback. The
overshoot is at most `num_acceptors - 1` — bounded and harmless.
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

-spec serve(
    cactus_transport:socket(),
    proto_opts(),
    {inet:ip_address(), inet:port_number()} | undefined
) -> non_neg_integer().
serve(Socket, ProtoOpts, Peer) ->
    refine_conn_label(ProtoOpts, Peer),
    Scheme = scheme(Socket),
    Count = serve_loop(Socket, Peer, Scheme, ProtoOpts, 0),
    _ = cactus_transport:close(Socket),
    Count.

-spec refine_conn_label(
    proto_opts(), {inet:ip_address(), inet:port_number()} | undefined
) -> ok.
refine_conn_label(ProtoOpts, Peer) ->
    ListenerName = maps:get(listener_name, ProtoOpts, undefined),
    proc_lib:set_label({cactus_conn, ListenerName, Peer}),
    ok.

%% 64 random bits in lowercase hex — collision-resistant for billions of
%% requests, short enough to embed in log lines.
-spec generate_request_id() -> binary().
generate_request_id() ->
    binary:encode_hex(crypto:strong_rand_bytes(8), lowercase).

%% Replaces (not merges) the conn process's logger metadata so a
%% keep-alive request never inherits the previous request's correlation.
-spec set_request_logger_metadata(cactus_http1:request()) -> ok.
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

-spec serve_loop(
    cactus_transport:socket(), term(), http | https, proto_opts(), non_neg_integer()
) -> non_neg_integer().
serve_loop(_Socket, _Peer, _Scheme, #{max_keep_alive_request := Max}, Count) when Count >= Max ->
    Count;
serve_loop(Socket, Peer, Scheme, ProtoOpts, Count) ->
    case drain_pending() of
        true ->
            %% Listener is draining — finish the in-flight pipeline by
            %% closing instead of looking for the next keep-alive request.
            Count;
        false ->
            do_serve_loop(Socket, Peer, Scheme, ProtoOpts, Count)
    end.

-spec do_serve_loop(
    cactus_transport:socket(), term(), http | https, proto_opts(), non_neg_integer()
) -> non_neg_integer().
do_serve_loop(Socket, Peer, Scheme, ProtoOpts, Count) ->
    %% First request on a fresh connection: bounded by request_timeout, and
    %% a silent client gets a 408. Idle wait between keep-alive requests:
    %% bounded by keep_alive_timeout, and an idle client just gets the
    %% socket closed silently — no 408 to a peer that wasn't going to read it.
    {Timeout, Phase} =
        case Count of
            0 -> {maps:get(request_timeout, ProtoOpts), first};
            _ -> {maps:get(keep_alive_timeout, ProtoOpts), keep_alive}
        end,
    %% `process_one` returns whether the response was the keep-alive
    %% kind or the close kind, plus whether a request was actually
    %% served (parse failure / silent-timeout / slow-client kicks
    %% don't count as served — the listener's `requests_counter`
    %% atomic skips them too, so the per-conn count stays consistent).
    case process_one(Socket, Peer, Scheme, ProtoOpts, Timeout, Phase) of
        {keep_alive, served} ->
            serve_loop(Socket, Peer, Scheme, ProtoOpts, Count + 1);
        {close, served} ->
            Count + 1;
        {close, unserved} ->
            Count
    end.

%% Non-blocking mailbox peek for a `{cactus_drain, _}` broadcast from
%% `cactus_listener:drain/2`. Checked between requests on a keep-alive
%% conn so an in-flight request always finishes, but the next one is
%% never started.
-spec drain_pending() -> boolean().
drain_pending() ->
    receive
        {cactus_drain, _Deadline} -> true
    after 0 ->
        false
    end.

-spec process_one(
    cactus_transport:socket(),
    term(),
    http | https,
    proto_opts(),
    non_neg_integer(),
    first | keep_alive
) -> {keep_alive | close, served | unserved}.
process_one(
    Socket,
    Peer,
    Scheme,
    #{
        dispatch := Dispatch,
        middlewares := ListenerMws,
        max_content_length := MaxCL,
        minimum_bytes_per_second := MinRate,
        body_buffering := BodyBuffering,
        requests_counter := ReqCounter
    } = ProtoOpts,
    Timeout,
    Phase
) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    Recv = make_recv(Socket, Deadline, MinRate),
    case parse_loop(<<>>, Recv) of
        {ok, Req0, Buffered} ->
            %% Bump the listener's requests-served counter as soon as
            %% headers parse — counts everything that reaches the
            %% dispatch pipeline (including 404 from the router and
            %% 413 from oversized bodies), excludes parse errors and
            %% silent slow-client closes.
            _ = atomics:add(ReqCounter, 1, 1),
            RequestId = generate_request_id(),
            Req = Req0#{
                peer => Peer,
                scheme => Scheme,
                request_id => RequestId,
                listener_name => maps:get(listener_name, ProtoOpts, undefined)
            },
            ok = set_request_logger_metadata(Req),
            ok = maybe_send_continue(Socket, Req, Buffered),
            Action = handle_with_body(
                Socket, Req, Buffered, Recv, MaxCL, Dispatch, ListenerMws, BodyBuffering
            ),
            {Action, served};
        {error, request_timeout} ->
            _ = maybe_send_request_timeout(Socket, Phase),
            {close, unserved};
        {error, slow_client} ->
            {close, unserved};
        {error, _} ->
            _ = send_bad_request(Socket),
            {close, unserved}
    end.

-spec maybe_send_request_timeout(cactus_transport:socket(), first | keep_alive) ->
    ok | {error, term()}.
maybe_send_request_timeout(Socket, first) -> send_request_timeout(Socket);
maybe_send_request_timeout(_Socket, keep_alive) -> ok.

%% Auto mode: read the body upfront, hand the handler the buffered
%% bytes via `req#{body}`. Manual mode: skip the upfront read, embed a
%% `body_state` in the request so the handler can call
%% `cactus_req:read_body/1,2`. Manual mode does not keep-alive — the
%% conn would have to drain whatever the handler skipped, which we
%% defer until arizona surfaces a need.
-spec handle_with_body(
    cactus_transport:socket(),
    cactus_http1:request(),
    binary(),
    fun(() -> {ok, binary()} | {error, term()}),
    non_neg_integer(),
    dispatch(),
    cactus_middleware:middleware_list(),
    auto | manual
) -> keep_alive | close.
handle_with_body(Socket, Req, Buffered, Recv, MaxCL, Dispatch, ListenerMws, auto) ->
    case read_body(Req, Buffered, Recv, MaxCL) of
        {ok, Body} ->
            ReqWithBody = Req#{body => Body},
            dispatch_resolved(Socket, ReqWithBody, Dispatch, ListenerMws);
        {error, content_length_too_large} ->
            _ = send_payload_too_large(Socket),
            close;
        {error, request_timeout} ->
            _ = send_request_timeout(Socket),
            close;
        {error, slow_client} ->
            close;
        {error, _} ->
            _ = send_bad_request(Socket),
            close
    end;
handle_with_body(Socket, Req, Buffered, Recv, MaxCL, Dispatch, ListenerMws, manual) ->
    case body_framing(Req) of
        {error, _} ->
            _ = send_bad_request(Socket),
            close;
        Framing ->
            BodyState = #{
                framing => Framing,
                buffered => Buffered,
                bytes_read => 0,
                pending => <<>>,
                done => false,
                recv => Recv,
                max => MaxCL
            },
            ReqWithState = Req#{body_state => BodyState},
            dispatch_resolved(Socket, ReqWithState, Dispatch, ListenerMws)
    end.

-spec dispatch_resolved(
    cactus_transport:socket(),
    cactus_http1:request(),
    dispatch(),
    cactus_middleware:middleware_list()
) -> keep_alive | close.
dispatch_resolved(Socket, Req, Dispatch, ListenerMws) ->
    case resolve_handler(Dispatch, Req) of
        {ok, Handler, Bindings, RouteOpts} ->
            FullReq = Req#{bindings => Bindings, route_opts => RouteOpts},
            handle_and_send(Socket, Handler, FullReq, ListenerMws);
        not_found ->
            _ = send_not_found(Socket),
            close
    end.

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
-spec make_recv(cactus_transport:socket(), integer(), non_neg_integer()) ->
    fun(() -> {ok, binary()} | {error, request_timeout | slow_client | term()}).
make_recv(Socket, Deadline, MinRate) ->
    Bytes = atomics:new(1, [{signed, false}]),
    Start = erlang:monotonic_time(millisecond),
    fun() ->
        Now = erlang:monotonic_time(millisecond),
        Remaining = max(0, Deadline - Now),
        case cactus_transport:recv(Socket, 0, Remaining) of
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
-spec peer(cactus_transport:socket()) -> {inet:ip_address(), inet:port_number()} | undefined.
peer(Socket) ->
    case cactus_transport:peername(Socket) of
        {ok, Peer} -> Peer;
        {error, _} -> undefined
    end.

-spec scheme(cactus_transport:socket()) -> http | https.
scheme({gen_tcp, _}) -> http;
scheme({ssl, _}) -> https;
scheme({fake, _}) -> http.

-spec resolve_handler(dispatch(), cactus_http1:request()) ->
    {ok, module(), cactus_router:bindings(), term()} | not_found.
resolve_handler({handler, Mod}, _Req) ->
    {ok, Mod, #{}, undefined};
resolve_handler({router, ListenerName}, Req) ->
    %% Routes are stored in `persistent_term` by `cactus_listener` so
    %% the lookup is O(1) and `cactus_listener:reload_routes/2` can
    %% atomically swap the table without bouncing the listener.
    Compiled = persistent_term:get({cactus_routes, ListenerName}),
    cactus_router:match(cactus_req:path(Req), Compiled).

-doc false.
-spec read_body(
    cactus_http1:request(),
    binary(),
    fun(() -> {ok, binary()} | {error, term()}),
    non_neg_integer()
) ->
    {ok, binary()}
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
            %% Any leftover bytes in `Buffered` are NOT body — they
            %% belong to a pipelined next request (which we currently
            %% drop on the floor; full pipelining support would feed
            %% these into the next `parse_loop` iteration).
            {ok, <<>>};
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
-spec maybe_send_continue(cactus_transport:socket(), cactus_http1:request(), binary()) -> ok.
maybe_send_continue(Socket, Req, Buffered) ->
    case Buffered =:= ~"" andalso has_continue_expectation(Req) of
        true ->
            _ = cactus_transport:send(Socket, ~"HTTP/1.1 100 Continue\r\n\r\n"),
            ok;
        false ->
            ok
    end.

-spec has_continue_expectation(cactus_http1:request()) -> boolean().
has_continue_expectation(Req) ->
    case cactus_req:header(~"expect", Req) of
        undefined -> false;
        Value -> string:lowercase(Value) =:= ~"100-continue"
    end.

-spec body_framing(cactus_http1:request()) ->
    none
    | chunked
    | {content_length, non_neg_integer()}
    | {error, bad_content_length | bad_transfer_encoding}.
body_framing(Req) ->
    case cactus_req:header(~"transfer-encoding", Req) of
        undefined ->
            case content_length(Req) of
                none -> none;
                {ok, N} -> {content_length, N};
                {error, _} = Err -> Err
            end;
        ~"chunked" ->
            chunked;
        _ ->
            {error, bad_transfer_encoding}
    end.

-spec read_body_until(
    non_neg_integer(),
    binary(),
    fun(() -> {ok, binary()} | {error, term()})
) ->
    {ok, binary()} | {error, term()}.
read_body_until(N, Acc, _RecvFun) when byte_size(Acc) >= N ->
    <<Body:N/binary, _/binary>> = Acc,
    {ok, Body};
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
    {ok, binary()} | {error, content_length_too_large | term()}.
read_chunked(Buf, RecvFun, MaxCL, Decoded) ->
    case cactus_http1:parse_chunk(Buf) of
        {ok, last, _Trailers, _Rest} ->
            {ok, <<>>};
        {ok, Data, Rest} ->
            NewDecoded = Decoded + byte_size(Data),
            if
                NewDecoded > MaxCL ->
                    {error, content_length_too_large};
                true ->
                    case read_chunked(Rest, RecvFun, MaxCL, NewDecoded) of
                        {ok, More} -> {ok, <<Data/binary, More/binary>>};
                        {error, _} = E -> E
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
%% `body_state`. Called only on the 4-tuple response path; the conn
%% uses the result to decide whether keep-alive can engage.
-spec drain_body(cactus_http1:request()) -> ok | {error, term()}.
drain_body(#{body_state := BS}) ->
    case consume_body_state(BS, all) of
        {ok, _Bytes, _BS2} -> ok;
        {error, _} = E -> E
    end;
drain_body(_Req) ->
    %% No body_state means the handler hand-built `Req2` without using
    %% manual-mode plumbing. Nothing to drain.
    ok.

-doc """
Consume bytes from a manual-mode `body_state()`. Returns either the
final tail (`{ok, Bytes, NewState}` — the body has been fully drained)
or a partial chunk (`{more, Bytes, NewState}` — more is still pending).
Used by `cactus_req:read_body/1,2`; not part of the public API.

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
    %% Any `buffered` bytes are pipelined-next-request leftovers, not
    %% body bytes — discard rather than leak them to the handler.
    {ok, <<>>, BS#{buffered := <<>>}};
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
    case cactus_http1:parse_chunk(Buf) of
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
    case cactus_http1:parse_chunk(Buf) of
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

-spec content_length(cactus_http1:request()) ->
    none | {ok, non_neg_integer()} | {error, bad_content_length}.
content_length(Req) ->
    case cactus_req:header(~"content-length", Req) of
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
    {ok, cactus_http1:request(), binary()} | {error, term()}.
parse_loop(Buf, RecvFun) ->
    case cactus_http1:parse_request(Buf) of
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

-spec handle_and_send(
    cactus_transport:socket(),
    module(),
    cactus_http1:request(),
    cactus_middleware:middleware_list()
) -> keep_alive | close.
handle_and_send(Socket, Handler, Req, ListenerMws) ->
    %% Listener-level middlewares wrap route-level middlewares wrap handler.
    %% Both lists run "first = outermost"; an empty list is a no-op.
    %% The pipeline returns `{Response, Req2}` — `Req2` is always
    %% threaded back so the conn can drain (in manual mode) and so
    %% response middlewares can rewrite. See `cactus_handler:result/0`.
    RouteMws = route_middlewares(Req),
    HandlerFun = fun(R) -> Handler:handle(R) end,
    Pipeline = cactus_middleware:compose(ListenerMws ++ RouteMws, HandlerFun),
    Metadata = telemetry_metadata(Req),
    StartMono = cactus_telemetry:request_start(Metadata),
    try Pipeline(Req) of
        {Response, Req2} when is_map(Req2) ->
            Result = dispatch_response(Socket, Handler, Req2, Response),
            ok = cactus_telemetry:request_stop(StartMono, Metadata, #{
                status => response_status(Response),
                response_kind => response_kind(Response)
            }),
            Result
    catch
        Class:Reason:Stack ->
            ok = cactus_telemetry:request_exception(StartMono, Metadata, Class, Reason),
            logger:error(#{
                msg => "cactus handler crashed",
                handler => Handler,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            _ = send_internal_error(Socket),
            close
    end.

-spec telemetry_metadata(cactus_http1:request()) -> cactus_telemetry:metadata().
telemetry_metadata(Req) ->
    #{
        request_id => maps:get(request_id, Req),
        peer => maps:get(peer, Req),
        method => maps:get(method, Req),
        path => maps:get(target, Req),
        scheme => maps:get(scheme, Req),
        listener_name => maps:get(listener_name, Req, undefined)
    }.

%% Order matters — `{websocket, _, _}` is a 3-tuple too, so the
%% atom-tagged variants must precede the buffered catch-all.
-spec response_status(cactus_handler:response()) -> cactus_http1:status().
response_status({stream, Status, _, _}) -> Status;
response_status({loop, Status, _, _}) -> Status;
response_status({sendfile, Status, _, _}) -> Status;
response_status({websocket, _, _}) -> 101;
response_status({Status, _, _}) when is_integer(Status) -> Status.

-spec response_kind(cactus_handler:response()) ->
    buffered | stream | loop | sendfile | websocket.
response_kind({stream, _, _, _}) -> stream;
response_kind({loop, _, _, _}) -> loop;
response_kind({sendfile, _, _, _}) -> sendfile;
response_kind({websocket, _, _}) -> websocket;
response_kind({_, _, _}) -> buffered.

-spec route_middlewares(cactus_http1:request()) -> cactus_middleware:middleware_list().
route_middlewares(Req) ->
    case cactus_req:route_opts(Req) of
        #{middlewares := Mws} -> Mws;
        _ -> []
    end.

-spec dispatch_response(
    cactus_transport:socket(),
    module(),
    cactus_http1:request(),
    cactus_handler:response()
) -> keep_alive | close.
dispatch_response(Socket, _Handler, Req, {websocket, Mod, State}) when is_atom(Mod) ->
    _ = upgrade_to_websocket(Socket, Req, Mod, State),
    close;
dispatch_response(Socket, _Handler, _Req, {stream, Status, Headers, Fun}) when
    is_function(Fun, 1)
->
    _ = stream_response(Socket, Status, Headers, Fun),
    close;
dispatch_response(Socket, Handler, _Req, {loop, Status, Headers, LoopState}) when
    is_integer(Status)
->
    _ = loop_response(Socket, Status, Headers, Handler, LoopState),
    close;
dispatch_response(
    Socket, _Handler, Req, {sendfile, Status, Headers, {Filename, Offset, Length}}
) when
    is_integer(Status)
->
    sendfile_response(Socket, Req, Status, Headers, Filename, Offset, Length);
dispatch_response(Socket, _Handler, Req, {Status, Headers, Body}) when is_integer(Status) ->
    RespBody = response_body_for(Req, Body),
    Resp = cactus_http1:response(Status, Headers, RespBody),
    _ = cactus_telemetry:response_send(
        cactus_transport:send(Socket, Resp), buffered_response
    ),
    finish_response(Req, Headers).

-spec sendfile_response(
    cactus_transport:socket(),
    cactus_http1:request(),
    cactus_http1:status(),
    cactus_http1:headers(),
    file:filename_all(),
    non_neg_integer(),
    non_neg_integer()
) -> keep_alive | close.
sendfile_response(Socket, Req, Status, Headers, Filename, Offset, Length) ->
    Head = cactus_http1:response(Status, Headers, ~""),
    _ = cactus_telemetry:response_send(
        cactus_transport:send(Socket, Head), sendfile_response_head
    ),
    %% RFC 9110 §9.3.2: HEAD must not include a message body. The
    %% headers (including Content-Length) match what GET would have
    %% sent, so framing is preserved.
    _ =
        case cactus_req:method(Req) of
            ~"HEAD" ->
                ok;
            _ ->
                cactus_telemetry:response_send(
                    cactus_transport:sendfile(Socket, Filename, Offset, Length),
                    sendfile_body
                )
        end,
    finish_response(Req, Headers).

%% Drain whatever the handler left on the socket so the next request
%% lands cleanly. In auto mode there's nothing to drain (no
%% body_state); in manual mode the conn consumes any unread body.
%% Drain failure (closed peer, malformed body, etc.) → close.
-spec finish_response(cactus_http1:request(), cactus_http1:headers()) -> keep_alive | close.
finish_response(Req, Headers) ->
    case drain_body(Req) of
        ok -> keep_alive_decision(Req, Headers);
        {error, _} -> close
    end.

%% RFC 9110 §9.3.2: a response to HEAD must not include a message body.
%% Headers (including Content-Length) stay as the handler set them, so
%% the framing matches what GET would have returned.
-spec response_body_for(cactus_http1:request(), iodata()) -> iodata().
response_body_for(Req, Body) ->
    case cactus_req:method(Req) of
        ~"HEAD" -> ~"";
        _ -> Body
    end.

%% HTTP/1.0 default close. HTTP/1.1 keep-alive unless either side
%% set Connection: close.
-spec keep_alive_decision(cactus_http1:request(), cactus_http1:headers()) ->
    keep_alive | close.
keep_alive_decision(Req, RespHeaders) ->
    case cactus_req:version(Req) of
        {1, 0} ->
            close;
        {1, 1} ->
            ReqClose = has_close_token(cactus_req:header(~"connection", Req)),
            RespClose = has_close_token(header_value(~"connection", RespHeaders)),
            case ReqClose orelse RespClose of
                true -> close;
                false -> keep_alive
            end
    end.

-spec has_close_token(binary() | undefined) -> boolean().
has_close_token(undefined) ->
    false;
has_close_token(Value) ->
    binary:match(string:lowercase(Value), ~"close") =/= nomatch.

-spec header_value(binary(), cactus_http1:headers()) -> binary() | undefined.
header_value(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, V} -> V;
        false -> undefined
    end.

%% Emit the status line + headers (with `Transfer-Encoding: chunked`
%% prepended), then call the user's stream fun with a Send/2 callback.
%% Each Send call frames its data as one chunk; passing `fin` appends
%% the size-0 terminator. Caller-supplied headers must NOT set
%% Transfer-Encoding or Content-Length.
-spec stream_response(
    cactus_transport:socket(),
    cactus_http1:status(),
    cactus_http1:headers(),
    cactus_handler:stream_fun()
) -> ok | {error, term()}.
stream_response(Socket, Status, UserHeaders, Fun) ->
    Headers = [{~"transfer-encoding", ~"chunked"} | UserHeaders],
    Head = cactus_http1:response(Status, Headers, ~""),
    _ = cactus_telemetry:response_send(
        cactus_transport:send(Socket, Head), stream_response_head
    ),
    Send = fun(Data, FinFlag) ->
        Frame = stream_frame(Data, FinFlag),
        cactus_transport:send(Socket, Frame)
    end,
    _ = Fun(Send),
    ok.

%% Build the wire frame for one chunked-stream emission.
%%
%% **Empty data is special-cased**: a zero-length chunk would encode
%% as `0\r\n\r\n`, which IS the chunked-body terminator — emitting it
%% mid-stream prematurely ends the response. So `Send(<<>>, nofin)`
%% emits nothing, `Send(<<>>, fin)` emits just the terminator (no
%% leading chunk), and `Send(<<>>, {fin, Trailers})` emits just the
%% terminator + trailers.
-spec stream_frame(iodata(), nofin | fin | {fin, cactus_http1:headers()}) -> iodata().
stream_frame(Data, nofin) ->
    case iolist_size(Data) of
        0 -> [];
        N -> [integer_to_binary(N, 16), ~"\r\n", Data, ~"\r\n"]
    end;
stream_frame(Data, fin) ->
    [chunk_or_empty(Data), ~"0\r\n\r\n"];
stream_frame(Data, {fin, Trailers}) ->
    [chunk_or_empty(Data), ~"0\r\n", encode_trailers(Trailers), ~"\r\n"].

-spec chunk_or_empty(iodata()) -> iodata().
chunk_or_empty(Data) ->
    case iolist_size(Data) of
        0 -> [];
        N -> [integer_to_binary(N, 16), ~"\r\n", Data, ~"\r\n"]
    end.

-spec encode_trailers(cactus_http1:headers()) -> iodata().
encode_trailers(Trailers) ->
    %% Trailers go on the wire after the size-0 chunk; the same
    %% header-injection defense the response-line headers get applies
    %% here — a CR/LF in a trailer value lets an attacker inject a
    %% phantom trailer header.
    [
        begin
            ok = cactus_http1:check_header_safe(Name, name),
            ok = cactus_http1:check_header_safe(Value, value),
            [Name, ~": ", Value, ~"\r\n"]
        end
     || {Name, Value} <- Trailers
    ].

%% Emit status + chunked headers, then receive Erlang messages and
%% dispatch each through `Handler:handle_info/3`. Each call gets a
%% `Push(Data)` fun that frames `Data` as one chunk and writes it.
%% On `{stop, _}` we emit the size-0 terminator and return.
-spec loop_response(
    cactus_transport:socket(),
    cactus_http1:status(),
    cactus_http1:headers(),
    module(),
    term()
) -> ok.
loop_response(Socket, Status, UserHeaders, Handler, State) ->
    Headers = [{~"transfer-encoding", ~"chunked"} | UserHeaders],
    Head = cactus_http1:response(Status, Headers, ~""),
    _ = cactus_telemetry:response_send(
        cactus_transport:send(Socket, Head), loop_response_head
    ),
    Push = fun(Data) ->
        %% Same special-case as `stream_frame/2`: zero-length data
        %% would encode as `0\r\n\r\n` — the chunked terminator —
        %% which would end the response mid-loop. Skip empty pushes.
        case iolist_size(Data) of
            0 ->
                ok;
            N ->
                cactus_transport:send(Socket, [
                    integer_to_binary(N, 16),
                    ~"\r\n",
                    Data,
                    ~"\r\n"
                ])
        end
    end,
    info_loop(Socket, Handler, Push, State).

-spec info_loop(cactus_transport:socket(), module(), cactus_handler:push_fun(), term()) -> ok.
info_loop(Socket, Handler, Push, State) ->
    receive
        Info ->
            case Handler:handle_info(Info, Push, State) of
                {ok, NewState} ->
                    info_loop(Socket, Handler, Push, NewState);
                {stop, _NewState} ->
                    _ = cactus_transport:send(Socket, ~"0\r\n\r\n"),
                    ok
            end
    end.

-spec send_bad_request(cactus_transport:socket()) -> ok | {error, term()}.
send_bad_request(Socket) ->
    Resp = cactus_http1:response(
        400,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    cactus_transport:send(Socket, Resp).

-spec send_payload_too_large(cactus_transport:socket()) -> ok | {error, term()}.
send_payload_too_large(Socket) ->
    Resp = cactus_http1:response(
        413,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    cactus_transport:send(Socket, Resp).

-spec send_not_found(cactus_transport:socket()) -> ok | {error, term()}.
send_not_found(Socket) ->
    Resp = cactus_http1:response(
        404,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    cactus_transport:send(Socket, Resp).

-spec send_request_timeout(cactus_transport:socket()) -> ok | {error, term()}.
send_request_timeout(Socket) ->
    Resp = cactus_http1:response(
        408,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    cactus_transport:send(Socket, Resp).

-spec send_internal_error(cactus_transport:socket()) -> ok | {error, term()}.
send_internal_error(Socket) ->
    Resp = cactus_http1:response(
        500,
        [{~"content-length", ~"0"}, {~"connection", ~"close"}],
        ~""
    ),
    cactus_transport:send(Socket, Resp).

%% --- WebSocket upgrade + frame loop ---

-spec upgrade_to_websocket(cactus_transport:socket(), cactus_http1:request(), module(), term()) ->
    ok | {error, term()}.
upgrade_to_websocket(Socket, Req, Mod, State) ->
    case cactus_ws:handshake_response(cactus_req:headers(Req)) of
        {ok, Status, RespHeaders, _} ->
            Resp = cactus_http1:response(Status, RespHeaders, ~""),
            %% If this send fails, the next recv inside ws_loop will return
            %% {error, _} and the loop ends cleanly — no separate handling.
            _ = cactus_telemetry:response_send(
                cactus_transport:send(Socket, Resp), websocket_upgrade_response
            ),
            Ctx = ws_context(Req, Mod),
            ok = cactus_telemetry:ws_upgrade(Ctx),
            ws_loop(Socket, <<>>, Mod, State, Ctx);
        {error, _} ->
            send_bad_request(Socket)
    end.

-spec ws_context(cactus_http1:request(), module()) -> map().
ws_context(Req, Mod) ->
    #{
        listener_name => maps:get(listener_name, Req, undefined),
        peer => maps:get(peer, Req, undefined),
        request_id => maps:get(request_id, Req, undefined),
        module => Mod
    }.

-spec ws_loop(cactus_transport:socket(), binary(), module(), term(), map()) -> ok.
ws_loop(Socket, Buffer, Mod, State, Ctx) ->
    case cactus_ws:parse_frame(Buffer) of
        {ok, Frame, NewBuffer} ->
            ok = cactus_telemetry:ws_frame_in(
                Ctx#{opcode => maps:get(opcode, Frame)},
                payload_size(Frame)
            ),
            handle_ws_frame(Socket, NewBuffer, Mod, State, Ctx, Frame);
        {more, _} ->
            case cactus_transport:recv(Socket, 0, infinity) of
                {ok, Data} ->
                    ws_loop(Socket, <<Buffer/binary, Data/binary>>, Mod, State, Ctx);
                {error, _} ->
                    ok
            end;
        {error, _} ->
            ok
    end.

-spec payload_size(cactus_ws:frame()) -> non_neg_integer().
payload_size(#{payload := P}) -> byte_size(P).

-spec handle_ws_frame(
    cactus_transport:socket(), binary(), module(), term(), map(), cactus_ws:frame()
) -> ok.
handle_ws_frame(Socket, _Buffer, _Mod, _State, Ctx, #{opcode := close}) ->
    ok = send_ws_frame(Socket, Ctx, close, ~""),
    ok;
handle_ws_frame(Socket, Buffer, Mod, State, Ctx, #{opcode := ping, payload := P}) ->
    ok = send_ws_frame(Socket, Ctx, pong, P),
    ws_loop(Socket, Buffer, Mod, State, Ctx);
handle_ws_frame(Socket, Buffer, Mod, State, Ctx, #{opcode := pong}) ->
    %% Server is not pinging clients yet — pong from client is just dropped.
    ws_loop(Socket, Buffer, Mod, State, Ctx);
handle_ws_frame(Socket, Buffer, Mod, State, Ctx, Frame) ->
    case Mod:handle_frame(Frame, State) of
        {reply, OutFrames, NewState} ->
            _ = send_ws_frames(Socket, Ctx, OutFrames),
            ws_loop(Socket, Buffer, Mod, NewState, Ctx);
        {ok, NewState} ->
            ws_loop(Socket, Buffer, Mod, NewState, Ctx);
        {close, _NewState} ->
            ok = send_ws_frame(Socket, Ctx, close, ~""),
            ok
    end.

%% Single outbound frame — wraps `cactus_transport:send/2` with a
%% `[cactus, ws, frame_out]` event so subscribers see every frame the
%% conn writes (auto-pong, close, and unary handler replies).
-spec send_ws_frame(
    cactus_transport:socket(), map(), cactus_ws:opcode(), iodata()
) -> ok.
send_ws_frame(Socket, Ctx, Opcode, Payload) ->
    ok = cactus_telemetry:ws_frame_out(
        Ctx#{opcode => Opcode}, iolist_size(Payload)
    ),
    _ = cactus_transport:send(Socket, cactus_ws:encode_frame(Opcode, Payload, true)),
    ok.

-spec send_ws_frames(
    cactus_transport:socket(), map(), [{cactus_ws:opcode(), iodata()}]
) -> ok | {error, term()}.
send_ws_frames(Socket, Ctx, OutFrames) ->
    %% Emit telemetry per frame so subscribers can count by opcode,
    %% then write the batched frames in a single TCP send to avoid
    %% partial-write fragmentation.
    lists:foreach(
        fun({Op, Payload}) ->
            ok = cactus_telemetry:ws_frame_out(
                Ctx#{opcode => Op}, iolist_size(Payload)
            )
        end,
        OutFrames
    ),
    Iodata = [cactus_ws:encode_frame(Op, Payload, true) || {Op, Payload} <- OutFrames],
    cactus_transport:send(Socket, Iodata).
