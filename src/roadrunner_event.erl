-module(roadrunner_event).
-moduledoc false.

%% Event emitters for roadrunner: one function per event, each handing
%% the raw values it is given to the configured
%% `roadrunner_event_handler` (see that module for the event
%% contract). Nothing is measured or built here, so the default
%% `roadrunner_event_noop` handler leaves an event at one
%% `persistent_term` read plus one call.
%%
%% The handler is stored in `persistent_term` by `put_handler/1` when
%% the application starts. A `persistent_term:put` is a global GC
%% scan, so it is written once at boot and never on a hot path; the
%% read falls back to the no-op handler when it was never written
%% (code run without the application started).

-export([
    put_handler/1,
    request_start/1,
    request_stop/3,
    request_exception/4,
    response_send/2,
    listener_accept/2,
    listener_conn_close/3,
    listener_conn_rejected/2,
    listener_accept_error/2,
    request_rejected/3,
    request_throttled/2,
    slots_reconciled/4,
    drain_acknowledged/2,
    ws_upgrade/4,
    ws_frame_in/3,
    ws_frame_out/3,
    ws_frame_rejected/3
]).

-define(HANDLER_KEY, {?MODULE, handler}).

-doc """
Validate `Handler` and make it the handler every event goes to. Fails
with `{invalid_event_handler, Handler}` when it does not export
`handle_event/2`.
""".
-spec put_handler(module()) -> ok.
put_handler(Handler) when is_atom(Handler) ->
    case
        code:ensure_loaded(Handler) =:= {module, Handler} andalso
            erlang:function_exported(Handler, handle_event, 2)
    of
        true -> persistent_term:put(?HANDLER_KEY, Handler);
        false -> error({invalid_event_handler, Handler})
    end.

-spec handler() -> module().
handler() ->
    persistent_term:get(?HANDLER_KEY, roadrunner_event_noop).

%% Hand one event to the handler. The handler is someone else's code
%% running in a connection process, so a raise is contained here: an
%% observability bug must not drop a request or a connection. The
%% handler is logged and swapped for the no-op one, so it can't fail
%% again on every request; the event's value becomes the no-op `ok`.
-spec dispatch(roadrunner_event_handler:event(), term()) -> term().
dispatch(Event, Args) ->
    Handler = handler(),
    try
        Handler:handle_event(Event, Args)
    catch
        Class:Reason:Stack ->
            ok = disable_handler(Handler, Event, Class, Reason, Stack)
    end.

%% Only the first process to see the crash swaps the handler and logs
%% it; others already in flight find it replaced and stay quiet.
-spec disable_handler(module(), roadrunner_event_handler:event(), atom(), term(), list()) ->
    ok.
disable_handler(Handler, Event, Class, Reason, Stack) ->
    case handler() of
        Handler ->
            ok = persistent_term:put(?HANDLER_KEY, roadrunner_event_noop),
            logger:error(#{
                msg => "roadrunner event handler crashed, events are now dropped",
                handler => Handler,
                event => Event,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            });
        _Replaced ->
            ok
    end.

-doc "Emit `request_start` and return the handler's request span.".
-spec request_start(roadrunner_req:request()) -> roadrunner_event_handler:span().
request_start(Req) ->
    dispatch(request_start, Req).

-doc "Emit `request_stop` for the span `request_start/1` returned.".
-spec request_stop(
    roadrunner_event_handler:span(),
    roadrunner_http:status(),
    roadrunner_event_handler:response_kind()
) -> ok.
request_stop(Span, Status, Kind) ->
    _ = dispatch(request_stop, {Span, Status, Kind}),
    ok.

-doc "Emit `request_exception` for the span `request_start/1` returned.".
-spec request_exception(
    roadrunner_event_handler:span(), error | exit | throw, term(), erlang:stacktrace()
) -> ok.
request_exception(Span, Class, Reason, Stacktrace) ->
    _ = dispatch(request_exception, {Span, Class, Reason, Stacktrace}),
    ok.

-doc """
Inspect a primary-write `gen_tcp:send`/`ssl:send` result. On `ok`,
this is a no-op. On `{error, _}`, it emits `response_send_failed` with
the `Phase` tag, then logs `?LOG_NOTICE`. The original send result is
returned so callers can chain.
""".
-spec response_send(ok | {error, term()}, atom()) -> ok | {error, term()}.
response_send(ok, _Phase) ->
    ok;
response_send({error, Reason} = Err, Phase) ->
    _ = dispatch(response_send_failed, {Phase, Reason}),
    logger:notice(#{
        msg => "roadrunner response send failed",
        phase => Phase,
        reason => Reason
    }),
    Err.

-doc "Emit `listener_accept` and return the handler's connection span.".
-spec listener_accept(atom(), roadrunner_event_handler:peer()) ->
    roadrunner_event_handler:span().
listener_accept(ListenerName, Peer) ->
    dispatch(listener_accept, {ListenerName, Peer}).

-doc "Emit `listener_conn_close` for the span `listener_accept/2` returned.".
-spec listener_conn_close(
    roadrunner_event_handler:span(), non_neg_integer(), roadrunner_event_handler:close_reason()
) -> ok.
listener_conn_close(Span, RequestsServed, Reason) ->
    _ = dispatch(listener_conn_close, {Span, RequestsServed, Reason}),
    ok.

-doc "Emit `listener_conn_rejected` for a connection dropped at `max_clients`.".
-spec listener_conn_rejected(atom(), max_clients) -> ok.
listener_conn_rejected(ListenerName, Reason) ->
    _ = dispatch(listener_conn_rejected, {ListenerName, Reason}),
    ok.

-doc """
Emit `listener_accept_error` for a failed `accept/1`, TLS handshake,
or PROXY-header read.
""".
-spec listener_accept_error(atom(), term()) -> ok.
listener_accept_error(ListenerName, Reason) ->
    _ = dispatch(listener_accept_error, {ListenerName, Reason}),
    ok.

-doc "Emit `request_rejected` for a request dropped by the parser or a limit.".
-spec request_rejected(atom(), roadrunner_event_handler:peer(), term()) -> ok.
request_rejected(ListenerName, Peer, Reason) ->
    _ = dispatch(request_rejected, {ListenerName, Peer, Reason}),
    ok.

-doc "Emit `request_throttled` for a request refused at a listener limit.".
-spec request_throttled(atom(), max_concurrent_requests | rate_limit) -> ok.
request_throttled(ListenerName, Reason) ->
    _ = dispatch(request_throttled, {ListenerName, Reason}),
    ok.

-doc "Emit `slots_reconciled` when the reaper releases orphan slots.".
-spec slots_reconciled(atom(), pos_integer(), non_neg_integer(), non_neg_integer()) -> ok.
slots_reconciled(ListenerName, Released, CounterWas, LiveConnsBounded) ->
    _ = dispatch(
        slots_reconciled, {ListenerName, Released, CounterWas, LiveConnsBounded}
    ),
    ok.

-doc "Emit `drain_acknowledged` for a handler winding down for a drain.".
-spec drain_acknowledged(roadrunner_req:request(), integer() | undefined) -> ok.
drain_acknowledged(Req, Deadline) ->
    _ = dispatch(drain_acknowledged, {Req, Deadline}),
    ok.

-doc "Emit `ws_upgrade` and return the handler's WebSocket span.".
-spec ws_upgrade(atom(), roadrunner_event_handler:peer(), binary() | undefined, module()) ->
    roadrunner_event_handler:span().
ws_upgrade(ListenerName, Peer, RequestId, Module) ->
    dispatch(ws_upgrade, {ListenerName, Peer, RequestId, Module}).

-doc "Emit `ws_frame_in` for one parsed inbound frame.".
-spec ws_frame_in(roadrunner_event_handler:span(), roadrunner_ws:opcode(), non_neg_integer()) ->
    ok.
ws_frame_in(Span, Opcode, PayloadSize) ->
    _ = dispatch(ws_frame_in, {Span, Opcode, PayloadSize}),
    ok.

-doc "Emit `ws_frame_out` for one outbound frame.".
-spec ws_frame_out(roadrunner_event_handler:span(), roadrunner_ws:opcode(), non_neg_integer()) ->
    ok.
ws_frame_out(Span, Opcode, PayloadSize) ->
    _ = dispatch(ws_frame_out, {Span, Opcode, PayloadSize}),
    ok.

-doc "Emit `ws_frame_rejected` when an inbound size cap is exceeded.".
-spec ws_frame_rejected(
    roadrunner_event_handler:span(), max_frame_size | max_message_size, non_neg_integer()
) -> ok.
ws_frame_rejected(Span, Reason, Size) ->
    _ = dispatch(ws_frame_rejected, {Span, Reason, Size}),
    ok.
