-module(roadrunner_http2_stream_response).
-moduledoc """
HTTP/2 `{stream, ...}` response — body delivered as one or more
DATA frames, with optional trailers as a closing HEADERS frame.

Mirrors `roadrunner_stream_response` so the handler-facing
`Send/2` API stays protocol-agnostic. Translation table:

| `Send(Data, FinFlag)` | h1 wire | h2 wire |
|---|---|---|
| `Send(Data, nofin)` | one chunk | DATA, no END_STREAM |
| `Send(Data, fin)` | chunk + `0\\r\\n\\r\\n` | DATA + END_STREAM |
| `Send(Data, {fin, Trailers})` | chunk + `0` + trailers | DATA + HEADERS + END_STREAM |

Empty data is special-cased to match the h1 behavior:
- `Send(<<>>, nofin)` is a no-op (no zero-length DATA frame).
- `Send(<<>>, fin)` emits an empty DATA frame with END_STREAM.
- `Send(<<>>, {fin, Trailers})` emits the trailer HEADERS frame
  (with END_STREAM) and no DATA.

The `Send` callback runs synchronously in the conn process and
blocks on `WINDOW_UPDATE` whenever the conn or stream send
window can't fit the next chunk (RFC 9113 §6.9). Conn-loop
state is threaded through Send via the process dictionary —
the h1-parity Send shape can't return state, and there is at
most one in-flight stream (Phase H7 keeps `MAX_CONCURRENT_STREAMS
= 1`).

If the handler returns without calling `Send(_, fin)` /
`{fin, _}` we auto-close the stream with an empty DATA frame so
the peer doesn't see a half-open stream.
""".

-export([run/4]).

%% Process-dict key for the conn `#loop{}` threaded through Send.
-define(STATE_KEY, '$roadrunner_http2_stream_state').
%% Process-dict flag set once Send observed a fin variant.
-define(FIN_KEY, '$roadrunner_http2_stream_fin').

-doc """
Send the response HEADERS (no `END_STREAM`), invoke the user's
stream fun with a `Send/2` callback, then return the updated
conn state. If the handler never finished the stream explicitly,
we close it with an empty `END_STREAM` DATA frame.
""".
-spec run(
    State :: term(),
    roadrunner_http:status(),
    roadrunner_http:headers(),
    roadrunner_handler:stream_fun()
) -> term().
run(State0, Status, Headers, Fun) ->
    State1 = roadrunner_conn_loop_http2:send_response_headers(
        State0, Status, Headers, false
    ),
    put(?STATE_KEY, State1),
    erase(?FIN_KEY),
    Send = fun do_send/2,
    _ = Fun(Send),
    case erase(?FIN_KEY) of
        true -> ok;
        _ -> do_send(<<>>, fin)
    end,
    erase(?STATE_KEY).

do_send(Data, nofin) ->
    case iolist_size(Data) of
        0 ->
            ok;
        _ ->
            send_body(iolist_to_binary(Data), false),
            ok
    end;
do_send(Data, fin) ->
    send_body(iolist_to_binary(Data), true),
    put(?FIN_KEY, true),
    ok;
do_send(Data, {fin, Trailers}) ->
    case iolist_size(Data) of
        0 -> ok;
        _ -> send_body(iolist_to_binary(Data), false)
    end,
    State0 = get(?STATE_KEY),
    State1 = roadrunner_conn_loop_http2:send_trailers(State0, Trailers),
    put(?STATE_KEY, State1),
    put(?FIN_KEY, true),
    ok.

send_body(Bin, EndStream) ->
    State0 = get(?STATE_KEY),
    State1 = roadrunner_conn_loop_http2:send_data_sync(State0, Bin, EndStream),
    put(?STATE_KEY, State1).
