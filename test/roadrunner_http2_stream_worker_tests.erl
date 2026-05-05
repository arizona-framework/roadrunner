-module(roadrunner_http2_stream_worker_tests).
-include_lib("eunit/include/eunit.hrl").

%% h2 worker mirrors the h1 path's `set_request_logger_metadata/1`
%% call so any `?LOG_*` from inside a handler running under h2 has
%% `request_id` (and `method`/`path`/`peer`) attached. Without the
%% call, an h2 handler's logs are uncorrelated.
%%
%% Drives the worker directly: the test process plays the conn,
%% receives the worker's `{h2_send_response, ...}`, acks it, and
%% decodes the probe handler's body to inspect the logger metadata
%% the worker installed.
logger_metadata_set_in_h2_worker_test_() ->
    {spawn, fun() ->
        StreamId = 1,
        ConnPid = self(),
        Req = #{
            method => ~"GET",
            target => ~"/",
            version => {2, 0},
            headers => [{~"host", ~"x"}],
            body => <<>>,
            bindings => #{},
            peer => {{127, 0, 0, 1}, 12345},
            scheme => https,
            request_id => ~"deadbeefdeadbeef",
            listener_name => http2_worker_md_test
        },
        ProtoOpts = #{
            dispatch => {handler, roadrunner_logger_probe_handler},
            middlewares => []
        },
        {_WorkerPid, _MonRef} = roadrunner_http2_stream_worker:start(
            ConnPid, StreamId, Req, ProtoOpts
        ),
        Body = recv_response_body(StreamId),
        ok = recv_worker_done(StreamId),
        Probe = binary_to_term(Body, [safe]),
        Md = maps:get(logger_metadata, Probe),
        ?assertEqual(~"deadbeefdeadbeef", maps:get(request_id, Md)),
        ?assertEqual(~"GET", maps:get(method, Md)),
        ?assertEqual(~"/", maps:get(path, Md)),
        ?assertEqual({{127, 0, 0, 1}, 12345}, maps:get(peer, Md))
    end}.

recv_response_body(StreamId) ->
    receive
        {h2_send_response, From, Ref, StreamId, _Status, _Headers, Bin} ->
            From ! {h2_send_ack, Ref},
            Bin
    after 1000 ->
        error(no_h2_send_response)
    end.

recv_worker_done(StreamId) ->
    receive
        {h2_worker_done, StreamId} -> ok
    after 1000 ->
        error(no_h2_worker_done)
    end.
