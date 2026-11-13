-module(roadrunner_multipart).
-moduledoc """
Parser for `multipart/form-data` request bodies (RFC 7578).

Two ways to read one:

- `parse/2` splits a buffered body into a list of `t:part/0` maps, each
  with its own `headers` and `body`. The whole body is in memory first.
- `read_part/1,2` and `read_part_body/1,2` stream it: one part's headers,
  then its body in bounded pieces, reading the request body only as far
  as needed. Use them for uploads too large to hold in memory, with the
  listener's `body_buffering => manual`.

And three helpers:

- `boundary/1` pulls the `boundary=…` parameter out of a `Content-Type`
  header value, handling unquoted, quoted, and parameter-mixed forms.
- `disposition/1` splits a part's `Content-Disposition` value into its
  type and parameters (`name`, `filename`).
- `params/1` parses the `key=value` parameters of any structured header
  value into a lowercase-keyed map.

Buffered:

```erlang
handle(Req) ->
    {ok, Body, Req2} = roadrunner_req:read_body(Req),
    {ok, Boundary} = roadrunner_multipart:boundary(
        roadrunner_req:header(~"content-type", Req2)
    ),
    {ok, Parts} = roadrunner_multipart:parse(iolist_to_binary(Body), Boundary),
    %% Parts is a list of #{headers := [...], body := <<...>>}.
    ...
```

Streamed, writing each uploaded file to disk as it arrives. The upload
directory comes from the route's state, as in
`{~"/upload", upload_handler, #{dir => UploadDir}}`, and each file gets a
name of our own (never build a path from the client's `name` or
`filename`):

```erlang
handle(Req) ->
    {{send, [], fun save_parts/1}, Req}.

save_parts(Req0) ->
    #{dir := Dir} = roadrunner_req:state(Req0),
    case roadrunner_multipart:read_part(Req0) of
        {ok, Headers, Req1} ->
            {_, Disposition} = lists:keyfind(~"content-disposition", 1, Headers),
            case roadrunner_multipart:disposition(Disposition) of
                {~"form-data", #{~"filename" := _}} ->
                    Name = integer_to_list(erlang:unique_integer([positive])),
                    {ok, Fd} = file:open(filename:join(Dir, Name), [write, raw, binary]),
                    Req2 = save_body(Fd, Req1),
                    ok = file:close(Fd),
                    save_parts(Req2);
                _Field ->
                    %% Not a file: the next read_part/1 skips its body.
                    save_parts(Req1)
            end;
        {done, Req1} ->
            ok = roadrunner_send:reply(204, [], <<>>, Req1),
            Req1
    end.

save_body(Fd, Req0) ->
    case roadrunner_multipart:read_part_body(Req0, #{length => 1048576}) of
        {ok, Data, Req} -> ok = file:write(Fd, Data), Req;
        {more, Data, Req} -> ok = file:write(Fd, Data), save_body(Fd, Req)
    end.
```

## What gets parsed

- The preamble (bytes before the first boundary) is discarded per
  RFC 7578 §4.1.
- Each part's headers are returned as a list of `{Name, Value}`
  binaries, with the name lowercased (matching the convention in
  `roadrunner_req:headers/1`). Values are LWS-trimmed.
- Each part's body is the bytes between `\r\n\r\n` (end-of-headers)
  and the next `\r\n--<boundary>` (start of next boundary or
  terminator).
- The terminating boundary is `--<boundary>--`. Anything after it
  (the epilogue) is ignored.

## What does NOT get parsed

- Per-part transfer encodings (`Content-Transfer-Encoding`) — bodies
  are returned as-is. Modern browsers send raw bytes for
  `multipart/form-data`, so this is rarely needed.
""".

-on_load(init_patterns/0).

-define(SEMI_CP_KEY, {?MODULE, semi_cp}).
-define(QUOTE_CP_KEY, {?MODULE, quote_cp}).
-define(CRLF_CP_KEY, {?MODULE, crlf_cp}).
-define(DBL_CRLF_CP_KEY, {?MODULE, dbl_crlf_cp}).
-define(COLON_CP_KEY, {?MODULE, colon_cp}).

-export([parse/2, boundary/1, params/1, disposition/1]).
-export([read_part/1, read_part/2, read_part_body/1, read_part_body/2]).
-export_type([part/0, part_headers/0]).

%% The longest header block `read_part/1` takes, and the most bytes
%% `read_part_body/1` returns at once, as Cowboy's defaults.
-define(DEFAULT_HEADERS_LENGTH, 64000).
-define(DEFAULT_BODY_LENGTH, 8000000).

%% The streaming reader's state, kept on the request between calls. `buf`
%% holds what was read from the request body and not handed out yet;
%% `stage` is what the bytes at its start are; `eof` is set once the
%% request body is read to its end.
-record(reader, {
    delim :: binary(),
    delim_cp :: binary:cp(),
    buf :: binary(),
    stage :: preamble | seek | delimited | headers | body | done,
    eof :: boolean()
}).

-doc """
One section of a parsed `multipart/form-data` body. `headers` is
the part's headers (names lowercased, values OWS-trimmed) as a list
of `{Name, Value}` binaries; `body` is the raw bytes between
end-of-headers and the next boundary.
""".
-type part() :: #{
    headers := part_headers(),
    body := binary()
}.

-doc """
A part's headers: `{Name, Value}` binaries, the name lowercased and the
value OWS-trimmed.
""".
-type part_headers() :: [{binary(), binary()}].

-doc """
Extract the `boundary=…` parameter from a `Content-Type` header value.
Handles unquoted (`boundary=abc`), quoted (`boundary="a b c"`), and
mixed-with-other-parameters forms.

Returns `{error, no_boundary}` when the parameter isn't present.
""".
-spec boundary(binary()) -> {ok, binary()} | {error, no_boundary}.
boundary(ContentType) when is_binary(ContentType) ->
    case params(ContentType) of
        #{~"boundary" := Boundary} -> {ok, Boundary};
        #{} -> {error, no_boundary}
    end.

-doc """
Split a part's `Content-Disposition` header value into its type,
lowercased, and its parameters, as `params/1` returns them.

```erlang
{~"form-data", #{~"name" := ~"avatar", ~"filename" := ~"me.png"}} =
    roadrunner_multipart:disposition(~"form-data; name=\"avatar\"; filename=\"me.png\"").
```
""".
-spec disposition(binary()) -> {binary(), #{binary() => binary()}}.
disposition(Value) when is_binary(Value) ->
    {Type, Pairs} = split_params(Value),
    {roadrunner_bin:ascii_lowercase(roadrunner_bin:trim_ows(Type)), params_map(Pairs)}.

-doc """
Parse the parameters of a structured header value (e.g. `Content-Type`,
`Content-Disposition`) into a map. The "type" prefix before the first
`;` is discarded — only the `key=value` pairs after it are returned.

Param names are lowercased per RFC 9110 §8.3.1 (media-type parameter
names are case-insensitive); values are returned as-is, with
surrounding quotes stripped. A `;` inside a quoted value, as in
`filename="a;b.txt"`, is part of the value.

Examples:
- `~"text/html; charset=utf-8"` → `#{~"charset" => ~"utf-8"}`
- `~"form-data; name=\"a\"; filename=\"f.txt\""` →
  `#{~"name" => ~"a", ~"filename" => ~"f.txt"}`
- `~"text/html"` → `#{}`

Malformed pairs (no `=`) are silently skipped.
""".
-spec params(binary()) -> #{binary() => binary()}.
params(Value) when is_binary(Value) ->
    {_Type, Pairs} = split_params(Value),
    params_map(Pairs).

-spec params_map([binary()]) -> #{binary() => binary()}.
params_map(Pairs) ->
    parse_pairs(Pairs, persistent_term:get(?QUOTE_CP_KEY), #{}).

%% A header value's type (before the first `;`) and its `key=value` pieces
%% (split on every `;` after it). A `;` inside a quoted value splits it too;
%% `parse_pairs/3` joins those pieces back.
-spec split_params(binary()) -> {binary(), [binary()]}.
split_params(Value) ->
    SemiCp = persistent_term:get(?SEMI_CP_KEY),
    case binary:split(Value, SemiCp) of
        [Type] -> {Type, []};
        [Type, Rest] -> {Type, binary:split(Rest, SemiCp, [global])}
    end.

-spec parse_pairs([binary()], binary:cp(), #{binary() => binary()}) ->
    #{binary() => binary()}.
parse_pairs([], _QuoteCp, Acc) ->
    Acc;
parse_pairs([Pair | Rest], QuoteCp, Acc) ->
    case split_pair(Pair) of
        {Key, <<$", Quoted/binary>>} ->
            case {binary:match(Quoted, QuoteCp), Rest} of
                {{End, _}, _} ->
                    <<Val:End/binary, _/binary>> = Quoted,
                    parse_pairs(Rest, QuoteCp, add_pair(Key, Val, Acc));
                {nomatch, [Next | More]} ->
                    %% A `;` inside the quotes split the value: join it back.
                    parse_pairs([<<Pair/binary, $;, Next/binary>> | More], QuoteCp, Acc);
                {nomatch, []} ->
                    parse_pairs(Rest, QuoteCp, add_pair(Key, Quoted, Acc))
            end;
        {Key, Val} ->
            parse_pairs(Rest, QuoteCp, add_pair(Key, Val, Acc));
        nomatch ->
            parse_pairs(Rest, QuoteCp, Acc)
    end.

%% A pair's key (after leading OWS) and value, split at its first `=` in
%% one walk over a single match context.
-spec split_pair(binary()) -> {binary(), binary()} | nomatch.
split_pair(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t -> split_pair(Rest);
split_pair(Pair) -> split_key(Pair, Pair, 0).

-spec split_key(binary(), binary(), non_neg_integer()) -> {binary(), binary()} | nomatch.
split_key(<<$=, Val/binary>>, Pair, Len) ->
    <<Key:Len/binary, _/binary>> = Pair,
    {Key, Val};
split_key(<<_, Rest/binary>>, Pair, Len) ->
    split_key(Rest, Pair, Len + 1);
split_key(<<>>, _Pair, _Len) ->
    nomatch.

%% The trim comes after the unquote, so whitespace inside quotes is kept
%% and trailing whitespace on a bare value goes.
-spec add_pair(binary(), binary(), #{binary() => binary()}) -> #{binary() => binary()}.
add_pair(Key, Val, Acc) ->
    Acc#{roadrunner_bin:ascii_lowercase(Key) => roadrunner_bin:trim_ows(Val)}.

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
        [_Preamble, Rest] ->
            %% Fetch the compiled patterns ONCE on the success branch
            %% and thread them through `parse_parts/5` → `parse_one_part/5`
            %% → header-line parsing. Avoids three
            %% `persistent_term:get/1` calls per part on a multi-part
            %% body, and avoids fetching them at all when the body
            %% lacks the opening boundary. `BodyEnd` is dynamic (depends
            %% on the multipart boundary string) so it can't live in
            %% persistent_term, but compiling it once here amortizes
            %% across every part's `extract_body/3` split.
            DblCrlfCp = persistent_term:get(?DBL_CRLF_CP_KEY),
            CrlfCp = persistent_term:get(?CRLF_CP_KEY),
            ColonCp = persistent_term:get(?COLON_CP_KEY),
            BodyEndCp = binary:compile_pattern(<<"\r\n", Sep/binary>>),
            parse_parts(Rest, BodyEndCp, DblCrlfCp, CrlfCp, ColonCp);
        _ ->
            {error, no_initial_boundary}
    end.

%% After the first boundary marker, what follows is either:
%% - "--\r\n" or "--" → terminating boundary, end of multipart.
%% - "\r\n" + part bytes → another part to parse.
-spec parse_parts(binary(), binary:cp(), binary:cp(), binary:cp(), binary:cp()) ->
    {ok, [part()]} | {error, term()}.
parse_parts(<<"--\r\n", _Epilogue/binary>>, _BodyEndCp, _DblCrlfCp, _CrlfCp, _ColonCp) ->
    {ok, []};
parse_parts(<<"--">>, _BodyEndCp, _DblCrlfCp, _CrlfCp, _ColonCp) ->
    {ok, []};
parse_parts(<<"\r\n", PartAndRest/binary>>, BodyEndCp, DblCrlfCp, CrlfCp, ColonCp) ->
    maybe
        {ok, Part, Rest} ?= parse_one_part(PartAndRest, BodyEndCp, DblCrlfCp, CrlfCp, ColonCp),
        {ok, More} ?= parse_parts(Rest, BodyEndCp, DblCrlfCp, CrlfCp, ColonCp),
        {ok, [Part | More]}
    end;
parse_parts(_, _, _, _, _) ->
    {error, malformed}.

-spec parse_one_part(binary(), binary:cp(), binary:cp(), binary:cp(), binary:cp()) ->
    {ok, part(), binary()} | {error, term()}.
%% Empty header block — the part starts with the empty-line terminator
%% immediately. RFC 5322 §2.2.3 (referenced by RFC 7578) allows this:
%% headers are followed by a blank line, and the header list itself
%% may be empty. Without this clause we'd reject a perfectly valid
%% file-upload that omits Content-Disposition / Content-Type.
parse_one_part(<<"\r\n", BodyAndRest/binary>>, BodyEndCp, _DblCrlfCp, _CrlfCp, _ColonCp) ->
    extract_body(BodyAndRest, [], BodyEndCp);
parse_one_part(Bytes, BodyEndCp, DblCrlfCp, CrlfCp, ColonCp) ->
    maybe
        [HeaderBlock, BodyAndRest] ?= binary:split(Bytes, DblCrlfCp),
        {ok, Headers} ?=
            parse_header_lines(binary:split(HeaderBlock, CrlfCp, [global]), ColonCp),
        extract_body(BodyAndRest, Headers, BodyEndCp)
    else
        [_] -> {error, no_header_terminator};
        Other -> Other
    end.

-spec extract_body(binary(), [{binary(), binary()}], binary:cp()) ->
    {ok, part(), binary()} | {error, no_part_terminator}.
extract_body(BodyAndRest, Headers, BodyEndCp) ->
    case binary:split(BodyAndRest, BodyEndCp) of
        [Body, Rest] -> {ok, #{headers => Headers, body => Body}, Rest};
        _ -> {error, no_part_terminator}
    end.

-spec parse_header_lines([binary()], binary:cp()) ->
    {ok, [{binary(), binary()}]} | {error, bad_header}.
parse_header_lines(Lines, ColonCp) ->
    parse_header_lines_loop(Lines, ColonCp).

-spec parse_header_lines_loop([binary()], binary:cp()) ->
    {ok, [{binary(), binary()}]} | {error, bad_header}.
parse_header_lines_loop([], _ColonCp) ->
    {ok, []};
parse_header_lines_loop([Line | Rest], ColonCp) ->
    maybe
        [Name, Value] ?= binary:split(Line, ColonCp),
        {ok, More} ?= parse_header_lines_loop(Rest, ColonCp),
        {ok, [{roadrunner_bin:ascii_lowercase(Name), roadrunner_bin:trim_ows(Value)} | More]}
    else
        [_] -> {error, bad_header};
        Other -> Other
    end.

-doc """
Read the next part's headers from a multipart request, streaming the
request body. The same as `read_part/2` with the default options.
""".
-spec read_part(roadrunner_req:request()) ->
    {ok, part_headers(), roadrunner_req:request()}
    | {done, roadrunner_req:request()}
    | {error, term()}.
read_part(Req) ->
    read_part(Req, #{}).

-doc """
Read the next part's headers from a multipart request, streaming the
request body.

Returns `{ok, Headers, Req2}` for the next part, then read its body with
`read_part_body/1,2`; or `{done, Req2}` after the last part. A part whose
body was not read, or not to its end, is skipped. Pass the request each
call returns to the next one: it carries the reader's state, including
body bytes it read ahead, so once you start reading parts, read the rest
of the body with these functions and not `roadrunner_req:read_body/1,2`.

The boundary comes from the request's `Content-Type`. `Opts` may set
`length`, the longest header block a part may have, 64000 bytes by
default. It is also how much each read of the request body asks for: a
read waits until that many bytes arrive or the body ends, as
`roadrunner_req:read_body/2` does.

Returns `{error, Reason}` when the body is not a well-formed multipart
body or can't be read:

- `not_multipart` or `no_boundary`: the `Content-Type` is not a
  `multipart/*` type with a `boundary` parameter of 1 to 70 characters
- `no_initial_boundary`: the body ended before its first boundary
- `no_header_terminator`: the body ended in a part's headers
- `no_part_terminator`: the body ended in a part or right after a
  boundary, before the closing boundary
- `headers_too_large`: a part's header block is over `length`
- `bad_header`: a part's header line has no `:`
- `malformed`: a boundary is followed by something other than a line
  break or the closing `--`
- an error from `roadrunner_req:read_body/2`, such as `request_timeout`
""".
-spec read_part(roadrunner_req:request(), #{length => pos_integer()}) ->
    {ok, part_headers(), roadrunner_req:request()}
    | {done, roadrunner_req:request()}
    | {error, term()}.
read_part(Req, Opts) ->
    Length = maps:get(length, Opts, ?DEFAULT_HEADERS_LENGTH),
    case reader(Req) of
        {ok, Reader} -> next_part(Reader, Req, Length, 0);
        {error, _} = Error -> Error
    end.

-doc """
Read the body of the part `read_part/1,2` just returned. The same as
`read_part_body/2` with the default options.
""".
-spec read_part_body(roadrunner_req:request()) ->
    {ok, binary(), roadrunner_req:request()}
    | {more, binary(), roadrunner_req:request()}
    | {error, term()}.
read_part_body(Req) ->
    read_part_body(Req, #{}).

-doc """
Read the body of the part `read_part/1,2` just returned, in pieces of at
most `length` bytes (`Opts`, 8000000 by default). Calling it on a request
that is not inside a part (before `read_part/1,2`, after the part's last
piece, or after `{done, _}`) raises `function_clause`.

Returns `{more, Data, Req2}` while the part goes on, so call it again
with `Req2`, and `{ok, Data, Req2}` with its last bytes. A call waits
until it has `length` bytes or the part's end (each read of the request
body asks for `length` bytes, as `roadrunner_req:read_body/2` does), so
`length` bounds both what one call returns and what the reader holds in
memory.

Returns `{error, no_part_terminator}` when the request body ends inside
the part, or an error from `roadrunner_req:read_body/2`.
""".
-spec read_part_body(roadrunner_req:request(), #{length => pos_integer()}) ->
    {ok, binary(), roadrunner_req:request()}
    | {more, binary(), roadrunner_req:request()}
    | {error, term()}.
read_part_body(#{multipart := #reader{stage = body} = Reader} = Req, Opts) ->
    part_body(Reader, Req, maps:get(length, Opts, ?DEFAULT_BODY_LENGTH), 0).

%% The request's reader, or a new one from its `Content-Type`. The buffer
%% starts with a line break so that the first boundary, which opens the
%% body without one, matches the same `\r\n--Boundary` delimiter as the
%% others (RFC 2046 §5.1.1).
-spec reader(roadrunner_req:request()) -> {ok, #reader{}} | {error, not_multipart | no_boundary}.
reader(#{multipart := #reader{} = Reader}) ->
    {ok, Reader};
reader(Req) ->
    ContentType = roadrunner_req:header_normalized(~"content-type", Req),
    maybe
        ok ?= multipart_type(ContentType),
        {ok, Boundary} ?= boundary(ContentType),
        ok ?= boundary_length(Boundary),
        Delim = <<"\r\n--", Boundary/binary>>,
        {ok, #reader{
            delim = Delim,
            delim_cp = binary:compile_pattern(Delim),
            buf = ~"\r\n",
            stage = preamble,
            eof = false
        }}
    end.

%% RFC 2046 §5.1.1: a boundary is 1 to 70 characters. An empty one would
%% make every line that starts with `--` a delimiter.
-spec boundary_length(binary()) -> ok | {error, no_boundary}.
boundary_length(Boundary) when byte_size(Boundary) >= 1, byte_size(Boundary) =< 70 -> ok;
boundary_length(_Boundary) -> {error, no_boundary}.

-spec multipart_type(binary() | undefined) -> ok | {error, not_multipart}.
multipart_type(<<M, U, L, T, I, P, A, R, T2, $/, _/binary>>) when
    M bor 16#20 =:= $m,
    U bor 16#20 =:= $u,
    L bor 16#20 =:= $l,
    T bor 16#20 =:= $t,
    I bor 16#20 =:= $i,
    P bor 16#20 =:= $p,
    A bor 16#20 =:= $a,
    R bor 16#20 =:= $r,
    T2 bor 16#20 =:= $t
->
    ok;
multipart_type(_ContentType) ->
    {error, not_multipart}.

%% Walk the buffer to the next part's headers. `Scanned` is how far the
%% buffer was already searched for what the stage looks for, so a refill
%% searches only the new bytes (and the few before them a match could
%% start in).
-spec next_part(#reader{}, roadrunner_req:request(), pos_integer(), non_neg_integer()) ->
    {ok, part_headers(), roadrunner_req:request()}
    | {done, roadrunner_req:request()}
    | {error, term()}.
next_part(#reader{stage = done} = Reader, Req, _Length, _Scanned) ->
    {done, Req#{multipart => Reader}};
next_part(#reader{stage = body} = Reader, Req, Length, _Scanned) ->
    %% The part's body was left unread: skip it.
    next_part(Reader#reader{stage = seek}, Req, Length, 0);
next_part(#reader{stage = Stage, buf = Buf, delim = Delim} = Reader, Req, Length, Scanned) when
    Stage =:= preamble; Stage =:= seek
->
    case
        binary:match(Buf, Reader#reader.delim_cp, [{scope, {Scanned, byte_size(Buf) - Scanned}}])
    of
        {Pos, Len} ->
            <<_:(Pos + Len)/binary, Rest/binary>> = Buf,
            next_part(Reader#reader{stage = delimited, buf = Rest}, Req, Length, 0);
        nomatch ->
            %% Only the bytes a delimiter could still start in are kept.
            Keep = min(byte_size(Buf), byte_size(Delim) - 1),
            Skip = byte_size(Buf) - Keep,
            <<_:Skip/binary, Tail/binary>> = Buf,
            refill_part(Reader#reader{buf = Tail}, Req, Length, 0, unterminated(Stage))
    end;
next_part(#reader{stage = delimited, buf = Buf} = Reader, Req, Length, _Scanned) ->
    case Buf of
        <<"--", _/binary>> ->
            {done, Req#{multipart => Reader#reader{stage = done, buf = <<>>}}};
        <<"\r\n", Rest/binary>> ->
            next_part(Reader#reader{stage = headers, buf = Rest}, Req, Length, 0);
        <<C, Rest/binary>> when C =:= $\s; C =:= $\t ->
            %% Transport padding after the boundary (RFC 2046 §5.1.1).
            next_part(Reader#reader{buf = Rest}, Req, Length, 0);
        <<C>> when C =:= $-; C =:= $\r ->
            refill_part(Reader, Req, Length, 0, no_part_terminator);
        <<>> ->
            refill_part(Reader, Req, Length, 0, no_part_terminator);
        _ ->
            {error, malformed}
    end;
next_part(#reader{stage = headers, buf = Buf} = Reader, Req, Length, Scanned) ->
    case Buf of
        <<"\r\n", Rest/binary>> ->
            %% No headers: the blank line comes first (RFC 5322 §2.2.3).
            {ok, [], Req#{multipart => Reader#reader{stage = body, buf = Rest}}};
        _ ->
            DblCrlfCp = persistent_term:get(?DBL_CRLF_CP_KEY),
            case binary:match(Buf, DblCrlfCp, [{scope, {Scanned, byte_size(Buf) - Scanned}}]) of
                {Pos, _} when Pos =< Length ->
                    <<Block:Pos/binary, _:4/binary, Rest/binary>> = Buf,
                    Lines = binary:split(Block, persistent_term:get(?CRLF_CP_KEY), [global]),
                    maybe
                        {ok, Headers} ?=
                            parse_header_lines(Lines, persistent_term:get(?COLON_CP_KEY)),
                        {ok, Headers, Req#{multipart => Reader#reader{stage = body, buf = Rest}}}
                    end;
                {_Pos, _} ->
                    {error, headers_too_large};
                nomatch when byte_size(Buf) > Length ->
                    {error, headers_too_large};
                nomatch ->
                    refill_part(
                        Reader, Req, Length, max(0, byte_size(Buf) - 3), no_header_terminator
                    )
            end
    end.

-spec unterminated(preamble | seek) -> no_initial_boundary | no_part_terminator.
unterminated(preamble) -> no_initial_boundary;
unterminated(seek) -> no_part_terminator.

%% Read more of the request body into the buffer and go on, or fail with
%% `Eof` when the body has ended.
-spec refill_part(#reader{}, roadrunner_req:request(), pos_integer(), non_neg_integer(), atom()) ->
    {ok, part_headers(), roadrunner_req:request()}
    | {done, roadrunner_req:request()}
    | {error, term()}.
refill_part(#reader{eof = true}, _Req, _Length, _Scanned, Eof) ->
    {error, Eof};
refill_part(Reader, Req0, Length, Scanned, _Eof) ->
    case refill(Reader, Req0, Length) of
        {ok, Reader1, Req} -> next_part(Reader1, Req, Length, Scanned);
        {error, _} = Error -> Error
    end.

%% The part's body up to the delimiter, at most `Length` bytes a call.
-spec part_body(#reader{}, roadrunner_req:request(), pos_integer(), non_neg_integer()) ->
    {ok, binary(), roadrunner_req:request()}
    | {more, binary(), roadrunner_req:request()}
    | {error, term()}.
part_body(#reader{buf = Buf, delim = Delim} = Reader, Req0, Length, Scanned) ->
    case
        binary:match(Buf, Reader#reader.delim_cp, [{scope, {Scanned, byte_size(Buf) - Scanned}}])
    of
        {Pos, _} when Pos =< Length ->
            %% The rest starts with the delimiter, which `read_part/1,2`
            %% finds right away.
            <<Data:Pos/binary, Rest/binary>> = Buf,
            {ok, Data, Req0#{multipart => Reader#reader{stage = seek, buf = Rest}}};
        {_Pos, _} ->
            more(Reader, Req0, Length);
        nomatch ->
            %% The last bytes may be the start of the delimiter.
            Safe = max(0, byte_size(Buf) - (byte_size(Delim) - 1)),
            case Safe >= Length of
                true ->
                    more(Reader, Req0, Length);
                false when Reader#reader.eof ->
                    {error, no_part_terminator};
                false ->
                    case refill(Reader, Req0, Length) of
                        {ok, Reader1, Req} -> part_body(Reader1, Req, Length, Safe);
                        {error, _} = Error -> Error
                    end
            end
    end.

-spec more(#reader{}, roadrunner_req:request(), pos_integer()) ->
    {more, binary(), roadrunner_req:request()}.
more(#reader{buf = Buf} = Reader, Req, Length) ->
    <<Data:Length/binary, Rest/binary>> = Buf,
    {more, Data, Req#{multipart => Reader#reader{buf = Rest}}}.

%% Up to `Length` more bytes of the request body onto the buffer. In auto
%% mode the first read returns the whole buffered body, so the reader
%% marks the end and never reads again.
-spec refill(#reader{}, roadrunner_req:request(), pos_integer()) ->
    {ok, #reader{}, roadrunner_req:request()} | {error, term()}.
refill(#reader{buf = Buf} = Reader, Req0, Length) ->
    case roadrunner_req:read_body(Req0, #{length => Length}) of
        {ok, Bytes, Req} ->
            {ok, Reader#reader{buf = append(Buf, Bytes), eof = true}, Req};
        {more, Bytes, Req} ->
            {ok, Reader#reader{buf = append(Buf, Bytes)}, Req};
        {error, _} = Error ->
            Error
    end.

-spec append(binary(), iodata()) -> binary().
append(Buf, Bytes) when is_binary(Bytes) ->
    <<Buf/binary, Bytes/binary>>;
append(Buf, Bytes) ->
    iolist_to_binary([Buf | Bytes]).

%% `-on_load` callback. Compiles the binary patterns once into
%% `persistent_term` so the hot path reads a constant, not a recompile.
-spec init_patterns() -> ok.
init_patterns() ->
    persistent_term:put(?SEMI_CP_KEY, binary:compile_pattern(~";")),
    persistent_term:put(?QUOTE_CP_KEY, binary:compile_pattern(~"\"")),
    persistent_term:put(?CRLF_CP_KEY, binary:compile_pattern(~"\r\n")),
    persistent_term:put(?DBL_CRLF_CP_KEY, binary:compile_pattern(~"\r\n\r\n")),
    persistent_term:put(?COLON_CP_KEY, binary:compile_pattern(~":")),
    ok.
