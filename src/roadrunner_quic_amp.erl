-module(roadrunner_quic_amp).
-moduledoc false.

%% Server anti-amplification accounting (RFC 9000 §8.1).
%%
%% Before it has validated the client's address, a server MUST NOT send
%% more than three times the number of bytes it has received, which limits
%% its use as a packet-amplification reflector. This module is the pure
%% byte accounting: the connection records received and sent datagram
%% sizes, asks how much it may still send (or whether a given datagram
%% fits), and marks the address validated once a Handshake packet from the
%% client decrypts (proof the client received the server's Initial), which
%% lifts the limit. Holding back an over-budget datagram until more is
%% received is the send pipeline's job; this module only does the counting.

-export([new/0, received/2, sent/2, validate/1, budget/1, can_send/2]).

-export_type([t/0]).

%% RFC 9000 §8.1: the pre-validation send cap is three times bytes received.
-define(FACTOR, 3).

-record(amp, {
    rx = 0 :: non_neg_integer(),
    tx = 0 :: non_neg_integer(),
    validated = false :: boolean()
}).

-opaque t() :: #amp{}.

-doc "A fresh accounting state: nothing received or sent, address not yet validated.".
-spec new() -> t().
new() ->
    #amp{}.

-doc "Record `Bytes` received from the client; this raises the send budget.".
-spec received(non_neg_integer(), t()) -> t().
received(Bytes, #amp{rx = Rx} = Amp) ->
    Amp#amp{rx = Rx + Bytes}.

-doc "Record `Bytes` sent to the client; this spends the send budget.".
-spec sent(non_neg_integer(), t()) -> t().
sent(Bytes, #amp{tx = Tx} = Amp) ->
    Amp#amp{tx = Tx + Bytes}.

-doc "Mark the client's address validated (RFC 9000 §8.1), lifting the limit.".
-spec validate(t()) -> t().
validate(Amp) ->
    Amp#amp{validated = true}.

-doc """
Bytes the server may still send: `infinity` once the address is
validated, otherwise three times the bytes received minus the bytes sent
(never negative). `infinity` orders above any integer, so a caller can
cap a datagram with `min(MaxSize, budget(Amp))`.
""".
-spec budget(t()) -> non_neg_integer() | infinity.
budget(#amp{validated = true}) ->
    infinity;
budget(#amp{rx = Rx, tx = Tx}) ->
    max(0, ?FACTOR * Rx - Tx).

-doc "Whether a datagram of `Bytes` fits within the remaining send budget.".
-spec can_send(non_neg_integer(), t()) -> boolean().
can_send(_Bytes, #amp{validated = true}) ->
    true;
can_send(Bytes, Amp) ->
    Bytes =< budget(Amp).
