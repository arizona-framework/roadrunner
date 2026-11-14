-module(roadrunner_grpc_status).
-moduledoc false.

%% gRPC status codes (gRPC's statuscodes.md) and the `grpc-message`
%% trailer's encoding (PROTOCOL-HTTP2): the message is UTF-8, then
%% percent-encoded, every byte outside space through `~` and every `%`
%% written as `%` and two uppercase hex digits. Decoding never fails: an
%% escape that is not `%` and two hex digits stays as it is, which the
%% protocol allows ("decode valid portions while leaving broken
%% %-encodings as-is").

-export([code/1, name/1, encode_message/1, decode_message/1]).

-export_type([name/0]).

-define(IS_HEX(C),
    ((C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) orelse
        (C >= $A andalso C =< $F))
).

-type name() ::
    ok
    | cancelled
    | unknown
    | invalid_argument
    | deadline_exceeded
    | not_found
    | already_exists
    | permission_denied
    | resource_exhausted
    | failed_precondition
    | aborted
    | out_of_range
    | unimplemented
    | internal
    | unavailable
    | data_loss
    | unauthenticated.

-doc "The status code a name stands for.".
-spec code(name()) -> 0..16.
code(ok) -> 0;
code(cancelled) -> 1;
code(unknown) -> 2;
code(invalid_argument) -> 3;
code(deadline_exceeded) -> 4;
code(not_found) -> 5;
code(already_exists) -> 6;
code(permission_denied) -> 7;
code(resource_exhausted) -> 8;
code(failed_precondition) -> 9;
code(aborted) -> 10;
code(out_of_range) -> 11;
code(unimplemented) -> 12;
code(internal) -> 13;
code(unavailable) -> 14;
code(data_loss) -> 15;
code(unauthenticated) -> 16.

-doc "The name of a status code.".
-spec name(0..16) -> name().
name(0) -> ok;
name(1) -> cancelled;
name(2) -> unknown;
name(3) -> invalid_argument;
name(4) -> deadline_exceeded;
name(5) -> not_found;
name(6) -> already_exists;
name(7) -> permission_denied;
name(8) -> resource_exhausted;
name(9) -> failed_precondition;
name(10) -> aborted;
name(11) -> out_of_range;
name(12) -> unimplemented;
name(13) -> internal;
name(14) -> unavailable;
name(15) -> data_loss;
name(16) -> unauthenticated.

-doc """
Percent-encode a UTF-8 status message for the `grpc-message` trailer. A
message with nothing to escape, the usual case, comes back as it is.
""".
-spec encode_message(binary()) -> binary().
encode_message(Message) ->
    case plain(Message) of
        true -> Message;
        false -> escape(Message)
    end.

%% Whether every byte is one the trailer carries as itself.
-spec plain(binary()) -> boolean().
plain(<<C, Rest/binary>>) when C >= 16#20, C =< 16#7E, C =/= $% ->
    plain(Rest);
plain(<<>>) ->
    true;
plain(_Message) ->
    false.

-spec escape(binary()) -> binary().
escape(Message) ->
    <<
        <<(escape_byte(C))/binary>>
     || <<C>> <= Message
    >>.

-spec escape_byte(byte()) -> binary().
escape_byte(C) when C >= 16#20, C =< 16#7E, C =/= $% ->
    <<C>>;
escape_byte(C) ->
    <<$%, (hex(C bsr 4)), (hex(C band 16#F))>>.

-spec hex(0..15) -> byte().
hex(N) when N < 10 -> $0 + N;
hex(N) -> $A + N - 10.

-doc """
Decode a `grpc-message` trailer value back to the UTF-8 message. Escapes
are read in either case; a `%` not followed by two hex digits is kept as it
is.
""".
-spec decode_message(binary()) -> binary().
decode_message(Value) ->
    unescape(Value, <<>>).

-spec unescape(binary(), binary()) -> binary().
unescape(<<$%, H, L, Rest/binary>>, Acc) when ?IS_HEX(H), ?IS_HEX(L) ->
    unescape(Rest, <<Acc/binary, (unhex(H) * 16 + unhex(L))>>);
unescape(<<C, Rest/binary>>, Acc) ->
    unescape(Rest, <<Acc/binary, C>>);
unescape(<<>>, Acc) ->
    Acc.

-spec unhex(byte()) -> 0..15.
unhex(C) when C >= $0, C =< $9 -> C - $0;
unhex(C) when C >= $a, C =< $f -> C - $a + 10;
unhex(C) -> C - $A + 10.
