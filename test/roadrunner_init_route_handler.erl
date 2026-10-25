-module(roadrunner_init_route_handler).
-moduledoc """
Test-fixture handler that exports `roadrunner_handler:init_route/1` and is a
`roadrunner_ws_handler` too, so its module also carries the WebSocket
`init/1`. `init_route/1` reports each run to the `notify` pid in the route's
state and wraps the state as `{routed, State}`; `#{raise => Reason}` makes it
raise instead. A plain request answers with the state it sees as
`term_to_binary/1`; an upgrade request opens a WebSocket session whose
`init/1` reports to the same pid and sends one `ws-init` text frame.
""".

-behaviour(roadrunner_handler).
-behaviour(roadrunner_ws_handler).

-export([init_route/1, handle/1]).
-export([init/1, handle_frame/2]).

-spec init_route(term()) -> term().
init_route(#{raise := Reason}) ->
    error(Reason);
init_route(#{notify := Pid} = State) ->
    Pid ! {init_route, State},
    {routed, State};
init_route(State) ->
    {routed, State}.

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    State = roadrunner_req:state(Req),
    case roadrunner_req:header(~"upgrade", Req) of
        undefined -> {{200, [], term_to_binary(State)}, Req};
        _ -> {{websocket, ?MODULE, State}, Req}
    end.

-spec init(term()) -> roadrunner_ws_handler:result().
init({routed, #{notify := Pid}} = State) ->
    Pid ! {ws_init, State},
    {reply, [{text, ~"ws-init"}], State}.

-spec handle_frame(roadrunner_ws:frame(), term()) -> roadrunner_ws_handler:result().
handle_frame(_Frame, State) ->
    {ok, State}.
