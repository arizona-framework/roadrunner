%% What the HTTP/3 connection loop keeps from the client's control stream
%% (RFC 9114 §6.2.1), owned by `roadrunner_conn_loop_http3`, which checks
%% each control frame against it: the client's SETTINGS (`false` until
%% they arrive, as they must come first), its last MAX_PUSH_ID (`undefined`
%% before one), and the ID of its last GOAWAY (`undefined` before one). Shared
%% with the unit tests that drive the control stream. Private: not part
%% of the roadrunner API.
-record(h3_control, {
    settings = false :: false | map(),
    max_push_id = undefined :: non_neg_integer() | undefined,
    goaway_id = undefined :: non_neg_integer() | undefined
}).
