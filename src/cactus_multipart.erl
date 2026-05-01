-module(cactus_multipart).
-moduledoc """
Parser for `multipart/form-data` request bodies (RFC 7578).

Two entry points:

- `boundary/1` — pull the `boundary=…` parameter out of a
  `Content-Type` header value, handling unquoted, quoted, and
  parameter-mixed forms.
- `parse/2` — split a buffered body into a list of `part()` maps,
  each with its own `headers` and decoded `body`.

Typical handler shape:

```erlang
handle(Req) ->
    {ok, Body, Req2} = cactus_req:read_body(Req),
    {ok, Boundary} = cactus_multipart:boundary(
        cactus_req:header(~"content-type", Req2)
    ),
    {ok, Parts} = cactus_multipart:parse(Body, Boundary),
    %% Parts is a list of #{headers := [...], body := <<...>>}.
    ...
```

This is a buffered parser — the entire body must be in memory first.
For very large file uploads where you can't afford to buffer, a
streaming variant is a future feature; today, cap them at the
listener's `max_content_length` (default 10 MB).

## What gets parsed

- The preamble (bytes before the first boundary) is discarded per
  RFC 7578 §4.1.
- Each part's headers are returned as a list of `{Name, Value}`
  binaries, with the name lowercased (matching the convention in
  `cactus_req:headers/1`). Values are LWS-trimmed.
- Each part's body is the bytes between `\r\n\r\n` (end-of-headers)
  and the next `\r\n--<boundary>` (start of next boundary or
  terminator).
- The terminating boundary is `--<boundary>--`. Anything after it
  (the epilogue) is ignored.

## What does NOT get parsed

- `Content-Disposition` parameters (`name`, `filename`, etc.) —
  callers parse them out of the raw header value if they need to.
  Adding a `disposition/1` helper is a straightforward follow-up.
- Per-part transfer encodings (`Content-Transfer-Encoding`) — bodies
  are returned as-is. Modern browsers send raw bytes for
  `multipart/form-data`, so this is rarely needed.
""".

-export([parse/2, boundary/1]).
-export_type([part/0]).

-type part() :: #{
    headers := [{binary(), binary()}],
    body := binary()
}.

-doc """
Extract the `boundary=…` parameter from a `Content-Type` header value.
Handles unquoted (`boundary=abc`), quoted (`boundary="a b c"`), and
mixed-with-other-parameters forms.

Returns `{error, no_boundary}` when the parameter isn't present.
""".
-spec boundary(binary()) -> {ok, binary()} | {error, no_boundary}.
boundary(ContentType) when is_binary(ContentType) ->
    case binary:match(ContentType, ~"boundary=") of
        nomatch ->
            {error, no_boundary};
        {Pos, Len} ->
            Tail = binary:part(
                ContentType,
                Pos + Len,
                byte_size(ContentType) - Pos - Len
            ),
            {ok, extract_boundary(Tail)}
    end.

-spec extract_boundary(binary()) -> binary().
extract_boundary(<<$", Rest/binary>>) ->
    case binary:match(Rest, ~"\"") of
        {End, _} -> binary:part(Rest, 0, End);
        nomatch -> Rest
    end;
extract_boundary(Bin) ->
    case binary:match(Bin, ~";") of
        {End, _} -> binary:part(Bin, 0, End);
        nomatch -> Bin
    end.

-doc """
Split `Body` into a list of multipart parts using `Boundary` as the
delimiter. The boundary must NOT include the leading `--` — that is
the multipart wire prefix and is added internally.

Returns `{error, no_initial_boundary}` if the body doesn't start
with (or contain) the opening boundary, `{error, bad_header}` on
a malformed part header, or other `{error, _}` shapes when the
multipart structure is otherwise broken.
""".
-spec parse(binary(), binary()) -> {ok, [part()]} | {error, term()}.
parse(Body, Boundary) when is_binary(Body), is_binary(Boundary) ->
    Sep = <<"--", Boundary/binary>>,
    case binary:split(Body, Sep) of
        [_Preamble, Rest] -> parse_parts(Rest, Sep);
        _ -> {error, no_initial_boundary}
    end.

%% After the first boundary marker, what follows is either:
%% - "--\r\n" or "--" → terminating boundary, end of multipart.
%% - "\r\n" + part bytes → another part to parse.
-spec parse_parts(binary(), binary()) -> {ok, [part()]} | {error, term()}.
parse_parts(<<"--\r\n", _Epilogue/binary>>, _Sep) ->
    {ok, []};
parse_parts(<<"--">>, _Sep) ->
    {ok, []};
parse_parts(<<"\r\n", PartAndRest/binary>>, Sep) ->
    case parse_one_part(PartAndRest, Sep) of
        {ok, Part, Rest} ->
            case parse_parts(Rest, Sep) of
                {ok, More} -> {ok, [Part | More]};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end;
parse_parts(_, _) ->
    {error, malformed}.

-spec parse_one_part(binary(), binary()) ->
    {ok, part(), binary()} | {error, term()}.
parse_one_part(Bytes, Sep) ->
    case binary:split(Bytes, ~"\r\n\r\n") of
        [HeaderBlock, BodyAndRest] ->
            case parse_header_lines(binary:split(HeaderBlock, ~"\r\n", [global])) of
                {ok, Headers} ->
                    BodyEnd = <<"\r\n", Sep/binary>>,
                    case binary:split(BodyAndRest, BodyEnd) of
                        [Body, Rest] ->
                            {ok, #{headers => Headers, body => Body}, Rest};
                        _ ->
                            {error, no_part_terminator}
                    end;
                {error, _} = E ->
                    E
            end;
        _ ->
            {error, no_header_terminator}
    end.

-spec parse_header_lines([binary()]) ->
    {ok, [{binary(), binary()}]} | {error, bad_header}.
parse_header_lines([]) ->
    {ok, []};
parse_header_lines([Line | Rest]) ->
    case binary:split(Line, ~":") of
        [Name, Value] ->
            case parse_header_lines(Rest) of
                {ok, More} ->
                    {ok, [{string:lowercase(Name), string:trim(Value)} | More]};
                {error, _} = E ->
                    E
            end;
        _ ->
            {error, bad_header}
    end.
