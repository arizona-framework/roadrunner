-module(roadrunner_manual_body_handler).
-moduledoc """
Test fixture for manual body mode over HTTP/2 and HTTP/3. The route's state
picks what the handler does with the body:

- `read`: read it all and answer with its size (413 with the reason when
  the read fails)
- `reject`: answer 401 without reading it
- `pieces` / `chunks`: read it 4 bytes at a time / chunk by chunk and answer
  `Count:Total`
- `{gated, Name}`: register as `Name`, wait for `go`, then `read`
- `{report, Pid}`: read it and send `Pid` the outcome, `{read_result, _}`
- `{gated_report, Name, Pid}`: `{gated, Name}`, then `{report, Pid}`
- `{announce_report, Pid}`: send `Pid` `reading`, then `{report, Pid}`
- `{gated_pieces, Name, Pid}`: register as `Name`, wait for `go`, read
  100000 bytes and send `Pid` `first_piece`, then read the rest and answer
  with the total
- `{answer_first, Name, Pid}`: stream a complete response, then try to read
  the body and send `Pid` the outcome, `{read_after_answer, _}`, then
  register as `Name` and wait for `go`
- `stream_echo`: start a streamed answer, then read the body and stream it
  back
- `read_then_stream`: read the body, then stream it back
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
behave(stream_echo, Req) ->
    Fun = fun(Send) ->
        {ok, Body, _} = roadrunner_req:read_body(Req),
        _ = Send(Body, fin),
        ok
    end,
    {{stream, 200, [{~"content-type", ~"text/plain"}], Fun}, Req};
behave(read_then_stream, Req) ->
    {ok, Body, _} = roadrunner_req:read_body(Req),
    Fun = fun(Send) ->
        _ = Send(Body, fin),
        ok
    end,
    {{stream, 200, [{~"content-type", ~"text/plain"}], Fun}, Req};
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
behave({announce_report, Pid}, Req) ->
    Pid ! reading,
    behave({report, Pid}, Req);
behave({gated_report, Name, Pid}, Req) ->
    true = register(Name, self()),
    receive
        go -> ok
    end,
    behave({report, Pid}, Req);
behave({gated_pieces, Name, Pid}, Req) ->
    true = register(Name, self()),
    receive
        go -> ok
    end,
    {more, First, Req1} = roadrunner_req:read_body(Req, #{length => 100000}),
    Pid ! first_piece,
    {ok, Rest, Req2} = roadrunner_req:read_body(Req1),
    Total = iolist_size(First) + iolist_size(Rest),
    {roadrunner_resp:text(200, integer_to_binary(Total)), Req2};
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
