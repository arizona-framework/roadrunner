-module(roadrunner_quic_tls_hello).
-moduledoc false.

%% TLS 1.3 hello exchange (RFC 8446 §4.1.2/§4.1.3/§4.3.1) for a server-only
%% QUIC v1 endpoint: parse the client's ClientHello, and build the server's
%% ServerHello and EncryptedExtensions. v1 negotiates x25519
%% (NamedGroup 0x001d) and TLS_AES_128_GCM_SHA256 (0x1301) only.
%%
%% This module owns the message bodies; `roadrunner_quic_tls_handshake`
%% frames them (1-byte type + 24-bit length), and
%% `roadrunner_quic_transport_params` is the body of the
%% quic_transport_parameters extension (codepoint 0x0039, RFC 9001 §8.2).
%% `parse_client_hello/1` takes the already-deframed ClientHello body and
%% returns the fields a server needs as a map; the build functions return
%% the fully framed handshake message as an iolist.
%%
%% Pure codec: it parses and builds wire bytes and never crashes on a
%% malformed buffer (flat `{error, atom()}`). It does NOT negotiate or
%% validate the peer's choices (TLS version, cipher, group selection,
%% mandatory-extension presence) - that is the connection layer's job, so
%% `parse_client_hello/1` extracts what is present and leaves absent
%% extensions out of the map. The server build does not generate keys: the
%% caller owns the x25519 key pair and passes the public key in.

-export([parse_client_hello/1, build_server_hello/1, build_encrypted_extensions/1]).

-export_type([client_hello/0]).

%% Handshake message types (RFC 8446 §4), for framing via the C3 module.
-define(SERVER_HELLO, 2).
-define(ENCRYPTED_EXTENSIONS, 8).

%% Extension codepoints (RFC 8446 §4.2 + RFC 9001 §8.2).
-define(EXT_SERVER_NAME, 16#0000).
-define(EXT_SIGNATURE_ALGORITHMS, 16#000D).
-define(EXT_ALPN, 16#0010).
-define(EXT_SUPPORTED_VERSIONS, 16#002B).
-define(EXT_KEY_SHARE, 16#0033).
-define(EXT_QUIC_TRANSPORT_PARAMS, 16#0039).

%% Wire constants.
-define(LEGACY_VERSION, 16#0303).
-define(TLS_1_3, 16#0304).
-define(GROUP_X25519, 16#001D).
%% v1 cipher suite (the only suite the server offers).
-define(CIPHER_AES_128_GCM_SHA256, 16#1301).
%% SNI name_type 0 = host_name (RFC 6066 §3).
-define(SNI_HOST_NAME, 16#00).

-type client_hello() :: #{
    random := binary(),
    session_id := binary(),
    cipher_suites := [non_neg_integer()],
    alpn_protocols := [binary()],
    signature_algorithms := [non_neg_integer()],
    key_share => binary(),
    server_name => binary(),
    transport_params => roadrunner_quic_transport_params:params()
}.

%% =============================================================================
%% parse_client_hello/1
%% =============================================================================

-doc """
Parse a ClientHello body (RFC 8446 §4.1.2), as handed up by
`roadrunner_quic_tls_handshake:decode/1`. Returns the fields a server
needs as a map: the random and legacy session id (echoed in the
ServerHello), the offered cipher suites, the client's x25519 key share,
the offered ALPN protocols and signature schemes, and (when present) the
SNI host name and decoded QUIC transport parameters. Absent extensions
are simply left out of the map. Returns `{error, Reason}` on a malformed
buffer.
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
%% build_server_hello/1
%% =============================================================================

-doc """
Build a ServerHello (RFC 8446 §4.1.3), framed, as an iolist. Inputs:
`random` (32 bytes), `session_id` (the client's legacy session id, echoed
verbatim), and `key_share` (the server's 32-byte x25519 public key). The
cipher suite is fixed to TLS_AES_128_GCM_SHA256 and the group to x25519.
The two server extensions are key_share then supported_versions
(selecting TLS 1.3).
""".
-spec build_server_hello(#{
    random := binary(), session_id := binary(), key_share := binary()
}) -> iolist().
build_server_hello(#{random := Random, session_id := SessionId, key_share := PubKey}) ->
    Extensions = [
        encode_extension(?EXT_KEY_SHARE, server_key_share(PubKey)),
        encode_extension(?EXT_SUPPORTED_VERSIONS, <<?TLS_1_3:16>>)
    ],
    Body = [
        <<?LEGACY_VERSION:16, Random:32/binary, (byte_size(SessionId)):8>>,
        SessionId,
        <<?CIPHER_AES_128_GCM_SHA256:16, 0:8, (iolist_size(Extensions)):16>>,
        Extensions
    ],
    roadrunner_quic_tls_handshake:encode(?SERVER_HELLO, Body).

%% =============================================================================
%% build_encrypted_extensions/1
%% =============================================================================

-doc """
Build an EncryptedExtensions message (RFC 8446 §4.3.1), framed, as an
iolist. Carries the selected `alpn` protocol (RFC 7301) and the server's
QUIC `transport_params` (RFC 9001 §8.2); each is omitted if absent or
empty.
""".
-spec build_encrypted_extensions(#{
    alpn => binary(), transport_params => roadrunner_quic_transport_params:params()
}) -> iolist().
build_encrypted_extensions(Opts) ->
    Extensions = [alpn_extension(Opts), transport_params_extension(Opts)],
    Body = [<<(iolist_size(Extensions)):16>>, Extensions],
    roadrunner_quic_tls_handshake:encode(?ENCRYPTED_EXTENSIONS, Body).

%% =============================================================================
%% Internal - ClientHello field extraction
%% =============================================================================

%% Assemble the client_hello() map from the parsed pieces. The structural
%% extractors are lenient (a malformed extension is treated as absent);
%% only the transport parameters carry a validating decoder whose error
%% is propagated.
-spec finalize_client_hello(binary(), binary(), [non_neg_integer()], #{
    non_neg_integer() => binary()
}) ->
    {ok, client_hello()} | {error, atom()}.
finalize_client_hello(Random, SessionId, Ciphers, Extensions) ->
    Base = #{
        random => Random,
        session_id => SessionId,
        cipher_suites => Ciphers,
        alpn_protocols => extract_alpn(Extensions),
        signature_algorithms => extract_signature_algorithms(Extensions)
    },
    WithKeyShare = maybe_put(key_share, extract_x25519_key_share(Extensions), Base),
    WithName = maybe_put(server_name, extract_server_name(Extensions), WithKeyShare),
    case extract_transport_params(Extensions) of
        none -> {ok, WithName};
        {ok, Params} -> {ok, WithName#{transport_params => Params}};
        {error, _} = Error -> Error
    end.

-spec maybe_put(atom(), undefined | term(), map()) -> map().
maybe_put(_Key, undefined, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => Value}.

%% The x25519 public key from the client's key_share list (RFC 8446
%% §4.2.8), or undefined if the client offered no x25519 entry.
-spec extract_x25519_key_share(#{non_neg_integer() => binary()}) -> binary() | undefined.
extract_x25519_key_share(#{?EXT_KEY_SHARE := Data}) ->
    case take_u16_vector(Data) of
        {ok, Entries, _Rest} -> find_x25519_entry(Entries);
        {error, _} -> undefined
    end;
extract_x25519_key_share(#{}) ->
    undefined.

-spec find_x25519_entry(binary()) -> binary() | undefined.
find_x25519_entry(<<?GROUP_X25519:16, KeyLen:16, Key:KeyLen/binary, _Rest/binary>>) ->
    Key;
find_x25519_entry(<<_Group:16, KeyLen:16, _Key:KeyLen/binary, Rest/binary>>) ->
    find_x25519_entry(Rest);
find_x25519_entry(_) ->
    undefined.

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
%% C4 codec, or `none` if the extension is absent.
-spec extract_transport_params(#{non_neg_integer() => binary()}) ->
    none | {ok, roadrunner_quic_transport_params:params()} | {error, atom()}.
extract_transport_params(#{?EXT_QUIC_TRANSPORT_PARAMS := Data}) ->
    roadrunner_quic_transport_params:decode(Data);
extract_transport_params(#{}) ->
    none.

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

%% A ServerHello key_share extension body: a single bare KeyShareEntry
%% (RFC 8446 §4.2.8), no list-length prefix.
-spec server_key_share(binary()) -> iolist().
server_key_share(PubKey) ->
    [<<?GROUP_X25519:16, (byte_size(PubKey)):16>>, PubKey].

%% The EncryptedExtensions ALPN extension carrying the single selected
%% protocol (RFC 7301 §3.1), or [] when no protocol was selected. An empty
%% protocol is treated as absent: a zero-length ProtocolName is invalid
%% (RFC 7301 §3.1), so it is omitted rather than emitted malformed.
-spec alpn_extension(#{alpn => binary(), _ => _}) -> iolist().
alpn_extension(#{alpn := Protocol}) when byte_size(Protocol) > 0 ->
    NameList = [<<(byte_size(Protocol)):8>>, Protocol],
    encode_extension(?EXT_ALPN, [<<(iolist_size(NameList)):16>>, NameList]);
alpn_extension(#{}) ->
    [].

%% The EncryptedExtensions quic_transport_parameters extension (RFC 9001
%% §8.2), or [] when no parameters were given (an empty map is absent).
-spec transport_params_extension(#{
    transport_params => roadrunner_quic_transport_params:params(), _ => _
}) ->
    iolist().
transport_params_extension(#{transport_params := Params}) when map_size(Params) > 0 ->
    encode_extension(?EXT_QUIC_TRANSPORT_PARAMS, roadrunner_quic_transport_params:encode(Params));
transport_params_extension(#{}) ->
    [].

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
