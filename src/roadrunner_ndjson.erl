-module(roadrunner_ndjson).
-moduledoc """
Newline-delimited JSON (NDJSON) encoding helper.

The JSON sibling of `roadrunner_sse`. `item/1` frames one value as a
compact JSON document followed by a single `\\n` delimiter and returns
iodata, so it drops into every response shape unchanged. Set the
response content-type to `content_type/0` (`application/x-ndjson`).

A bounded result set as a buffered body — `roadrunner_resp:ndjson/2`
frames the whole list and sets the headers (it calls `item/1` per row):

```erlang
handle(Req) ->
    Rows = my_db:recent_orders(),
    {roadrunner_resp:ndjson(200, Rows), Req}.
```

A large or lazy result set, streamed one line per chunk without
buffering the whole body (the `{stream, ...}` shape):

```erlang
handle(Req) ->
    Fun = fun(Send) ->
        my_db:fold_orders(fun(Row, _Acc) ->
            Send(roadrunner_ndjson:item(Row), nofin)
        end, ok),
        Send(~"", fin)
    end,
    {{stream, 200, [{~"content-type", roadrunner_ndjson:content_type()}], Fun}, Req}.
```

A message-driven feed (token-by-token output, pub/sub): use the
`{loop, ...}` shape and push each item from `handle_info/3`, exactly as
the `roadrunner_sse` example does, with `item/1` in place of
`roadrunner_sse:event/1`.

`json:encode/1` emits compact, single-line JSON (control characters in
strings are escaped), so an item never carries a raw newline that would
break the framing.
""".

-export([
    item/1,
    content_type/0
]).

-doc """
Encode one term as a compact JSON document followed by the `\\n`
delimiter, ready to hand to the streaming `Push` fun.
""".
-spec item(Term :: term()) -> iodata().
item(Term) ->
    [json:encode(Term), $\n].

-doc "The NDJSON media type, for the response `content-type` header.".
-spec content_type() -> binary().
content_type() ->
    ~"application/x-ndjson".
