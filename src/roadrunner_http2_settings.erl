-module(roadrunner_http2_settings).
-moduledoc """
HTTP/2 SETTINGS state and frame helpers (RFC 9113 §6.5).

A SETTINGS frame carries zero or more 6-byte parameter records:
2-byte identifier + 4-byte value. The frame applies to the connection
as a whole (stream id MUST be 0). The receiver records the new
values and replies with a SETTINGS frame whose ACK flag is set
(payload empty).

This module is Phase H2 of the HTTP/2 plan — enough to negotiate the
preamble and answer ACK requirements. Validation of obvious value
ranges (negative `INITIAL_WINDOW_SIZE`, zero `MAX_FRAME_SIZE`, etc.)
arrives with the full frame codec in Phase H3 and the stream state
machine in Phase H5.

The known parameter identifiers per RFC 9113 §6.5.2:

| id | name                             | default     |
|----|----------------------------------|-------------|
| 1  | `SETTINGS_HEADER_TABLE_SIZE`     | 4096        |
| 2  | `SETTINGS_ENABLE_PUSH`           | 1           |
| 3  | `SETTINGS_MAX_CONCURRENT_STREAMS`| (no limit)  |
| 4  | `SETTINGS_INITIAL_WINDOW_SIZE`   | 65535       |
| 5  | `SETTINGS_MAX_FRAME_SIZE`        | 16384       |
| 6  | `SETTINGS_MAX_HEADER_LIST_SIZE`  | (no limit)  |

Unknown identifiers MUST be ignored (RFC 9113 §6.5.2 last paragraph)
— preserves forward compatibility with future SETTINGS extensions.
""".

-export([
    new/0,
    apply_payload/2,
    encode_settings/1,
    settings_ack_frame/0,
    initial_settings_frame/1
]).

-export_type([settings/0]).

-record(settings, {
    header_table_size = 4096 :: non_neg_integer(),
    enable_push = 1 :: 0 | 1,
    max_concurrent_streams = infinity :: pos_integer() | infinity,
    initial_window_size = 65535 :: non_neg_integer(),
    max_frame_size = 16384 :: pos_integer(),
    max_header_list_size = infinity :: pos_integer() | infinity
}).

-opaque settings() :: #settings{}.

-doc "Fresh peer settings record initialized to the RFC 9113 §6.5.2 defaults.".
-spec new() -> settings().
new() ->
    #settings{}.

-doc """
Apply a SETTINGS frame's raw payload to `Current`. Returns the
updated record or an error tuple. The frame's ACK flag handling is
the caller's responsibility — this function is for the
non-ACK branch only.

A non-ACK SETTINGS payload is N×6 bytes per RFC 9113 §6.5; any other
length is `FRAME_SIZE_ERROR`. Unknown parameter identifiers are
ignored per §6.5.2 (forward compat).
""".
-spec apply_payload(binary(), settings()) ->
    {ok, settings()} | {error, frame_size_error}.
apply_payload(Payload, Current) when byte_size(Payload) rem 6 =:= 0 ->
    apply_records(Payload, Current);
apply_payload(_, _) ->
    {error, frame_size_error}.

apply_records(<<>>, Acc) ->
    {ok, Acc};
apply_records(<<Id:16, Value:32, Rest/binary>>, Acc) ->
    apply_records(Rest, apply_one(Id, Value, Acc)).

%% RFC 9113 §6.5.2 last paragraph: unknown identifiers MUST be ignored.
%% Per-id range validation lives in `roadrunner_conn_loop_http2`'s
%% `validate_settings/1` which runs against the parsed parameter
%% list before this module is consulted; here we trust the input.
apply_one(1, V, S) -> S#settings{header_table_size = V};
apply_one(2, V, S) -> S#settings{enable_push = V};
apply_one(3, V, S) -> S#settings{max_concurrent_streams = V};
apply_one(4, V, S) -> S#settings{initial_window_size = V};
apply_one(5, V, S) -> S#settings{max_frame_size = V};
apply_one(6, V, S) -> S#settings{max_header_list_size = V};
apply_one(_, _, S) -> S.

-doc """
Build the wire payload for an outbound SETTINGS frame announcing the
*differences* from the protocol defaults. Settings whose value
matches the §6.5.2 default are omitted to keep the frame small.
""".
-spec encode_settings(settings()) -> iodata().
encode_settings(S) ->
    Default = #settings{},
    [
        <<Id:16, Value:32>>
     || {Id, Field} <- known_fields(),
        Value <- [field(Field, S)],
        Value =/= field(Field, Default),
        %% `infinity` is our internal sentinel for "no limit"; it has
        %% no on-the-wire integer representation, so it never gets
        %% encoded. Reaching this when `Value =:= infinity` only
        %% happens if the user explicitly sets a setting back to
        %% `infinity` after a non-default — still a no-op on the wire.
        Value =/= infinity
    ].

%% Walk shape used by `encode_settings/1` — kept here so a future
%% field addition shows up in one place.
known_fields() ->
    [
        {1, header_table_size},
        {2, enable_push},
        {3, max_concurrent_streams},
        {4, initial_window_size},
        {5, max_frame_size},
        {6, max_header_list_size}
    ].

field(header_table_size, S) -> S#settings.header_table_size;
field(enable_push, S) -> S#settings.enable_push;
field(max_concurrent_streams, S) -> S#settings.max_concurrent_streams;
field(initial_window_size, S) -> S#settings.initial_window_size;
field(max_frame_size, S) -> S#settings.max_frame_size;
field(max_header_list_size, S) -> S#settings.max_header_list_size.

-doc """
The ACK SETTINGS frame: type 4, ACK flag set (0x01), zero payload.
Sent by either peer to confirm receipt of a non-ACK SETTINGS frame.
""".
-spec settings_ack_frame() -> binary().
settings_ack_frame() ->
    <<0:24, 4, 1, 0:32>>.

-doc """
Build the full initial SETTINGS frame to send right after the
preface. Carries `encode_settings/1`'s diff payload.
""".
-spec initial_settings_frame(settings()) -> iodata().
initial_settings_frame(Settings) ->
    Payload = iolist_to_binary(encode_settings(Settings)),
    [<<(byte_size(Payload)):24, 4, 0, 0:32>>, Payload].
