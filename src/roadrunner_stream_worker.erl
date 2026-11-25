-module(roadrunner_stream_worker).
-moduledoc false.

-include("roadrunner_proto_opts.hrl").
-include("roadrunner_body_reader.hrl").

%% Runs one HTTP/2 or HTTP/3 request inside its stream worker: route it,
%% run the handler pipeline, send the response and emit the request
%% telemetry. Both protocols share this flow; only how a response is put
%% on the stream differs, so each worker implements the two callbacks
%% below and passes its module in.

-export([run/7]).
-export([conn_heap_floor/1, heap_floor/3, floor_spawn_opts/1, spawn_opts/2]).
-export_type([conn_heap_floor/0, floor_spawn_opts/0, heap_floor/0, peer_limit/0, reset_why/0]).

%% Where a `{send, ...}` fun's worker keeps its reductions as its streamed
%% body starts, and the most that body may take for the worker to still
%% learn from it: about one scheduler time slice (see sent_heap_floor/2).
-define(BODY_START_KEY, '$roadrunner_body_start').
-define(SHORT_BODY_REDUCTIONS, 4000).

%% The client's cap in bytes on a response's header section (HTTP/2
%% SETTINGS_MAX_HEADER_LIST_SIZE, HTTP/3 SETTINGS_MAX_FIELD_SECTION_SIZE),
%% or `infinity` when it set none.
-type peer_limit() :: non_neg_integer() | infinity.

%% Why a connection reset a stream, the last element of the message it
%% tells the stream's worker (`{h2_stream_reset, StreamId, Why}` over
%% HTTP/2, `{roadrunner_stream_reset, StreamId, Why}` over HTTP/3): the
%% client reset it, or its connection is closing for a reason of its own
%% (`peer`); the worker's deadline passed
%% (`roadrunner_send_writer:cancel_after/2`, `deadline`); the client held
%% the stream's response back for `send_stall_timeout` (`send_stall`); or
%% the `connection_age` grace ran out (`connection_age_grace`).
-type reset_why() :: peer | deadline | send_stall | connection_age_grace.

%% A listener's `handler_spawn` options made ready for a worker started at
%% a heap floor (see floor_spawn_opts/1): whether the emulator's default
%% `max_heap_size` decides if the floor applies, and the options without
%% `min_heap_size`.
-type floor_spawn_opts() ::
    {default_max_heap_size | own_max_heap_size, [proc_lib:start_spawn_option()]}.

%% The heap floor of a connection: the min_heap_size it starts its stream
%% workers at, in an atomics cell its workers raise (see conn_heap_floor/1).
%% Base is the size workers start at without it, Cap the most it rises to.
-type conn_heap_floor() ::
    {atomics:atomics_ref(), Base :: pos_integer(), Cap :: pos_integer()} | undefined.
%% What a worker gets of it: the floor it starts at, beside the cell, base
%% and cap, and whether it relearns the floor (see heap_floor/3).
-type heap_floor() ::
    {
        atomics:atomics_ref(),
        Floor :: pos_integer(),
        Base :: pos_integer(),
        Cap :: pos_integer(),
        Relearn :: boolean()
    }
    | undefined.

%% Send a complete response (headers and body) on the stream.
-callback send_buffered(
    pid(), non_neg_integer(), roadrunner_http:status(), roadrunner_http:headers(), iodata()
) -> ok.

%% Send the handler's response, returning the status actually sent (which
%% differs from the handler's when the worker overrides a response it
%% cannot send, e.g. 500 for a returned 1xx). It runs in the `of` body of
%% the handler's `try`, which does not catch: if it raises (a stream fun
%% that fails, a sendfile that cannot open its file), no
%% `request_exception` is emitted, the worker exits and the
%% connection resets the stream.
-callback emit_handler_response(
    pid(), non_neg_integer(), module(), roadrunner_handler:response()
) -> roadrunner_http:status().

%% Send an interim 1xx on the stream, for `roadrunner_send:inform/3`.
-callback send_interim(
    pid(), non_neg_integer(), roadrunner_http:status(), roadrunner_http:headers()
) -> ok | {error, term()}.

%% Send a streamed response's head, for `roadrunner_send:stream/3`,
%% returning the body's `Send` and the status actually sent (a 500 when the
%% head could not be).
-callback start_stream(
    pid(), non_neg_integer(), module(), roadrunner_http:status(), roadrunner_http:headers()
) -> {{ok, roadrunner_handler:send_fun()} | {error, term()}, roadrunner_http:status()}.

-spec run(
    module(),
    h2 | h3,
    pid(),
    non_neg_integer(),
    roadrunner_req:request(),
    roadrunner_conn:dispatch(),
    heap_floor()
) -> ok.
run(Worker, Protocol, Conn, StreamId, Req, Dispatch, HeapFloor0) ->
    HeapFloor = start_heap_floor(HeapFloor0),
    %% `dispatch` is set by listener init and always present. The matched
    %% route's `Pipeline` is a pre-composed `next()` fun (listener mws ++
    %% per-route mws, with `state` injected up front if attached, ending in
    %% `fun Handler:handle/1`), built once at compile / `reload_routes/2`
    %% time — we just call it with the request, no per-request closure.
    Span = roadrunner_event:request_start(Req),
    case roadrunner_conn:resolve_handler(Dispatch, Req) of
        {ok, Handler, Bindings, Pipeline, _State, Limits} ->
            case route_body(Limits, Req) of
                #{} = Req1 ->
                    case route_slot(Limits, Protocol, Conn, StreamId) of
                        granted ->
                            invoke(
                                Worker,
                                Protocol,
                                Conn,
                                StreamId,
                                Handler,
                                Pipeline,
                                Req1#{bindings => Bindings},
                                Span,
                                HeapFloor
                            );
                        {refused, RetryAfter} ->
                            ok = Worker:send_buffered(
                                Conn,
                                StreamId,
                                503,
                                [{~"retry-after", integer_to_binary(RetryAfter)}],
                                ~""
                            ),
                            ok = roadrunner_event:request_stop(Span, 503, buffered);
                        reset ->
                            %% The client reset the stream, or its
                            %% connection went, while it waited: nothing is
                            %% left to answer.
                            ok
                    end;
                too_large ->
                    ok = Worker:send_buffered(
                        Conn,
                        StreamId,
                        413,
                        [{~"content-type", ~"text/plain"}],
                        ~"Payload Too Large"
                    ),
                    ok = roadrunner_event:request_stop(Span, 413, buffered)
            end;
        {method_not_allowed, Allowed} ->
            %% Path matched but no route on it answers this method: 405 plus
            %% the `Allow` union, decided before any pipeline runs because the
            %% method gate is a routing decision rather than handler work.
            ok = Worker:send_buffered(
                Conn,
                StreamId,
                405,
                [
                    {~"content-type", ~"text/plain"},
                    {~"allow", roadrunner_conn:allow_header_value(Allowed)}
                ],
                ~"Method Not Allowed"
            ),
            ok = roadrunner_event:request_stop(Span, 405, buffered);
        not_found ->
            ok = Worker:send_buffered(
                Conn, StreamId, 404, [{~"content-type", ~"text/plain"}], ~"Not Found"
            ),
            ok = roadrunner_event:request_stop(Span, 404, buffered)
    end.

%% A stream worker starts with a small heap and grows it over several
%% collections to what its request needs, as an HTTP/1.1 connection did
%% before its heap floor (`roadrunner_conn_loop:raise_heap_floor/1`). A
%% worker lives for one request, so the connection keeps the floor instead:
%% each worker that collected raises the connection's cell, up to the cap,
%% and the workers started after it get the larger size. Every 16th stream
%% relearns: it starts at half the floor, and if it runs without collecting
%% it lowers the cell to that. A connection whose requests got smaller so
%% stops sizing workers for the larger ones, halving the floor every 16
%% streams, while one whose requests still need the floor raises it
%% straight back. A floor under twice the base is kept, since half of it
%% is the base; at the base itself the stream relearns from the base. The
%% other streams keep the floor as they find it: an HTTP/2 client sends
%% many requests at once, so a reset to the base when a relearning stream
%% starts would leave every worker started before the next raise at the
%% base.

%% The connection's cell, or `undefined` when the listener's
%% `handler_spawn.heap_floor` is `false`, its `max` no higher than the
%% base, or the workers have a `max_heap_size` (see max_heap_size_set/1).
-doc false.
-spec conn_heap_floor(roadrunner_conn:proto_opts()) -> conn_heap_floor().
conn_heap_floor(#proto_opts{heap_floor = undefined}) ->
    undefined;
conn_heap_floor(#proto_opts{heap_floor = Cap, handler_spawn_opts = SpawnOpts}) ->
    Base =
        case last_spawn_opt(min_heap_size, SpawnOpts) of
            {min_heap_size, Words} -> Words;
            false -> element(2, erlang:system_info(min_heap_size))
        end,
    case Cap > Base andalso not max_heap_size_set(SpawnOpts) of
        true ->
            Cell = atomics:new(1, []),
            ok = atomics:put(Cell, 1, Base),
            {Cell, Base, Cap};
        false ->
            undefined
    end.

%% Whether workers spawned with `SpawnOpts` have a `max_heap_size`, the
%% listener's or the emulator's default (a size of 0 is no limit). The
%% floor is then off: a raised `min_heap_size` makes every collection
%% hold larger heaps, and no floor under the limit was found that keeps a
%% collection from reaching it, so a worker the limit would let live
%% could be killed because of the floor.
-spec max_heap_size_set([proc_lib:start_spawn_option()]) -> boolean().
max_heap_size_set(SpawnOpts) ->
    Size =
        case last_spawn_opt(max_heap_size, SpawnOpts) of
            {max_heap_size, Words} when is_integer(Words) -> Words;
            {max_heap_size, #{size := Words}} -> Words;
            false -> maps:get(size, erlang:system_info(max_heap_size))
        end,
    Size > 0.

%% A spawn option as the spawn applies it: the last one given wins.
-spec last_spawn_opt(atom(), [proc_lib:start_spawn_option()]) -> tuple() | false.
last_spawn_opt(Key, SpawnOpts) ->
    lists:keyfind(Key, 1, lists:reverse(SpawnOpts)).

%% The floor the next worker starts at: the cell's, or half of it for a
%% relearning stream (every 16th, see above).
-doc false.
-spec heap_floor(conn_heap_floor(), non_neg_integer(), h2 | h3) -> heap_floor().
heap_floor(undefined, _StreamId, _Protocol) ->
    undefined;
heap_floor({Cell, Base, Cap}, StreamId, Protocol) ->
    Floor = atomics:get(Cell, 1),
    case relearn(StreamId, Protocol) of
        true when Floor =:= Base -> {Cell, Base, Base, Cap, true};
        true when Floor div 2 > Base -> {Cell, Floor div 2, Base, Cap, true};
        _ -> {Cell, Floor, Base, Cap, false}
    end.

%% Client-initiated request streams count up by 2 on HTTP/2 (1, 3, 5, ...)
%% and by 4 on HTTP/3 (0, 4, 8, ...): every 16th of them relearns.
-spec relearn(non_neg_integer(), h2 | h3) -> boolean().
relearn(StreamId, h2) -> (StreamId bsr 1) rem 16 =:= 0;
relearn(StreamId, h3) -> (StreamId bsr 2) rem 16 =:= 0.

%% Once spawned at its floor, the worker notes the heap it started with
%% (`Floor` becomes that size, as the emulator rounded it up) and lowers
%% its `min_heap_size` back to the base. That changes nothing until the
%% worker collects, and a collection then sizes the heap for what is live,
%% so a heap no longer the size it started at shows that the worker
%% collected (see raise_heap_floor/1). It also keeps a worker that lives
%% on, such as one streaming a long response, from holding the floor's
%% heap past its first collection. A worker started at the cap only
%% lowers it, as it has nothing to raise.
-spec start_heap_floor(heap_floor()) -> heap_floor().
start_heap_floor({_Cell, Cap, Base, Cap, false} = HeapFloor) ->
    _ = erlang:process_flag(min_heap_size, Base),
    HeapFloor;
start_heap_floor({Cell, Floor, Base, Cap, Relearn}) when Floor > Base ->
    {heap_size, Heap} = erlang:process_info(self(), heap_size),
    _ = erlang:process_flag(min_heap_size, Base),
    {Cell, Heap, Base, Cap, Relearn};
start_heap_floor({Cell, _Floor, Base, Cap, Relearn}) ->
    {heap_size, Heap} = erlang:process_info(self(), heap_size),
    {Cell, Heap, Base, Cap, Relearn};
start_heap_floor(undefined) ->
    undefined.

%% The listener's `handler_spawn` options made ready once, when it starts,
%% for the workers started at a heap floor (spawn_opts/2): without
%% `min_heap_size`, which the floor takes the place of, so the floor can go
%% in front of them; and whether the emulator's default `max_heap_size`
%% decides if the floor applies, which it does when the options set none
%% (one that sets a limit has no floor at all, see conn_heap_floor/1).
-doc false.
-spec floor_spawn_opts([proc_lib:start_spawn_option()]) -> floor_spawn_opts().
floor_spawn_opts(SpawnOpts) ->
    case last_spawn_opt(max_heap_size, SpawnOpts) of
        false -> {default_max_heap_size, without_min_heap_size(SpawnOpts)};
        {max_heap_size, _} -> {own_max_heap_size, without_min_heap_size(SpawnOpts)}
    end.

-spec without_min_heap_size([proc_lib:start_spawn_option()]) ->
    [proc_lib:start_spawn_option()].
without_min_heap_size([{min_heap_size, _} | Rest]) -> without_min_heap_size(Rest);
without_min_heap_size([Opt | Rest]) -> [Opt | without_min_heap_size(Rest)];
without_min_heap_size([]) -> [].

%% The worker's spawn options: the listener's `handler_spawn` ones, and a
%% floor above the base as its `min_heap_size`, in place of the
%% listener's. Spawned at that size, the worker has the heap from the
%% start; setting it after the spawn (`process_flag/2`) would only take
%% effect at the worker's first collection. The emulator's default
%% `max_heap_size` can change while the connection lives
%% (`erlang:system_flag/2`) and applies at each spawn, so where the
%% listener's options set none a worker spawned while one is set gets no
%% floor (see max_heap_size_set/1).
-doc false.
-spec spawn_opts(roadrunner_conn:proto_opts(), heap_floor()) ->
    [proc_lib:start_spawn_option() | monitor].
spawn_opts(
    #proto_opts{floor_spawn_opts = FloorSpawnOpts} = ProtoOpts, {_Cell, Floor, Base, _Cap, _Relearn}
) when
    Floor > Base
->
    floor_spawn_opts(FloorSpawnOpts, ProtoOpts, Floor);
spawn_opts(#proto_opts{handler_spawn_opts = SpawnOpts}, _HeapFloor) ->
    [monitor | SpawnOpts].

-spec floor_spawn_opts(floor_spawn_opts(), roadrunner_conn:proto_opts(), pos_integer()) ->
    [proc_lib:start_spawn_option() | monitor].
floor_spawn_opts({own_max_heap_size, FloorOpts}, _ProtoOpts, Floor) ->
    [monitor, {min_heap_size, Floor} | FloorOpts];
floor_spawn_opts({default_max_heap_size, FloorOpts}, ProtoOpts, Floor) ->
    case erlang:system_info(max_heap_size) of
        #{size := 0} -> [monitor, {min_heap_size, Floor} | FloorOpts];
        #{} -> [monitor | ProtoOpts#proto_opts.handler_spawn_opts]
    end.

%% Sampled once a complete response is sent, by the handler or by a
%% `{send, ...}` fun. A streamed or file response (`stream`, `loop`,
%% `sendfile`, and a fun's `roadrunner_send:stream/3` or `sendfile/4`) is
%% sampled as it starts instead: what comes after is its body going out
%% for as long as the stream lasts, which collects however large the
%% floor, so learning from it would only climb the floor to the cap. The
%% heap's size then says little of what the request needed: a full sweep
%% can shrink the heap back toward what is live, so a request that makes
%% a lot of short-lived garbage
%% ends with a small heap however often it collected. What tells is
%% whether the worker collected at all. A worker that did outgrew its
%% floor, so it raises the cell to half as much again as the larger of its
%% floor and its heap, and the workers after it raise it again until they
%% run without collecting. Most workers read that from their heap's size
%% (start_heap_floor/1), which a collection can leave at the size it
%% started at; a relearning worker reads it exactly, from the data its
%% last collection kept (`recent_size`, 0 until it first collects), and
%% one that did not collect lowers the cell to the floor it started at.
%% That read costs more, so only every 16th stream makes it. Workers
%% ending at once can leave the cell a step off either way; the next
%% relearning or collecting worker moves it again.
-spec raise_heap_floor(heap_floor()) -> ok.
raise_heap_floor(undefined) ->
    ok;
raise_heap_floor({_Cell, Floor, _Base, Cap, false}) when Floor >= Cap ->
    %% Started at the cap: nothing to raise, so skip reading the heap.
    ok;
raise_heap_floor({Cell, Floor, _Base, Cap, false}) ->
    case erlang:process_info(self(), heap_size) of
        {heap_size, Floor} -> ok;
        {heap_size, Heap} -> raise_heap_floor(Cell, Floor, Heap, Cap)
    end;
raise_heap_floor({Cell, Floor, _Base, Cap, true}) ->
    {garbage_collection_info, Info} = erlang:process_info(self(), garbage_collection_info),
    case lists:keyfind(recent_size, 1, Info) of
        {recent_size, 0} ->
            %% Spawned with a large request, the worker can start above
            %% the cap.
            atomics:put(Cell, 1, min(Floor, Cap));
        {recent_size, _} ->
            {heap_block_size, Heap} = lists:keyfind(heap_block_size, 1, Info),
            raise_heap_floor(Cell, Floor, Heap, Cap)
    end.

-spec raise_heap_floor(atomics:atomics_ref(), pos_integer(), pos_integer(), pos_integer()) -> ok.
raise_heap_floor(Cell, Floor, Heap, Cap) ->
    Needed = min(max(Heap, Floor) * 3 div 2, Cap),
    case atomics:get(Cell, 1) of
        Current when Needed > Current -> atomics:put(Cell, 1, Needed);
        _ -> ok
    end.

%% The request held to its route's own `max_content_length`, or `too_large`.
%% The connection holds a buffered body to the listener's cap, raised to the
%% route's when a body outgrows it, so only a route cap tighter than the
%% listener's is left to check on one here, once the request is routed. A
%% body read in manual mode is held to the route's cap as it is read.
%% A slot of the route's own `max_concurrent_requests`, taken before any
%% middleware or the handler runs, and held for as long as this worker
%% lives: the process that monitors it (its HTTP/2 connection, or HTTP/3's
%% loop), or the route's keeper, frees it when the worker exits, however
%% that comes. The stream already holds a slot of the listener's
%% ceiling while it waits here, which `roadrunner_listener` keeps the route
%% queues from filling. A reset of the stream, or its connection going, ends
%% the wait: nobody is left to answer.
-spec route_slot(roadrunner_router:limits(), h2 | h3, pid(), non_neg_integer()) ->
    granted | {refused, pos_integer()} | reset.
route_slot({_Body, Ceiling}, Protocol, Conn, StreamId) ->
    case
        roadrunner_route_keeper:acquire(
            Ceiling, stream_reset(Protocol, StreamId), Conn, slot_owner(Protocol, Conn)
        )
    of
        {ok, _Token} -> granted;
        Refused -> Refused
    end;
route_slot(_Limits, _Protocol, _Conn, _StreamId) ->
    granted.

%% The process that monitors this worker, which frees a slot the worker
%% takes on its own: the HTTP/2 connection, or HTTP/3's loop (`Conn` is then
%% the QUIC connection).
-spec slot_owner(h2 | h3, pid()) -> pid().
slot_owner(h2, Conn) -> Conn;
slot_owner(h3, _Conn) -> roadrunner_http3_stream_worker:loop().

%% The tag and stream id of the message the connection sends a worker
%% whose stream was reset, `{Tag, StreamId, Why}` (`reset_why()`).
-spec stream_reset(h2 | h3, non_neg_integer()) ->
    {h2_stream_reset | roadrunner_stream_reset, non_neg_integer()}.
stream_reset(h2, StreamId) -> {h2_stream_reset, StreamId};
stream_reset(h3, StreamId) -> {roadrunner_stream_reset, StreamId}.

-spec route_body(roadrunner_router:limits(), roadrunner_req:request()) ->
    roadrunner_req:request() | too_large.
route_body(undefined, Req) ->
    Req;
route_body({Max, _Ceiling}, Req) ->
    route_body(Max, Req);
route_body(Max, #{body := Body} = Req) ->
    case iolist_size(Body) > Max of
        true -> too_large;
        false -> Req
    end;
route_body(Max, #{body_reader := #stream_body_reader{} = Reader} = Req) ->
    Req#{body_reader := Reader#stream_body_reader{max = Max}}.

-spec invoke(
    module(),
    h2 | h3,
    pid(),
    non_neg_integer(),
    module(),
    roadrunner_middleware:next(),
    roadrunner_req:request(),
    roadrunner_event_handler:span(),
    heap_floor()
) -> ok.
invoke(
    Worker,
    Protocol,
    Conn,
    StreamId,
    Handler,
    Pipeline,
    #{method := Method} = Req,
    Span,
    HeapFloor
) ->
    try Pipeline(Req) of
        {{send, Headers, Fun}, Req2} when is_list(Headers), is_function(Fun, 1) ->
            run_send(
                Worker, Protocol, Conn, StreamId, Handler, Req2, Headers, Fun, Span, HeapFloor
            );
        {Response0, Req2} ->
            %% A handler-returned 1xx or unsafe header becomes a 500 here,
            %% for every shape (`roadrunner_conn:final_response/3`,
            %% `safe_response/3`). Telemetry reports the status actually
            %% sent. RFC 9110 §9.3.2: a HEAD response carries no content, so
            %% emit the body-stripped form; telemetry keeps the shape before
            %% stripping (`roadrunner_conn:response_kind/1`).
            Response = safe_response(
                Protocol, Handler, roadrunner_conn:final_response(Protocol, Handler, Response0)
            ),
            Final = roadrunner_conn:head_response(Response, Method),
            ok = continue_before(Final, Req2),
            Kind = roadrunner_conn:response_kind(Response),
            Status = emit(Worker, Conn, StreamId, Handler, Final, Kind, HeapFloor),
            ok = roadrunner_event:request_stop(Span, Status, Kind)
    catch
        Class:Reason:Stack ->
            ok = roadrunner_event:request_exception(Span, Class, Reason, Stack),
            logger:error(#{
                msg => crash_message(Protocol),
                handler => Handler,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            ok = Worker:send_buffered(
                Conn, StreamId, 500, [{~"content-type", ~"text/plain"}], ~"Internal Server Error"
            )
    end.

%% Send the handler's response, sampling the heap after a complete one and
%% before a streamed or file one (see raise_heap_floor/1).
-spec emit(
    module(),
    pid(),
    non_neg_integer(),
    module(),
    roadrunner_handler:response(),
    buffered | stream | loop | sendfile | websocket,
    heap_floor()
) -> roadrunner_http:status().
emit(Worker, Conn, StreamId, Handler, Response, Kind, HeapFloor) when
    Kind =:= stream; Kind =:= loop; Kind =:= sendfile
->
    ok = raise_heap_floor(HeapFloor),
    Worker:emit_handler_response(Conn, StreamId, Handler, Response);
emit(Worker, Conn, StreamId, Handler, Response, _Kind, HeapFloor) ->
    Status = Worker:emit_handler_response(Conn, StreamId, Handler, Response),
    ok = raise_heap_floor(HeapFloor),
    Status.

%% A `{send, Headers, Fun}` response: the fun writes the stream itself,
%% as it runs, through `send_emit/4`. It runs under its own `try`
%% (`roadrunner_send_writer:run/5`): a crash before a final response is
%% answered 500, as a handler crash is; one after it leaves the stream to the
%% connection, reset when its body was still open. A transport exit (the
%% stream reset or the connection gone under a write) ends the worker as it
%% does for the `stream` shape, without a report.
-spec run_send(
    module(),
    h2 | h3,
    pid(),
    non_neg_integer(),
    module(),
    roadrunner_req:request(),
    roadrunner_http:headers(),
    roadrunner_send:sender(),
    roadrunner_event_handler:span(),
    heap_floor()
) -> ok.
run_send(Worker, Protocol, Conn, StreamId, Handler, Req, Headers, Fun, Span, HeapFloor) ->
    Emit = send_emit(Worker, Protocol, Conn, StreamId, Handler, HeapFloor),
    case roadrunner_send_writer:run(Handler, Fun, Headers, Req, Emit) of
        {closed, {Kind, Status, _SentHeaders}} ->
            %% The fun stopped on purpose (`{shutdown, _}`): only its stream
            %% ends.
            ok = sent_heap_floor(Kind, HeapFloor),
            roadrunner_event:request_stop(Span, Status, Kind);
        {done, {Kind, Status, _SentHeaders}, _Req2} ->
            ok = sent_heap_floor(Kind, HeapFloor),
            roadrunner_event:request_stop(Span, Status, Kind);
        {crashed, exit, Reason, _Stack, _Sent} when
            Reason =:= stream_reset; Reason =:= conn_down; element(1, Reason) =:= quic_conn_down
        ->
            exit(Reason);
        {crashed, Class, Reason, Stack, Sent} ->
            ok = roadrunner_event:request_exception(Span, Class, Reason, Stack),
            logger:error(#{
                msg => crash_message(Protocol),
                handler => Handler,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            crash_answer(Sent, Worker, Conn, StreamId)
    end.

%% A fun's complete response is sampled once the fun has run; a streamed
%% or file one as it started (`send_emit/6`). A fun's streamed body is
%% sampled again once the fun has run when it took less than about one
%% scheduler time slice of work: a gRPC unary call, which streams its one
%% message and its trailers, still learns from encoding and sending them,
%% while a long stream that keeps sending does not.
-spec sent_heap_floor(buffered | stream | sendfile | websocket, heap_floor()) -> ok.
sent_heap_floor(buffered, HeapFloor) ->
    raise_heap_floor(HeapFloor);
sent_heap_floor(stream, HeapFloor) when HeapFloor =/= undefined ->
    {reductions, Reductions} = erlang:process_info(self(), reductions),
    case get(?BODY_START_KEY) of
        Start when is_integer(Start), Reductions - Start < ?SHORT_BODY_REDUCTIONS ->
            raise_heap_floor(HeapFloor);
        _ ->
            ok
    end;
sent_heap_floor(_Kind, _HeapFloor) ->
    ok.

%% Sample the heap as a fun's streamed body starts, and note the worker's
%% reductions then for sent_heap_floor/2. A relearning worker does not
%% lower the floor yet: a short body is sampled again at its end, where
%% the worker can still collect.
-spec body_started(heap_floor()) -> ok.
body_started(undefined) ->
    ok;
body_started({Cell, Floor, Base, Cap, _Relearn}) ->
    ok = raise_heap_floor({Cell, Floor, Base, Cap, false}),
    {reductions, Reductions} = erlang:process_info(self(), reductions),
    _ = put(?BODY_START_KEY, Reductions),
    ok.

%% A 500 for a fun that crashed before its final response. After a complete
%% one the stream is done; a body still open is reset by the connection on
%% the worker's abnormal exit.
-spec crash_answer(none | complete | open, module(), pid(), non_neg_integer()) -> ok.
crash_answer(none, Worker, Conn, StreamId) ->
    Worker:send_buffered(
        Conn, StreamId, 500, [{~"content-type", ~"text/plain"}], ~"Internal Server Error"
    );
crash_answer(complete, _Worker, _Conn, _StreamId) ->
    ok;
crash_answer(open, _Worker, _Conn, _StreamId) ->
    exit(unfinished_response).

%% `roadrunner_send`'s writer for this stream. A complete or file response
%% goes through the shapes' own send path (`emit_handler_response/4`), so it
%% gets their HEAD and header-limit handling: a status other than the one
%% asked for is the 500 that answered headers over the client's limit. A
%% complete one answers the client, so a 100 Continue still owed is not
%% sent after it (`roadrunner_conn:skip_continue/1`); a stream sends it
%% first.
-spec send_emit(module(), h2 | h3, pid(), non_neg_integer(), module(), heap_floor()) ->
    roadrunner_send_writer:emit().
send_emit(Worker, Protocol, Conn, StreamId, Handler, HeapFloor) ->
    fun
        ({inform, Status, Headers}, _Req) ->
            Worker:send_interim(Conn, StreamId, Status, Headers);
        ({reply, Status, Headers, Body}, #{method := Method} = Req) ->
            ok = roadrunner_conn:skip_continue(Req),
            Response = roadrunner_conn:head_response({Status, Headers, Body}, Method),
            Sent = Worker:emit_handler_response(Conn, StreamId, Handler, Response),
            {sent(Protocol, Status, Sent), Sent, Headers};
        ({sendfile, Status, Headers, Spec}, #{method := Method} = Req) ->
            ok = roadrunner_conn:skip_continue(Req),
            ok = raise_heap_floor(HeapFloor),
            Response = roadrunner_conn:head_response({sendfile, Status, Headers, Spec}, Method),
            Sent = Worker:emit_handler_response(Conn, StreamId, Handler, Response),
            {sent(Protocol, Status, Sent), Sent, Headers};
        ({stream, Status, Headers}, Req) ->
            ok = roadrunner_conn:continue_before_stream(Req),
            ok = body_started(HeapFloor),
            {Result, Sent} = Worker:start_stream(Conn, StreamId, Handler, Status, Headers),
            {Result, Sent, Headers};
        ({websocket, _Mod, _State, _Opts} = Upgrade, _Req) ->
            %% No WebSocket over HTTP/2 or HTTP/3: the 501 a returned
            %% upgrade gets.
            {
                {error, not_supported},
                Worker:emit_handler_response(Conn, StreamId, Handler, Upgrade),
                []
            };
        ({cancel_after, Ms}, _Req) ->
            cancel_after(Protocol, Conn, StreamId, Ms);
        (monitor_connection, _Req) ->
            %% The h2 connection, or the QUIC connection an h3 stream rides
            %% on: either exits when the client's connection goes away.
            {ok, monitor(process, Conn)}
    end.

%% A timer that has the loop holding the stream cancel it: the h2
%% connection (`roadrunner_conn_loop_http2:cancel_stream/3`), or the h3 loop
%% the worker was started from (`roadrunner_conn_loop_http3`), as an h3
%% worker's `Conn` is the QUIC connection.
-spec cancel_after(h2 | h3, pid(), non_neg_integer(), non_neg_integer()) ->
    {ok, reference()}.
cancel_after(Protocol, Conn, StreamId, Ms) ->
    Loop =
        case Protocol of
            h2 -> Conn;
            h3 -> roadrunner_http3_stream_worker:loop()
        end,
    %% `erlang:send_after/3` takes at most 2^32 - 1 ms.
    {ok, erlang:send_after(min(Ms, 16#FFFFFFFF), Loop, {roadrunner_cancel_stream, StreamId})}.

%% A complete response's result: `ok` when its status went out, the
%% header-limit error `start_stream/5` returns when a 500 did instead.
-spec sent(h2 | h3, roadrunner_http:status(), roadrunner_http:status()) ->
    ok | {error, header_list_too_large | field_section_too_large}.
sent(_Protocol, Status, Status) -> ok;
sent(h2, _Status, _Sent) -> {error, header_list_too_large};
sent(h3, _Status, _Sent) -> {error, field_section_too_large}.

%% RFC 9110 §5.5: a response header name or value containing CR, LF or
%% NUL is a handler bug (usually unvalidated user input echoed into a
%% header) that would put malformed bytes on the wire, or split at a
%% downstream h2/h3->h1 reverse proxy. Answer 500 instead, in every
%% shape, before anything is sent; only the kind is logged, never the
%% raw bytes. Checking here, in the worker, keeps the bug on its own
%% stream: the h2 conn process that encodes the headers is shared by
%% every stream of the connection. Connection-specific fields are not
%% rejected here, the send paths strip them.
-spec safe_response(h2 | h3, module(), roadrunner_handler:response()) ->
    roadrunner_handler:response().
safe_response(_Protocol, _Handler, {websocket, _, _} = Response) ->
    Response;
safe_response(_Protocol, _Handler, {websocket, _, _, _} = Response) ->
    Response;
safe_response(Protocol, Handler, Response) ->
    case roadrunner_http:unsafe_header(response_headers(Response)) of
        none ->
            Response;
        Kind ->
            logger:error(#{
                msg => unsafe_message(Protocol),
                handler => Handler,
                kind => Kind
            }),
            {500, [{~"content-type", ~"text/plain"}], ~"Internal Server Error"}
    end.

-spec response_headers(roadrunner_handler:response()) -> roadrunner_http:headers().
response_headers({stream, _, Headers, _}) -> Headers;
response_headers({loop, _, Headers, _}) -> Headers;
response_headers({sendfile, _, Headers, _}) -> Headers;
response_headers({_, Headers, _}) -> Headers.

-spec unsafe_message(h2 | h3) -> string().
unsafe_message(h2) -> "roadrunner h2 handler returned a header with CR/LF/NUL";
unsafe_message(h3) -> "roadrunner h3 handler returned a header with CR/LF/NUL".

%% A response that streams may read the body as it goes: the 100 Continue
%% its client may still be waiting on goes out first
%% (`roadrunner_conn:continue_before_stream/1`).
-spec continue_before(roadrunner_handler:response(), roadrunner_req:request()) -> ok.
continue_before({stream, _Status, _Headers, _Fun}, Req) ->
    roadrunner_conn:continue_before_stream(Req);
continue_before({loop, _Status, _Headers, _State}, Req) ->
    roadrunner_conn:continue_before_stream(Req);
continue_before(_Response, _Req) ->
    ok.

-spec crash_message(h2 | h3) -> string().
crash_message(h2) -> "roadrunner h2 handler crashed";
crash_message(h3) -> "roadrunner h3 handler crashed".
