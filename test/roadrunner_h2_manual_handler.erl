-module(roadrunner_h2_manual_handler).
-moduledoc """
Test fixture for manual body mode over HTTP/2. The route's state picks what
the handler does with the body:

- `read`: read it all and answer with its size (413 with the reason when
  the read fails)
- `reject`: answer 401 without reading it
- `pieces` / `chunks`: read it 4 bytes at a time / chunk by chunk and answer
  `Count:Total`
- `{gated, Name}`: register as `Name`, wait for `go`, then `read`
- `{report, Pid}`: read it and send `Pid` the outcome, `{read_result, _}`
- `{gated_report, Name, Pid}`: `{gated, Name}`, then `{report, Pid}`
- `{answer_first, Name, Pid}`: stream a complete response, then try to read
  the body and send `Pid` the outcome, `{read_after_answer, _}`, then
  register as `Name` and wait for `go`
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    behave(roadrunner_req:state(Req), Req).

behave(read, Req) ->
    case roadrunner_req:read_body(Req) of
        {ok, Body, Req2} -> {roadrunner_resp:text(200, integer_to_binary(iolist_size(Body))), Req2};
        {error, Reason} -> {roadrunner_resp:text(413, atom_to_binary(Reason)), Req}
    end;
behave(reject, Req) ->
    {roadrunner_resp:text(401, ~"no"), Req};
behave(pieces, Req) ->
    count(Req, fun(R) -> roadrunner_req:read_body(R, #{length => 4}) end, 0, 0);
behave(chunks, Req) ->
    count(Req, fun roadrunner_req:read_body_chunked/1, 0, 0);
behave({gated, Name}, Req) ->
    true = register(Name, self()),
    receive
        go -> ok
    end,
    behave(read, Req);
behave({report, Pid}, Req) ->
    Result =
        case roadrunner_req:read_body(Req) of
            {ok, Body, _} -> {ok, iolist_size(Body)};
            {error, _} = E -> E
        end,
    Pid ! {read_result, Result},
    {roadrunner_resp:text(200, ~"ok"), Req};
behave({gated_report, Name, Pid}, Req) ->
    true = register(Name, self()),
    receive
        go -> ok
    end,
    behave({report, Pid}, Req);
behave({answer_first, Name, Pid}, Req) ->
    Fun = fun(Send) ->
        _ = Send(~"done", fin),
        Pid ! {read_after_answer, roadrunner_req:read_body(Req)},
        true = register(Name, self()),
        receive
            go -> ok
        end
    end,
    {{stream, 200, [{~"content-type", ~"text/plain"}], Fun}, Req}.

count(Req, Read, Count, Total) ->
    case Read(Req) of
        {more, Bytes, Req2} ->
            count(Req2, Read, Count + 1, Total + iolist_size(Bytes));
        {ok, Bytes, Req2} ->
            Size = iolist_size(Bytes),
            Out = [integer_to_binary(Count + 1), ~":", integer_to_binary(Total + Size)],
            {roadrunner_resp:text(200, Out), Req2}
    end.
