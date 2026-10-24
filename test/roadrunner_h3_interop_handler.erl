-module(roadrunner_h3_interop_handler).
-moduledoc """
Handler for `scripts/h3interop.sh`, which drives an HTTP/3 listener with
independent QUIC clients. `/bytes/N` answers with N bytes of the repeating
`0123456789abcdef` pattern, which the script regenerates to check every
byte arrived; `/echo` answers with the request body.
""".

-behaviour(roadrunner_handler).

-export([handle/1]).

-define(PATTERN, ~"0123456789abcdef").

-spec handle(roadrunner_req:request()) ->
    {roadrunner_handler:response(), roadrunner_req:request()}.
handle(#{target := ~"/echo"} = Req) ->
    {{200, [{~"content-type", ~"application/octet-stream"}], roadrunner_req:body(Req)}, Req};
handle(#{target := <<"/bytes/", Size/binary>>} = Req) ->
    Body = pattern(binary_to_integer(Size)),
    {{200, [{~"content-type", ~"application/octet-stream"}], Body}, Req};
handle(Req) ->
    {{404, [], ~""}, Req}.

%% `Size` bytes of the repeating pattern.
-spec pattern(non_neg_integer()) -> binary().
pattern(Size) ->
    Whole = binary:copy(?PATTERN, Size div byte_size(?PATTERN)),
    <<Whole/binary, (binary:part(?PATTERN, 0, Size rem byte_size(?PATTERN)))/binary>>.
