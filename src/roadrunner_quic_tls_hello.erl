-module(roadrunner_quic_tls_hello).
-moduledoc false.

%% TLS 1.3 hello exchange (RFC 8446 §4.1.2/§4.1.3/§4.1.4/§4.3.1) for a
%% server-only QUIC v1 endpoint: parse the client's ClientHello, and build
%% the server's ServerHello, HelloRetryRequest and EncryptedExtensions. The
%% ServerHello and HelloRetryRequest carry the cipher suite and key exchange
%% group the caller selected.
%%
%% This module owns the message bodies; `roadrunner_quic_tls_handshake`
%% frames them (1-byte type + 24-bit length), and
%% `roadrunner_quic_transport_params` is the body of the
%% quic_transport_parameters extension (codepoint 0x0039, RFC 9001 §8.2).
%% `parse_client_hello/1` takes the already-deframed ClientHello body and
%% returns the fields a server needs as an opaque record, read with one
%% accessor per field; the build functions return the fully framed
%% handshake message as an iolist.
%%
%% Pure codec: it parses and builds wire bytes and never crashes on a
%% malformed buffer (flat `{error, atom()}`). It does NOT negotiate or
%% validate the peer's choices (TLS version, cipher, group selection,
%% mandatory-extension presence) - that is the connection layer's job, so
%% `parse_client_hello/1` extracts what is present and leaves absent
%% extensions `undefined`. The server build does not generate keys: the
%% caller owns the ephemeral key pair and passes the public key in.

-export([
    parse_client_hello/1,
    build_server_hello/4,
    build_hello_retry_request/3,
    build_encrypted_extensions/2
]).
-export([
    random/1,
    session_id/1,
    cipher_suites/1,
    supported_versions/1,
    alpn_protocols/1,
    signature_algorithms/1,
    supported_groups/1,
    key_shares/1,
    server_name/1,
    transport_params/1
]).

-export_type([client_hello/0]).

%% Handshake message types (RFC 8446 §4), for framing via the C3 module.
-define(SERVER_HELLO, 2).
-define(ENCRYPTED_EXTENSIONS, 8).

%% Extension codepoints (RFC 8446 §4.2 + RFC 9001 §8.2).
-define(EXT_SERVER_NAME, 16#0000).
-define(EXT_SUPPORTED_GROUPS, 16#000A).
-define(EXT_SIGNATURE_ALGORITHMS, 16#000D).
-define(EXT_ALPN, 16#0010).
-define(EXT_SUPPORTED_VERSIONS, 16#002B).
-define(EXT_KEY_SHARE, 16#0033).
-define(EXT_QUIC_TRANSPORT_PARAMS, 16#0039).

%% Wire constants.
-define(LEGACY_VERSION, 16#0303).
-define(TLS_1_3, 16#0304).
%% The HelloRetryRequest's Random: SHA-256 of "HelloRetryRequest" (RFC 8446
%% §4.1.3), which marks a ServerHello-shaped message as a HelloRetryRequest.
-define(HELLO_RETRY_RANDOM,
    <<16#CF, 16#21, 16#AD, 16#74, 16#E5, 16#9A, 16#61, 16#11, 16#BE, 16#1D, 16#8C, 16#02, 16#1E,
        16#65, 16#B8, 16#91, 16#C2, 16#A2, 16#11, 16#16, 16#7A, 16#BB, 16#8C, 16#5E, 16#07, 16#9E,
        16#09, 16#E2, 16#C8, 16#A8, 16#33, 16#9C>>
).
%% SNI name_type 0 = host_name (RFC 6066 §3).
-define(SNI_HOST_NAME, 16#00).

%% The extensions a ClientHello may leave out are `undefined` while absent.
-record(client_hello, {
    random :: binary(),
    session_id :: binary(),
    cipher_suites :: [non_neg_integer()],
    supported_versions :: [non_neg_integer()],
    alpn_protocols :: [binary()],
    signature_algorithms :: [non_neg_integer()],
    supported_groups = undefined :: [non_neg_integer()] | undefined,
    key_shares = undefined :: [{non_neg_integer(), binary()}] | undefined,
    server_name = undefined :: binary() | undefined,
    transport_params = undefined :: roadrunner_quic_transport_params:params() | undefined
}).

-opaque client_hello() :: #client_hello{}.

%% =============================================================================
%% parse_client_hello/1
%% =============================================================================

-doc """
Parse a ClientHello body (RFC 8446 §4.1.2), as handed up by
`roadrunner_quic_tls_handshake:decode/1`. Returns the fields a server
needs: the random and legacy session id (echoed in the
ServerHello), the offered cipher suites and TLS versions
(supported_versions, RFC 8446 §4.2.1), the offered ALPN protocols and
signature schemes, and (when present) the offered groups
(supported_groups, §4.2.7), the client's key shares as `{Group,
KeyExchange}` pairs in its order (key_share, §4.2.8), the SNI host name,
and the decoded QUIC transport parameters. The version, ALPN and signature
lists read as empty when their extension is absent; the other absent
extensions read as `undefined`, so a caller can tell an absent
supported_groups or key_share (RFC 8446 §9.2) from an empty one. Returns
`{error, Reason}` on a malformed buffer.
""".
-spec parse_client_hello(binary()) -> {ok, client_hello()} | {error, atom()}.
parse_client_hello(<<?LEGACY_VERSION:16, Random:32/binary, AfterRandom/binary>>) ->
    maybe
        {ok, SessionId, AfterSession} ?= take_u8_vector(AfterRandom),
        {ok, CipherBytes, AfterCiphers} ?= take_u16_vector(AfterSession),
        {ok, _Compression, AfterCompression} ?= take_u8_vector(AfterCiphers),
        {ok, ExtBytes, _Rest} ?= take_u16_vector(AfterCompression),
        {ok, Extensions} ?= parse_extensions(ExtBytes),
        finalize_client_hello(Random, SessionId, parse_cipher_suites(CipherBytes), Extensions)
    end;
parse_client_hello(_) ->
    {error, malformed_client_hello}.

%% =============================================================================
%% build_server_hello/4
%% =============================================================================

-doc """
Build a ServerHello (RFC 8446 §4.1.3), framed, as an iolist, from its
`Random` (32 bytes), the client's legacy `SessionId` (echoed verbatim), the
selected suite's `CipherSuite` codepoint, and the server's `{Group,
PublicKey}` key share for the selected group (a KeyShareEntry, RFC 8446
§4.2.8). The two server extensions are key_share then supported_versions
(selecting TLS 1.3).
""".
-spec build_server_hello(
    binary(), binary(), non_neg_integer(), {non_neg_integer(), binary()}
) -> iolist().
build_server_hello(Random, SessionId, CipherSuite, {Group, PubKey}) ->
    KeyShareEntry = [<<Group:16, (byte_size(PubKey)):16>>, PubKey],
    server_hello(Random, SessionId, CipherSuite, KeyShareEntry).

%% =============================================================================
%% build_hello_retry_request/3
%% =============================================================================

-doc """
Build a HelloRetryRequest (RFC 8446 §4.1.4), framed, as an iolist: a
ServerHello whose Random is the fixed HelloRetryRequest value (§4.1.3),
asking the client for a key share in the selected `Group`. `SessionId`
(echoed verbatim) and `CipherSuite` are as for a ServerHello. The two
extensions are key_share, carrying just the selected group
(KeyShareHelloRetryRequest, §4.2.8), then supported_versions (selecting
TLS 1.3); no cookie is sent.
""".
-spec build_hello_retry_request(binary(), non_neg_integer(), non_neg_integer()) -> iolist().
build_hello_retry_request(SessionId, CipherSuite, Group) ->
    server_hello(?HELLO_RETRY_RANDOM, SessionId, CipherSuite, <<Group:16>>).

%% =============================================================================
%% build_encrypted_extensions/2
%% =============================================================================

-doc """
Build an EncryptedExtensions message (RFC 8446 §4.3.1), framed, as an
iolist. Carries the selected `Alpn` protocol (RFC 7301) and the server's
QUIC `TransportParams` (RFC 9001 §8.2); each is omitted if empty.
""".
-spec build_encrypted_extensions(binary(), roadrunner_quic_transport_params:params()) -> iolist().
build_encrypted_extensions(Alpn, TransportParams) ->
    Extensions = [alpn_extension(Alpn), transport_params_extension(TransportParams)],
    Body = [<<(iolist_size(Extensions)):16>>, Extensions],
    roadrunner_quic_tls_handshake:encode(?ENCRYPTED_EXTENSIONS, Body).

%% =============================================================================
%% ClientHello accessors
%% =============================================================================

-doc "The ClientHello's 32-byte Random.".
-spec random(client_hello()) -> binary().
random(#client_hello{random = V}) -> V.

-doc "The legacy session id, echoed in the ServerHello.".
-spec session_id(client_hello()) -> binary().
session_id(#client_hello{session_id = V}) -> V.

-doc "The offered cipher suite codepoints, in the client's order.".
-spec cipher_suites(client_hello()) -> [non_neg_integer()].
cipher_suites(#client_hello{cipher_suites = V}) -> V.

-doc "The offered TLS versions (supported_versions), empty when absent.".
-spec supported_versions(client_hello()) -> [non_neg_integer()].
supported_versions(#client_hello{supported_versions = V}) -> V.

-doc "The offered ALPN protocols, empty when absent.".
-spec alpn_protocols(client_hello()) -> [binary()].
alpn_protocols(#client_hello{alpn_protocols = V}) -> V.

-doc "The offered signature schemes, empty when absent.".
-spec signature_algorithms(client_hello()) -> [non_neg_integer()].
signature_algorithms(#client_hello{signature_algorithms = V}) -> V.

-doc "The offered groups (supported_groups), `undefined` when absent.".
-spec supported_groups(client_hello()) -> [non_neg_integer()] | undefined.
supported_groups(#client_hello{supported_groups = V}) -> V.

-doc "The client's `{Group, KeyExchange}` key shares, `undefined` when absent.".
-spec key_shares(client_hello()) -> [{non_neg_integer(), binary()}] | undefined.
key_shares(#client_hello{key_shares = V}) -> V.

-doc "The SNI host name, `undefined` when absent.".
-spec server_name(client_hello()) -> binary() | undefined.
server_name(#client_hello{server_name = V}) -> V.

-doc "The client's QUIC transport parameters, `undefined` when absent.".
-spec transport_params(client_hello()) -> roadrunner_quic_transport_params:params() | undefined.
transport_params(#client_hello{transport_params = V}) -> V.

%% =============================================================================
%% Internal - ClientHello field extraction
%% =============================================================================

%% Assemble the client_hello() record from the parsed pieces. The structural
%% extractors are lenient (a malformed extension is treated as absent);
%% only the transport parameters carry a validating decoder whose error
%% is propagated.
-spec finalize_client_hello(binary(), binary(), [non_neg_integer()], #{
    non_neg_integer() => binary()
}) ->
    {ok, client_hello()} | {error, atom()}.
finalize_client_hello(Random, SessionId, Ciphers, Extensions) ->
    case extract_transport_params(Extensions) of
        {error, _} = Error ->
            Error;
        TransportParams ->
            {ok, #client_hello{
                random = Random,
                session_id = SessionId,
                cipher_suites = Ciphers,
                supported_versions = extract_supported_versions(Extensions),
                alpn_protocols = extract_alpn(Extensions),
                signature_algorithms = extract_signature_algorithms(Extensions),
                supported_groups = extract_supported_groups(Extensions),
                key_shares = extract_key_shares(Extensions),
                server_name = extract_server_name(Extensions),
                transport_params = TransportParams
            }}
    end.

%% The offered groups (RFC 8446 §4.2.7: a two-byte-length list of 16-bit
%% NamedGroups) in the client's order, or undefined if the extension is
%% absent or malformed.
-spec extract_supported_groups(#{non_neg_integer() => binary()}) ->
    [non_neg_integer()] | undefined.
extract_supported_groups(#{?EXT_SUPPORTED_GROUPS := Data}) ->
    case take_u16_vector(Data) of
        {ok, List, _Rest} -> parse_u16_list(List);
        {error, _} -> undefined
    end;
extract_supported_groups(#{}) ->
    undefined.

%% The client's key shares (RFC 8446 §4.2.8: a two-byte-length list of
%% KeyShareEntry) as `{Group, KeyExchange}` pairs in its order, or undefined
%% if the extension is absent or malformed. An empty list is a valid offer
%% (the client asks the server to pick a group, §4.2.8).
-spec extract_key_shares(#{non_neg_integer() => binary()}) ->
    [{non_neg_integer(), binary()}] | undefined.
extract_key_shares(#{?EXT_KEY_SHARE := Data}) ->
    case take_u16_vector(Data) of
        {ok, Entries, _Rest} -> parse_key_share_entries(Entries);
        {error, _} -> undefined
    end;
extract_key_shares(#{}) ->
    undefined.

%% A packed KeyShareEntry list; a trailing partial entry is dropped.
-spec parse_key_share_entries(binary()) -> [{non_neg_integer(), binary()}].
parse_key_share_entries(<<Group:16, KeyLen:16, Key:KeyLen/binary, Rest/binary>>) ->
    [{Group, Key} | parse_key_share_entries(Rest)];
parse_key_share_entries(_) ->
    [].

%% The offered TLS versions (RFC 8446 §4.2.1: a one-byte-length list of
%% 16-bit versions), [] if absent or malformed.
-spec extract_supported_versions(#{non_neg_integer() => binary()}) -> [non_neg_integer()].
extract_supported_versions(#{?EXT_SUPPORTED_VERSIONS := Data}) ->
    case take_u8_vector(Data) of
        {ok, List, _Rest} -> parse_u16_list(List);
        {error, _} -> []
    end;
extract_supported_versions(#{}) ->
    [].

%% The ALPN protocol list (RFC 7301), [] if absent or malformed.
-spec extract_alpn(#{non_neg_integer() => binary()}) -> [binary()].
extract_alpn(#{?EXT_ALPN := Data}) ->
    case take_u16_vector(Data) of
        {ok, List, _Rest} -> parse_alpn_list(List);
        {error, _} -> []
    end;
extract_alpn(#{}) ->
    [].

-spec parse_alpn_list(binary()) -> [binary()].
parse_alpn_list(<<Len:8, Proto:Len/binary, Rest/binary>>) ->
    [Proto | parse_alpn_list(Rest)];
parse_alpn_list(_) ->
    [].

%% The offered signature schemes (RFC 8446 §4.2.3), [] if absent.
-spec extract_signature_algorithms(#{non_neg_integer() => binary()}) -> [non_neg_integer()].
extract_signature_algorithms(#{?EXT_SIGNATURE_ALGORITHMS := Data}) ->
    case take_u16_vector(Data) of
        {ok, List, _Rest} -> parse_u16_list(List);
        {error, _} -> []
    end;
extract_signature_algorithms(#{}) ->
    [].

%% The SNI host name (RFC 6066 §3, name_type 0), or undefined.
-spec extract_server_name(#{non_neg_integer() => binary()}) -> binary() | undefined.
extract_server_name(#{?EXT_SERVER_NAME := Data}) ->
    case take_u16_vector(Data) of
        {ok, <<?SNI_HOST_NAME:8, NameLen:16, Name:NameLen/binary, _/binary>>, _Rest} -> Name;
        _ -> undefined
    end;
extract_server_name(#{}) ->
    undefined.

%% Decode the QUIC transport parameters extension (RFC 9001 §8.2) via the
%% C4 codec, or `none` if the extension is absent. Any rejection (malformed,
%% out of range, duplicated, or server-only) is a TRANSPORT_PARAMETER_ERROR
%% (RFC 9000 §7.4, §18.2), not a TLS alert.
-spec extract_transport_params(#{non_neg_integer() => binary()}) ->
    roadrunner_quic_transport_params:params()
    | undefined
    | {error, transport_parameter_error}.
extract_transport_params(#{?EXT_QUIC_TRANSPORT_PARAMS := Data}) ->
    case roadrunner_quic_transport_params:decode(Data) of
        {ok, Params} -> Params;
        {error, _} -> {error, transport_parameter_error}
    end;
extract_transport_params(#{}) ->
    undefined.

-spec parse_cipher_suites(binary()) -> [non_neg_integer()].
parse_cipher_suites(Bin) ->
    parse_u16_list(Bin).

%% A packed list of 16-bit values; a trailing partial value is dropped.
-spec parse_u16_list(binary()) -> [non_neg_integer()].
parse_u16_list(<<Value:16, Rest/binary>>) ->
    [Value | parse_u16_list(Rest)];
parse_u16_list(_) ->
    [].

%% =============================================================================
%% Internal - extension list codec (RFC 8446 §4.2)
%% =============================================================================

%% Parse the extension vector into a map of type => extension_data,
%% rejecting a duplicated extension type (RFC 8446 §4.2).
-spec parse_extensions(binary()) -> {ok, #{non_neg_integer() => binary()}} | {error, atom()}.
parse_extensions(Bin) ->
    parse_extensions(Bin, #{}).

-spec parse_extensions(binary(), #{non_neg_integer() => binary()}) ->
    {ok, #{non_neg_integer() => binary()}} | {error, atom()}.
parse_extensions(<<>>, Acc) ->
    {ok, Acc};
parse_extensions(<<Type:16, Len:16, Data:Len/binary, Rest/binary>>, Acc) ->
    case Acc of
        #{Type := _} -> {error, duplicate_extension};
        #{} -> parse_extensions(Rest, Acc#{Type => Data})
    end;
parse_extensions(_, _) ->
    {error, malformed_extensions}.

%% One extension as a Type:16, Length:16, Data record (RFC 8446 §4.2).
-spec encode_extension(non_neg_integer(), iodata()) -> iolist().
encode_extension(Type, Data) ->
    [<<Type:16, (iolist_size(Data)):16>>, Data].

%% The ServerHello structure (RFC 8446 §4.1.3), shared by the ServerHello and
%% the HelloRetryRequest (§4.1.4), framed. `KeyShare` is the key_share
%% extension body, with no list-length prefix: a bare KeyShareEntry in a
%% ServerHello, the bare selected group in a HelloRetryRequest (§4.2.8).
-spec server_hello(binary(), binary(), non_neg_integer(), iodata()) -> iolist().
server_hello(Random, SessionId, CipherSuite, KeyShare) ->
    Extensions = [
        encode_extension(?EXT_KEY_SHARE, KeyShare),
        encode_extension(?EXT_SUPPORTED_VERSIONS, <<?TLS_1_3:16>>)
    ],
    Body = [
        <<?LEGACY_VERSION:16, Random:32/binary, (byte_size(SessionId)):8>>,
        SessionId,
        <<CipherSuite:16, 0:8, (iolist_size(Extensions)):16>>,
        Extensions
    ],
    roadrunner_quic_tls_handshake:encode(?SERVER_HELLO, Body).

%% The EncryptedExtensions ALPN extension carrying the single selected
%% protocol (RFC 7301 §3.1), or [] when no protocol was selected. An empty
%% protocol is treated as absent: a zero-length ProtocolName is invalid
%% (RFC 7301 §3.1), so it is omitted rather than emitted malformed.
-spec alpn_extension(binary()) -> iolist().
alpn_extension(<<>>) ->
    [];
alpn_extension(Protocol) ->
    NameList = [<<(byte_size(Protocol)):8>>, Protocol],
    encode_extension(?EXT_ALPN, [<<(iolist_size(NameList)):16>>, NameList]).

%% The EncryptedExtensions quic_transport_parameters extension (RFC 9001
%% §8.2), or [] when no parameters were given (an empty set is absent).
-spec transport_params_extension(roadrunner_quic_transport_params:params()) -> iolist().
transport_params_extension(Params) ->
    case roadrunner_quic_transport_params:encode(Params) of
        [] -> [];
        Encoded -> encode_extension(?EXT_QUIC_TRANSPORT_PARAMS, Encoded)
    end.

%% =============================================================================
%% Internal - wire helpers
%% =============================================================================

%% Read an 8-bit length prefix, then exactly that many bytes.
-spec take_u8_vector(binary()) -> {ok, binary(), binary()} | {error, atom()}.
take_u8_vector(<<Len:8, Value:Len/binary, Rest/binary>>) ->
    {ok, Value, Rest};
take_u8_vector(_) ->
    {error, truncated}.

%% Read a 16-bit length prefix, then exactly that many bytes.
-spec take_u16_vector(binary()) -> {ok, binary(), binary()} | {error, atom()}.
take_u16_vector(<<Len:16, Value:Len/binary, Rest/binary>>) ->
    {ok, Value, Rest};
take_u16_vector(_) ->
    {error, truncated}.
