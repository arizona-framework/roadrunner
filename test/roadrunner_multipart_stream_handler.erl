-module(roadrunner_multipart_stream_handler).
-moduledoc """
Test fixture for `roadrunner_multipart_SUITE`: streams a multipart body
with `roadrunner_multipart:read_part/2` and `read_part_body/2` (the
route's state is `{Pid, HeadersLength, BodyLength}`, their `length`). It sends `Pid`
`{part, Headers}` as each part's headers arrive, then `{parts, Result}`:
`{ok, [{Headers, Body}]}` once the body is read, or `{error, Reason}`.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req0) ->
    {Pid, HeadersLength, BodyLength} = roadrunner_req:state(Req0),
    case parts(Req0, Pid, HeadersLength, BodyLength) of
        {ok, Parts, Req} ->
            Pid ! {parts, {ok, Parts}},
            {roadrunner_resp:text(200, integer_to_binary(length(Parts))), Req};
        {error, Reason} = Error ->
            Pid ! {parts, Error},
            {roadrunner_resp:text(400, atom_to_binary(Reason)), Req0}
    end.

parts(Req0, Pid, HeadersLength, BodyLength) ->
    case roadrunner_multipart:read_part(Req0, #{length => HeadersLength}) of
        {ok, Headers, Req1} ->
            Pid ! {part, Headers},
            maybe
                {ok, Body, Req2} ?= body(Req1, BodyLength, []),
                {ok, More, Req} ?= parts(Req2, Pid, HeadersLength, BodyLength),
                {ok, [{Headers, Body} | More], Req}
            end;
        {done, Req} ->
            {ok, [], Req};
        {error, _} = Error ->
            Error
    end.

body(Req0, Length, Acc) ->
    case roadrunner_multipart:read_part_body(Req0, #{length => Length}) of
        {ok, Data, Req} -> {ok, iolist_to_binary(lists:reverse(Acc, [Data])), Req};
        {more, Data, Req} when byte_size(Data) =:= Length -> body(Req, Length, [Data | Acc]);
        {error, _} = Error -> Error
    end.
