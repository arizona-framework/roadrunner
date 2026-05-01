-module(cactus_sse).
-moduledoc """
Server-Sent Events (SSE) encoding helpers.

Pairs naturally with the `{loop, ...}` handler return: subscribe to a
pubsub topic in `handle/1`, then call `cactus_sse:event/1,2,3` from
`handle_info/3` to format each event before emitting it via the
`Push` fun.

Example handler:

```erlang
-behaviour(cactus_handler).
-export([handle/1, handle_info/3]).

handle(Req) ->
    ok = my_pubsub:subscribe(self(), notifications),
    Headers = [
        {~"content-type", ~"text/event-stream"},
        {~"cache-control", ~"no-cache"}
    ],
    {{loop, 200, Headers, undefined}, Req}.

handle_info({notification, Body}, Push, State) ->
    _ = Push(cactus_sse:event(~"notify", Body)),
    {ok, State};
handle_info(close, Push, State) ->
    _ = Push(cactus_sse:comment(~"bye")),
    {stop, State}.
```

Per the SSE spec ([WHATWG HTML §9.2](https://html.spec.whatwg.org/multipage/server-sent-events.html#parsing-an-event-stream)):

- Each event ends with a blank line (`\n\n`).
- `data:` may repeat — newlines in the payload split it into multiple
  `data:` lines, all reassembled into one event by the client.
- `event:` is optional; an unnamed event dispatches as the generic
  `message` event in the browser.
- `id:` lets the client resume from the last event seen.
- `retry: N` tells the client to wait N milliseconds before
  reconnecting.
- A line starting with `:` is a comment — useful for keep-alives over
  proxies that close idle connections.
""".

-export([
    event/1,
    event/2,
    event/3,
    comment/1,
    retry/1
]).

-doc "Anonymous event with just a data payload.".
-spec event(Data :: binary()) -> iodata().
event(Data) when is_binary(Data) ->
    [data_lines(Data), $\n].

-doc "Named event with a data payload.".
-spec event(EventName :: binary(), Data :: binary()) -> iodata().
event(Name, Data) when is_binary(Name), is_binary(Data) ->
    ok = check_single_line(Name, event_name),
    [~"event: ", Name, $\n, data_lines(Data), $\n].

-doc """
Named event with an id (for client-side reconnection resume) and a
data payload.
""".
-spec event(EventName :: binary(), Data :: binary(), Id :: binary()) -> iodata().
event(Name, Data, Id) when is_binary(Name), is_binary(Data), is_binary(Id) ->
    ok = check_single_line(Name, event_name),
    ok = check_single_line(Id, event_id),
    [~"event: ", Name, $\n, ~"id: ", Id, $\n, data_lines(Data), $\n].

-doc """
SSE comment line — invisible to the client's event handler but useful
for keep-alives over proxies.
""".
-spec comment(Text :: binary()) -> iodata().
comment(Text) when is_binary(Text) ->
    ok = check_single_line(Text, comment),
    [~": ", Text, ~"\n\n"].

%% SSE field values (event name, id, comment text) MUST NOT contain
%% line separators — `\r` or `\n` would split the value into a second
%% line that's either silently dropped or interpreted as a new field
%% by the client. Crash hard so a programmer bug — usually echoing
%% user input into one of these fields without sanitization — turns
%% into a 500, not a stream-corruption vulnerability. The `data` field
%% is exempt; multi-line `data:` emission is handled by `data_lines/1`.
-spec check_single_line(binary(), atom()) -> ok.
check_single_line(Bin, Field) ->
    case binary:match(Bin, [<<$\r>>, <<$\n>>]) of
        nomatch -> ok;
        _ -> error({sse_line_break, Field, Bin})
    end.

-doc """
Tell the client how long (in milliseconds) to wait before retrying
after a connection drop.
""".
-spec retry(Ms :: non_neg_integer()) -> iodata().
retry(Ms) when is_integer(Ms), Ms >= 0 ->
    [~"retry: ", integer_to_binary(Ms), ~"\n\n"].

%% Encode `Data` as one or more `data:` lines (split on each `\n`),
%% each terminated by a single newline. The caller appends the
%% trailing blank line that ends the event.
-spec data_lines(binary()) -> iodata().
data_lines(Data) ->
    [[~"data: ", Line, $\n] || Line <- binary:split(Data, ~"\n", [global])].
