-module(roadrunner_quic_test_client).
-moduledoc false.

%% Shared in-test QUIC client driver: the crypto/codec primitives a test
%% needs to play the QUIC client against the native server modules, used by
%% both the pure-value `roadrunner_quic_conn_state` tests and the
%% `roadrunner_quic_connection` process tests. The TLS 1.3 key schedule
%% itself is a handful of `roadrunner_quic_tls_crypto` calls each test makes
%% inline (the explicit client derivation is part of what the test asserts);
%% this module supplies the ClientHello codec, the packet sealing, and the
%% server-reply decoding so neither is duplicated.

-include_lib("public_key/include/public_key.hrl").

-export([key_material/0, gen_keypair/0]).
-export([client_hello_framed/3]).
-export([seal/6, seal_raw/6]).
-export([crypto_bytes/4, frames/4]).
-export([server_hello_key_share/1, deframe_all/1]).
-export([
    parse_server_hello/1,
    parse_encrypted_extensions/1,
    parse_certificate/1,
    parse_certificate_verify/1,
    parse_finished/1
]).
-export([verify_server_certificate_verify/4]).

%% TLS handshake message types (RFC 8446 §4).
-define(CLIENT_HELLO, 1).
-define(SERVER_HELLO, 2).

%% ClientHello wire constants (RFC 8446 §4.1.2).
-define(LEGACY_VERSION, 16#0303).
-define(CIPHER_AES_128_GCM_SHA256, 16#1301).
-define(GROUP_X25519, 16#001D).
-define(EXT_SIGNATURE_ALGORITHMS, 16#000D).
-define(EXT_ALPN, 16#0010).
-define(EXT_KEY_SHARE, 16#0033).
-define(EXT_QUIC_TRANSPORT_PARAMS, 16#0039).

%% Signature schemes (RFC 8446 §4.2.3) the server may sign with.
-define(SIG_RSA_PSS_RSAE_SHA256, 16#0804).
-define(SIG_ECDSA_SECP256R1_SHA256, 16#0403).
-define(SIG_ED25519, 16#0807).

%% The server CertificateVerify signature context (RFC 8446 §4.4.3).
-define(CERT_VERIFY_CONTEXT, ~"TLS 1.3, server CertificateVerify").

%% =============================================================================
%% Key material
%% =============================================================================

-doc "A fresh RSA key pair and its signature scheme (rsa_pss_rsae_sha256).".
-spec key_material() -> {Scheme :: 16#0804, public_key:private_key()}.
key_material() ->
    PrivKey = public_key:generate_key({rsa, 2048, 65537}),
    {16#0804, PrivKey}.

-doc "A fresh x25519 ephemeral key pair.".
-spec gen_keypair() -> {Pub :: binary(), Priv :: binary()}.
gen_keypair() ->
    crypto:generate_key(ecdh, x25519).

%% =============================================================================
%% ClientHello
%% =============================================================================

-doc """
A framed ClientHello (handshake-message bytes, RFC 8446 §4.1.2) offering
the given signature scheme, the x25519 key share, the `h3` ALPN, and a
quic_transport_parameters extension carrying `ClientSCID` as the
`initial_source_connection_id` (the server checks it against the client's
Initial SCID, RFC 9000 §7.3, and requires the extension's presence, RFC 9001
§8.2). `ClientSCID = none` omits the extension entirely, to exercise the §8.2
missing-extension path. These bytes are both the CRYPTO-frame payload and the
first transcript element.
""".
-spec client_hello_framed(
    Scheme :: non_neg_integer(), ClientPub :: binary(), ClientSCID :: binary() | none
) -> binary().
client_hello_framed(Scheme, ClientPub, ClientSCID) ->
    Random = crypto:strong_rand_bytes(32),
    Extensions = iolist_to_binary([
        signature_algorithms_ext([Scheme]),
        alpn_ext(~"h3"),
        key_share_ext(ClientPub),
        transport_params_ext(ClientSCID)
    ]),
    CipherSuites = <<?CIPHER_AES_128_GCM_SHA256:16>>,
    Body =
        <<?LEGACY_VERSION:16, Random/binary, 0:8, (byte_size(CipherSuites)):16, CipherSuites/binary,
            1:8, 0:8, (byte_size(Extensions)):16, Extensions/binary>>,
    iolist_to_binary(roadrunner_quic_tls_handshake:encode(?CLIENT_HELLO, Body)).

signature_algorithms_ext(Schemes) ->
    List = <<<<S:16>> || S <- Schemes>>,
    extension(?EXT_SIGNATURE_ALGORITHMS, <<(byte_size(List)):16, List/binary>>).

alpn_ext(Protocol) ->
    Entry = <<(byte_size(Protocol)):8, Protocol/binary>>,
    extension(?EXT_ALPN, <<(byte_size(Entry)):16, Entry/binary>>).

key_share_ext(PubKey) ->
    Entry = <<?GROUP_X25519:16, (byte_size(PubKey)):16, PubKey/binary>>,
    extension(?EXT_KEY_SHARE, <<(byte_size(Entry)):16, Entry/binary>>).

%% A quic_transport_parameters extension carrying just the client's
%% initial_source_connection_id, encoded with the production codec so the wire
%% bytes stay authoritative. `none` emits no extension at all.
transport_params_ext(none) ->
    <<>>;
transport_params_ext(ClientSCID) ->
    Body = iolist_to_binary(
        roadrunner_quic_transport_params:encode(#{initial_source_connection_id => ClientSCID})
    ),
    extension(?EXT_QUIC_TRANSPORT_PARAMS, Body).

extension(Type, Data) ->
    <<Type:16, (byte_size(Data)):16, Data/binary>>.

%% =============================================================================
%% Packet sealing (build client datagrams)
%% =============================================================================

-doc """
Build a one-level client datagram through the send pipeline. An Initial is
padded to 1200, satisfying the server's anti-amplification budget.
""".
-spec seal(
    roadrunner_quic_send:level(),
    non_neg_integer(),
    roadrunner_quic_keys:keys(),
    [roadrunner_quic_frame:frame()],
    binary(),
    binary()
) -> binary().
seal(Level, PN, Keys, Frames, DCID, SCID) ->
    Entries = #{Level => #{frames => Frames, keys => Keys, pn => PN}},
    {Datagram, _Sent} = roadrunner_quic_send:datagram(Entries, DCID, SCID),
    Datagram.

-doc """
Seal raw plaintext (bypassing frame encoding) so a packet can carry a
deliberately malformed frame, mirroring the send path's header sizing.
""".
-spec seal_raw(
    roadrunner_quic_packet:long_type(),
    non_neg_integer(),
    roadrunner_quic_keys:keys(),
    binary(),
    binary(),
    binary()
) -> binary().
seal_raw(Level, PN, #{key := Key, iv := IV, hp := HP}, Plaintext, DCID, SCID) ->
    PNLen = roadrunner_quic_packet:pn_length(PN),
    SealedSize = byte_size(Plaintext) + 16,
    [Header, _Payload] = roadrunner_quic_packet:encode_long(
        Level, 1, DCID, SCID, #{pn => PN, payload => <<0:(SealedSize * 8)>>}
    ),
    Sealed = roadrunner_quic_aead:seal(Key, IV, PN, Header, Plaintext),
    Protected = roadrunner_quic_aead:protect_header(HP, Header, Sealed, byte_size(Header) - PNLen),
    <<Protected/binary, Sealed/binary>>.

%% =============================================================================
%% Decode server datagrams
%% =============================================================================

-doc """
Contiguous CRYPTO bytes for a level across the server's datagrams. The
per-level keys map filters out the other levels' packets (they decode to
`{drop, no_keys}`); with no in-test loss a sorted concat reassembles the
flight.
""".
-spec crypto_bytes(
    [binary()],
    roadrunner_quic_recv:level(),
    #{roadrunner_quic_recv:level() => map()},
    non_neg_integer()
) -> binary().
crypto_bytes(Datagrams, Level, Keys, DCIDLen) ->
    Slices = [{Offset, Data} || {crypto, Offset, Data} <- frames(Datagrams, Level, Keys, DCIDLen)],
    iolist_to_binary([Data || {_Offset, Data} <- lists:sort(Slices)]).

-doc "Every frame decoded at a level across the server's datagrams.".
-spec frames(
    [binary()],
    roadrunner_quic_recv:level(),
    #{roadrunner_quic_recv:level() => map()},
    non_neg_integer()
) -> [roadrunner_quic_frame:frame()].
frames(Datagrams, Level, Keys, DCIDLen) ->
    lists:append([level_frames(Datagram, Level, Keys, DCIDLen) || Datagram <- Datagrams]).

level_frames(Datagram, Level, Keys, DCIDLen) ->
    Outcomes = roadrunner_quic_recv:datagram(Datagram, DCIDLen, Keys, #{}),
    lists:append([Fs || {ok, #{level := L, frames := Fs}} <- Outcomes, L =:= Level]).

%% =============================================================================
%% Handshake-message decoding
%% =============================================================================

-doc "The server's x25519 public key from a (framed) ServerHello's key_share extension.".
-spec server_hello_key_share(binary()) -> binary().
server_hello_key_share(ServerHello) ->
    [{?SERVER_HELLO, Body} | _] = deframe_all(ServerHello),
    maps:get(key_share, parse_server_hello(Body)).

extract_extension(Type, <<Type:16, Len:16, Data:Len/binary, _Rest/binary>>) ->
    Data;
extract_extension(Type, <<_OtherType:16, Len:16, _Data:Len/binary, Rest/binary>>) ->
    extract_extension(Type, Rest).

-doc "Decode all framed handshake messages into `{Type, Body}` pairs.".
-spec deframe_all(iodata()) -> [{byte(), binary()}].
deframe_all(Iolist) ->
    deframe_all_bin(iolist_to_binary(Iolist)).

deframe_all_bin(<<>>) ->
    [];
deframe_all_bin(Bin) ->
    {ok, {Type, Body}, Rest} = roadrunner_quic_tls_handshake:decode(Bin),
    [{Type, Body} | deframe_all_bin(Rest)].

%% =============================================================================
%% Server-flight parsing (the client mirror of the server-side build,
%% RFC 8446 §4.1.3/§4.3.1/§4.4). Each takes a deframed handshake-message body.
%% These parse trusted server output in tests, so they pattern-match strictly
%% and let it crash on a malformed buffer rather than returning `{error, _}`.
%% =============================================================================

-doc "ServerHello body: the server random, echoed session id, selected cipher, and x25519 key share.".
-spec parse_server_hello(binary()) ->
    #{
        random := binary(),
        session_id := binary(),
        cipher := non_neg_integer(),
        key_share := binary()
    }.
parse_server_hello(Body) ->
    <<?LEGACY_VERSION:16, Random:32/binary, SidLen:8, SessionId:SidLen/binary, Cipher:16, 0:8,
        ExtsLen:16, Exts:ExtsLen/binary>> = Body,
    <<?GROUP_X25519:16, KeyLen:16, KeyShare:KeyLen/binary>> =
        extract_extension(?EXT_KEY_SHARE, Exts),
    #{random => Random, session_id => SessionId, cipher => Cipher, key_share => KeyShare}.

-doc "EncryptedExtensions body: the selected ALPN protocol and decoded QUIC transport parameters, each present when the server sent it.".
-spec parse_encrypted_extensions(binary()) ->
    #{
        alpn => binary(), transport_params => roadrunner_quic_transport_params:params()
    }.
parse_encrypted_extensions(<<ExtsLen:16, Exts:ExtsLen/binary>>) ->
    ExtMap = extension_map(Exts),
    add_transport_params(ExtMap, add_alpn(ExtMap, #{})).

add_alpn(#{?EXT_ALPN := <<_ListLen:16, NameLen:8, Proto:NameLen/binary>>}, Acc) ->
    Acc#{alpn => Proto};
add_alpn(#{}, Acc) ->
    Acc.

add_transport_params(#{?EXT_QUIC_TRANSPORT_PARAMS := Data}, Acc) ->
    {ok, Params} = roadrunner_quic_transport_params:decode(Data),
    Acc#{transport_params => Params};
add_transport_params(#{}, Acc) ->
    Acc.

-doc "Certificate body: the DER certificate chain, leaf first (RFC 8446 §4.4.2).".
-spec parse_certificate(binary()) -> [binary()].
parse_certificate(<<CtxLen:8, _Ctx:CtxLen/binary, ListLen:24, List:ListLen/binary>>) ->
    cert_entries(List).

cert_entries(<<>>) ->
    [];
cert_entries(<<CertLen:24, Cert:CertLen/binary, ExtLen:16, _Exts:ExtLen/binary, Rest/binary>>) ->
    [Cert | cert_entries(Rest)].

-doc "CertificateVerify body: the signature scheme and signature bytes (RFC 8446 §4.4.3).".
-spec parse_certificate_verify(binary()) -> {non_neg_integer(), binary()}.
parse_certificate_verify(<<Scheme:16, SigLen:16, Signature:SigLen/binary>>) ->
    {Scheme, Signature}.

-doc "Finished body: the verify_data MAC itself (RFC 8446 §4.4.4).".
-spec parse_finished(binary()) -> binary().
parse_finished(VerifyData) ->
    VerifyData.

%% A lenient type => data map of an extension vector, for the optional
%% EncryptedExtensions extensions.
extension_map(<<>>) ->
    #{};
extension_map(<<Type:16, Len:16, Data:Len/binary, Rest/binary>>) ->
    (extension_map(Rest))#{Type => Data}.

%% =============================================================================
%% Server CertificateVerify verification (RFC 8446 §4.4.3) - the client side
%% of the server's signing. Reconstructs the signed content (64 spaces, the
%% context string, a 0 separator, then the transcript hash through the
%% Certificate message) and verifies `Signature` under `Scheme` with the
%% server's public key.
%% =============================================================================

-doc "Verify a server CertificateVerify signature over `TranscriptHash` with the server's `PublicKey`.".
-spec verify_server_certificate_verify(
    non_neg_integer(), binary(), public_key:public_key(), binary()
) -> boolean().
verify_server_certificate_verify(Scheme, Signature, PublicKey, TranscriptHash) ->
    Content = iolist_to_binary([
        binary:copy(<<16#20>>, 64), ?CERT_VERIFY_CONTEXT, 0, TranscriptHash
    ]),
    {SigAlg, HashAlg, Options} = verify_params(Scheme),
    crypto:verify(SigAlg, HashAlg, Content, Signature, crypto_pubkey(Scheme, PublicKey), Options).

-spec verify_params(non_neg_integer()) -> {atom(), atom(), [{atom(), atom() | integer()}]}.
verify_params(?SIG_RSA_PSS_RSAE_SHA256) ->
    {rsa, sha256, [{rsa_padding, rsa_pkcs1_pss_padding}, {rsa_pss_saltlen, -1}]};
verify_params(?SIG_ECDSA_SECP256R1_SHA256) ->
    {ecdsa, sha256, []};
verify_params(?SIG_ED25519) ->
    {eddsa, none, []}.

%% Convert the public_key public-key term into the key form crypto:verify
%% expects for the scheme (mirror of the server-side crypto_key/2).
-spec crypto_pubkey(non_neg_integer(), public_key:public_key()) -> [integer() | binary() | atom()].
crypto_pubkey(?SIG_RSA_PSS_RSAE_SHA256, #'RSAPublicKey'{publicExponent = E, modulus = N}) ->
    [E, N];
crypto_pubkey(?SIG_ECDSA_SECP256R1_SHA256, {#'ECPoint'{point = Point}, _Params}) ->
    [Point, secp256r1];
crypto_pubkey(?SIG_ED25519, {#'ECPoint'{point = Point}, _Params}) ->
    [Point, ed25519].
