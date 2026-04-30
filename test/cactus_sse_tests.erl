-module(cactus_sse_tests).

-include_lib("eunit/include/eunit.hrl").

event_data_only_test() ->
    ?assertEqual(
        ~"data: hello\n\n",
        iolist_to_binary(cactus_sse:event(~"hello"))
    ).

event_empty_data_test() ->
    ?assertEqual(
        ~"data: \n\n",
        iolist_to_binary(cactus_sse:event(~""))
    ).

event_with_name_test() ->
    ?assertEqual(
        ~"event: reload\ndata: \n\n",
        iolist_to_binary(cactus_sse:event(~"reload", ~""))
    ).

event_with_name_and_payload_test() ->
    ?assertEqual(
        ~"event: ping\ndata: pong\n\n",
        iolist_to_binary(cactus_sse:event(~"ping", ~"pong"))
    ).

event_with_id_test() ->
    ?assertEqual(
        ~"event: msg\nid: 42\ndata: hello\n\n",
        iolist_to_binary(cactus_sse:event(~"msg", ~"hello", ~"42"))
    ).

%% Per the SSE spec: each newline in `data` becomes its own `data:` line.
event_multiline_data_test() ->
    ?assertEqual(
        ~"data: line one\ndata: line two\ndata: line three\n\n",
        iolist_to_binary(cactus_sse:event(~"line one\nline two\nline three"))
    ).

event_with_name_and_multiline_data_test() ->
    ?assertEqual(
        ~"event: log\ndata: hello\ndata: world\n\n",
        iolist_to_binary(cactus_sse:event(~"log", ~"hello\nworld"))
    ).

comment_test() ->
    ?assertEqual(
        ~": keepalive\n\n",
        iolist_to_binary(cactus_sse:comment(~"keepalive"))
    ).

comment_empty_test() ->
    ?assertEqual(
        ~": \n\n",
        iolist_to_binary(cactus_sse:comment(~""))
    ).

retry_test() ->
    ?assertEqual(
        ~"retry: 5000\n\n",
        iolist_to_binary(cactus_sse:retry(5000))
    ).
