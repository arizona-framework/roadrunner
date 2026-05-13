-module(roadrunner_bench_cowboy_sse_handler).
-moduledoc """
Cowboy loop handler for `scripts/bench.escript --scenarios server_sent_events`.

Mirror of `roadrunner_bench_sse_handler` for cowboy. Uses the
`cowboy_loop` behaviour: `init/2` opens a streaming reply and
seeds the first emit message; `info/3` walks the counter,
streaming one SSE event per call.
""".

-behaviour(cowboy_loop).

-export([init/2, info/3, terminate/3]).

-define(NUM_EVENTS, 100).

-spec init(cowboy_req:req(), term()) -> {cowboy_loop, cowboy_req:req(), term()}.
init(Req0, _State) ->
    Req = cowboy_req:stream_reply(
        200,
        #{
            ~"content-type" => ~"text/event-stream",
            ~"cache-control" => ~"no-cache",
            %% Force conn close after the stream so the bench's
            %% drain-until-EOF semantics work the same way they do
            %% against roadrunner (whose `{loop, ...}` path closes
            %% the conn on `{stop, State}`).
            ~"connection" => ~"close"
        },
        Req0
    ),
    self() ! {emit, ?NUM_EVENTS},
    {cowboy_loop, Req, 0}.

-spec info(term(), cowboy_req:req(), term()) ->
    {ok, cowboy_req:req(), term()} | {stop, cowboy_req:req(), term()}.
info({emit, 0}, Req, State) ->
    cowboy_req:stream_body(~": end\n\n", fin, Req),
    {stop, Req, State};
info({emit, N}, Req, State) ->
    Data = iolist_to_binary([
        ~"event: tick\ndata: ",
        integer_to_binary(N),
        ~"\n\n"
    ]),
    cowboy_req:stream_body(Data, nofin, Req),
    self() ! {emit, N - 1},
    {ok, Req, State}.

-spec terminate(term(), cowboy_req:req(), term()) -> ok.
terminate(_Reason, _Req, _State) ->
    ok.
