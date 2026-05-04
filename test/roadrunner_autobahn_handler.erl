-module(roadrunner_autobahn_handler).
-moduledoc """
Echo handler driven by the [Autobahn|Testsuite](https://github.com/crossbario/autobahn-testsuite)
fuzzingclient. Implements both behaviours:

- `roadrunner_handler:handle/1` upgrades any incoming HTTP request to
  a WebSocket session driven by this same module.
- `roadrunner_ws_handler:handle_frame/2` echoes the canonical
  conformance shape: text → text reply, binary → binary reply,
  nothing else. Control frames (close / ping / pong) are auto-handled
  by `roadrunner_ws_session`.

Used by `scripts/autobahn.escript`. Not part of the production
behaviour — only loaded under the test profile.
""".

-behaviour(roadrunner_handler).
-behaviour(roadrunner_ws_handler).

-export([handle/1, handle_frame/2]).

-spec handle(roadrunner_http1:request()) -> roadrunner_handler:result().
handle(Req) ->
    {{websocket, ?MODULE, no_state}, Req}.

-spec handle_frame(roadrunner_ws:frame(), term()) ->
    {reply, [{roadrunner_ws:opcode(), iodata()}], term()}
    | {ok, term()}.
handle_frame(#{opcode := text, payload := P}, State) ->
    {reply, [{text, P}], State};
handle_frame(#{opcode := binary, payload := P}, State) ->
    {reply, [{binary, P}], State};
handle_frame(_Frame, State) ->
    {ok, State}.
