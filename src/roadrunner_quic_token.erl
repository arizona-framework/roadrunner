-module(roadrunner_quic_token).
-moduledoc false.

%% Address validation tokens (RFC 9000 §8.1.3, §8.1.4), pure apart from the
%% clock and random nonce new/2 reads.
%%
%% Once a connection has validated the client's address, the server hands
%% the client a token in a NEW_TOKEN frame (§19.7); the client puts it in the
%% Initial of a later connection, and a token that opens for the address the
%% Initial came from counts as validating that address at once, lifting the
%% three-times anti-amplification limit on the server's first flight (§8.1).
%%
%% A token is the client's IP address and the second it was issued (system
%% time, so it means the same after a restart and on another server given
%% the same secret), sealed with AES-256-GCM under a key derived from the
%% listener's secret. The seal keeps a client from making or altering one
%% (§8.1.4 MUST) and keeps the address and time unreadable, so nothing in it
%% links the connection it was issued on to the one it is used on for an
%% observer (§8.1.3 MUST). The port is left out: a client's next connection
%% almost never has the same one (§8.1.3). Each token carries a fresh random
%% 96-bit nonce, which makes every token unique across clients (§8.1.3 MUST)
%% and lets a token be told apart once spent.
%%
%% Layout: a format byte (marks a NEW_TOKEN token apart from a Retry one,
%% §8.1.1; this server sends no Retry), the nonce, then the sealed issue time
%% and address with their tag; the format byte is the associated data.
%%
%% A token is good for ?LIFETIME seconds (§8.1.3 SHOULD expire): long enough
%% for a client coming back within the hour, short enough that the set of
%% spent tokens the listener keeps to refuse a second use (§8.1.4) stays
%% small, and that a token seen on the wire is of use to an attacker only
%% briefly.

-export([new/2, seal/4, open/4, oldest/1]).

-define(FORMAT, 1).
-define(NONCE_LEN, 12).
-define(TAG_LEN, 16).
%% How long a token is accepted, in seconds.
-define(LIFETIME, 3600).
%% How far in the future an issue time may be (another server's clock may be
%% a little ahead), in seconds.
-define(CLOCK_SKEW, 60).

-doc """
A fresh token for a client at `Ip`, sealed under `Key` (32 bytes), issued
now with a random nonce.
""".
-spec new(<<_:256>>, inet:ip_address()) -> binary().
new(Key, Ip) ->
    seal(Key, Ip, erlang:system_time(second), crypto:strong_rand_bytes(?NONCE_LEN)).

-doc "The token for a client at `Ip`, issued at second `IssuedAt` with `Nonce`.".
-spec seal(<<_:256>>, inet:ip_address(), non_neg_integer(), <<_:96>>) -> binary().
seal(Key, Ip, IssuedAt, Nonce) ->
    {Sealed, Tag} = crypto:crypto_one_time_aead(
        aes_256_gcm, Key, Nonce, <<IssuedAt:64, (ip_bytes(Ip))/binary>>, <<?FORMAT>>, true
    ),
    <<?FORMAT, Nonce/binary, Sealed/binary, Tag/binary>>.

-doc """
Open a token a client presented from `Ip` at second `Now`: `{ok, Id}` when
it was sealed under `Key` for that address and is still good, `Id` naming
it so it can be spent once; `error` for anything else, a malformed or
forged token, another address, or an expired token, all of which count as
no token at all (RFC 9000 §8.1.3).
""".
-spec open(<<_:256>>, binary(), inet:ip_address(), integer()) ->
    {ok, {non_neg_integer(), <<_:96>>}} | error.
open(Key, <<?FORMAT, Nonce:?NONCE_LEN/binary, Rest/binary>>, Ip, Now) when
    byte_size(Rest) > ?TAG_LEN
->
    SealedLen = byte_size(Rest) - ?TAG_LEN,
    <<Sealed:SealedLen/binary, Tag:?TAG_LEN/binary>> = Rest,
    IpBytes = ip_bytes(Ip),
    case crypto:crypto_one_time_aead(aes_256_gcm, Key, Nonce, Sealed, <<?FORMAT>>, Tag, false) of
        <<IssuedAt:64, IpBytes/binary>> when
            IssuedAt >= Now - ?LIFETIME, IssuedAt =< Now + ?CLOCK_SKEW
        ->
            {ok, {IssuedAt, Nonce}};
        _ ->
            error
    end;
open(_Key, _Token, _Ip, _Now) ->
    error.

-doc "The earliest issue time a token presented at second `Now` may have.".
-spec oldest(integer()) -> integer().
oldest(Now) ->
    Now - ?LIFETIME.

%% An address as its network-order bytes: 4 for IPv4, 16 for IPv6.
-spec ip_bytes(inet:ip_address()) -> binary().
ip_bytes({A, B, C, D}) ->
    <<A, B, C, D>>;
ip_bytes({A, B, C, D, E, F, G, H}) ->
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>.
