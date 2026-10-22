-module(roadrunner_test_event_handler).
-moduledoc false.

%% Test-only `roadrunner_event_handler` that forwards every event to
%% the `telemetry` library as a `[roadrunner, _, _]` event with
%% measurement and metadata maps, so the suites assert on events with
%% `telemetry_test:attach_event_handlers/2`. It is also the reference
%% for a `telemetry` backed handler outside roadrunner.
%%
%% `start/0` stands in for `application:ensure_all_started(telemetry)`
%% in tests: it starts `telemetry` and makes this module the handler,
%% since most tests drive roadrunner without starting its application.

-behaviour(roadrunner_event_handler).

-export([start/0, handle_event/2]).

-spec start() -> {ok, [atom()]}.
start() ->
    {ok, _} = Started = application:ensure_all_started(telemetry),
    ok = roadrunner_event:put_handler(?MODULE),
    Started.

-spec handle_event(roadrunner_event_handler:event(), term()) -> term().
handle_event(request_start, Req) ->
    StartMono = erlang:monotonic_time(),
    Metadata = request_metadata(Req),
    ok = telemetry:execute(
        [roadrunner, request, start], #{system_time => erlang:system_time()}, Metadata
    ),
    {StartMono, Metadata};
handle_event(request_stop, {{StartMono, Metadata}, Status, Kind}) ->
    telemetry:execute(
        [roadrunner, request, stop],
        #{duration => erlang:monotonic_time() - StartMono},
        Metadata#{status => Status, response_kind => Kind}
    );
handle_event(request_exception, {{StartMono, Metadata}, Class, Reason}) ->
    telemetry:execute(
        [roadrunner, request, exception],
        #{duration => erlang:monotonic_time() - StartMono},
        Metadata#{kind => Class, reason => Reason}
    );
handle_event(request_rejected, {ListenerName, Peer, Reason}) ->
    now_event([roadrunner, request, rejected], #{
        listener_name => ListenerName, peer => Peer, reason => Reason
    });
handle_event(request_throttled, {ListenerName, Reason}) ->
    now_event([roadrunner, request, throttled], #{
        listener_name => ListenerName, reason => Reason
    });
handle_event(response_send_failed, {Phase, Reason}) ->
    now_event(
        [roadrunner, response, send_failed],
        merge_logger_metadata(#{phase => Phase, reason => Reason})
    );
handle_event(listener_accept, {ListenerName, Peer}) ->
    StartMono = erlang:monotonic_time(),
    ok = now_event([roadrunner, listener, accept], #{
        listener_name => ListenerName, peer => Peer
    }),
    {StartMono, ListenerName, Peer};
handle_event(listener_conn_close, {{StartMono, ListenerName, Peer}, RequestsServed}) ->
    telemetry:execute(
        [roadrunner, listener, conn_close],
        #{duration => erlang:monotonic_time() - StartMono},
        #{listener_name => ListenerName, peer => Peer, requests_served => RequestsServed}
    );
handle_event(listener_conn_rejected, {ListenerName, Reason}) ->
    now_event([roadrunner, listener, conn_rejected], #{
        listener_name => ListenerName, reason => Reason
    });
handle_event(listener_accept_error, {ListenerName, Reason}) ->
    now_event([roadrunner, listener, accept_error], #{
        listener_name => ListenerName, reason => Reason
    });
handle_event(slots_reconciled, {ListenerName, Released, CounterWas, LiveConnsBounded}) ->
    now_event([roadrunner, listener, slots_reconciled], #{
        listener_name => ListenerName,
        released => Released,
        counter_was => CounterWas,
        live_conns_bounded => LiveConnsBounded
    });
handle_event(drain_acknowledged, {Req, Deadline}) ->
    now_event([roadrunner, drain, acknowledged], #{
        listener_name => maps:get(listener_name, Req, undefined),
        peer => maps:get(peer, Req, undefined),
        request_id => maps:get(request_id, Req, undefined),
        deadline => Deadline
    });
handle_event(ws_upgrade, {ListenerName, Peer, RequestId, Module}) ->
    Metadata = #{
        listener_name => ListenerName, peer => Peer, request_id => RequestId, module => Module
    },
    ok = now_event([roadrunner, ws, upgrade], Metadata),
    Metadata;
handle_event(ws_frame_in, {Metadata, Opcode, PayloadSize}) ->
    telemetry:execute(
        [roadrunner, ws, frame_in],
        #{system_time => erlang:system_time(), payload_size => PayloadSize},
        Metadata#{opcode => Opcode}
    );
handle_event(ws_frame_out, {Metadata, Opcode, PayloadSize}) ->
    telemetry:execute(
        [roadrunner, ws, frame_out],
        #{system_time => erlang:system_time(), payload_size => PayloadSize},
        Metadata#{opcode => Opcode}
    );
handle_event(ws_frame_rejected, {Metadata, Reason, Size}) ->
    telemetry:execute(
        [roadrunner, ws, frame_rejected],
        #{system_time => erlang:system_time(), size => Size},
        Metadata#{reason => Reason}
    ).

now_event(Event, Metadata) ->
    telemetry:execute(Event, #{system_time => erlang:system_time()}, Metadata).

request_metadata(
    #{
        request_id := RequestId,
        peer := Peer,
        method := Method,
        target := Target,
        scheme := Scheme,
        listener_name := ListenerName
    } = Req
) ->
    Metadata = #{
        request_id => RequestId,
        peer => Peer,
        method => Method,
        path => Target,
        scheme => Scheme,
        listener_name => ListenerName
    },
    case Req of
        %% Resolved behind a trusted proxy (`real_ip`).
        #{client_ip := ClientIP} -> Metadata#{client_ip => ClientIP};
        #{} -> Metadata
    end.

%% The conn's logger process metadata (`request_id`, `peer`, `method`,
%% `path`) when it was set; just `Extra` before it was.
merge_logger_metadata(Extra) ->
    case logger:get_process_metadata() of
        undefined -> Extra;
        Md -> maps:merge(Md, Extra)
    end.
