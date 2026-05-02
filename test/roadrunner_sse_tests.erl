-module(roadrunner_sse_tests).

-include_lib("eunit/include/eunit.hrl").

event_data_only_test() ->
    ?assertEqual(
        ~"data: hello\n\n",
        iolist_to_binary(roadrunner_sse:event(~"hello"))
    ).

event_empty_data_test() ->
    ?assertEqual(
        ~"data: \n\n",
        iolist_to_binary(roadrunner_sse:event(~""))
    ).

event_with_name_test() ->
    ?assertEqual(
        ~"event: reload\ndata: \n\n",
        iolist_to_binary(roadrunner_sse:event(~"reload", ~""))
    ).

event_with_name_and_payload_test() ->
    ?assertEqual(
        ~"event: ping\ndata: pong\n\n",
        iolist_to_binary(roadrunner_sse:event(~"ping", ~"pong"))
    ).

event_with_id_test() ->
    ?assertEqual(
        ~"event: msg\nid: 42\ndata: hello\n\n",
        iolist_to_binary(roadrunner_sse:event(~"msg", ~"hello", ~"42"))
    ).

%% Per the SSE spec: each newline in `data` becomes its own `data:` line.
event_multiline_data_test() ->
    ?assertEqual(
        ~"data: line one\ndata: line two\ndata: line three\n\n",
        iolist_to_binary(roadrunner_sse:event(~"line one\nline two\nline three"))
    ).

event_with_name_and_multiline_data_test() ->
    ?assertEqual(
        ~"event: log\ndata: hello\ndata: world\n\n",
        iolist_to_binary(roadrunner_sse:event(~"log", ~"hello\nworld"))
    ).

comment_test() ->
    ?assertEqual(
        ~": keepalive\n\n",
        iolist_to_binary(roadrunner_sse:comment(~"keepalive"))
    ).

comment_empty_test() ->
    ?assertEqual(
        ~": \n\n",
        iolist_to_binary(roadrunner_sse:comment(~""))
    ).

retry_test() ->
    ?assertEqual(
        ~"retry: 5000\n\n",
        iolist_to_binary(roadrunner_sse:retry(5000))
    ).

%% --- line-break injection defenses ---

event_with_newline_in_name_rejected_test() ->
    %% A `\n` in the event name would terminate the field early and
    %% leak the rest of the input as a separate SSE line.
    ?assertError(
        {sse_line_break, event_name, _},
        roadrunner_sse:event(~"my\nevent", ~"data")
    ).

event_with_cr_in_name_rejected_test() ->
    ?assertError(
        {sse_line_break, event_name, _},
        roadrunner_sse:event(~"my\revent", ~"data")
    ).

event_with_newline_in_id_rejected_test() ->
    ?assertError(
        {sse_line_break, event_id, _},
        roadrunner_sse:event(~"name", ~"data", ~"id\nbad")
    ).

comment_with_newline_rejected_test() ->
    ?assertError(
        {sse_line_break, comment, _},
        roadrunner_sse:comment(~"line1\nline2")
    ).

%% Data is exempt: multi-line content splits into multiple `data:` lines.
event_data_with_newline_splits_into_multiple_data_lines_test() ->
    ?assertEqual(
        ~"data: line one\ndata: line two\n\n",
        iolist_to_binary(roadrunner_sse:event(~"line one\nline two"))
    ).
