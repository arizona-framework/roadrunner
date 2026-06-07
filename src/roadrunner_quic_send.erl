-module(roadrunner_quic_send).
-moduledoc false.

%% QUIC v1 send pipeline (RFC 9000 §12.2/§14.1, RFC 9001 §5), pure: the
%% inverse of `roadrunner_quic_recv`.
%%
%% Given the frames to send per encryption level (each with its keys and
%% packet number), it encodes the frames, AEAD-seals each packet (the
%% unprotected header is the associated data), applies header protection,
%% and coalesces the packets into ONE UDP datagram in increasing
%% encryption-level order (Initial, then Handshake, then 1-RTT). It returns
%% the datagram bytes plus a per-packet record (level, packet number,
%% length, ack-eliciting?) the connection loop feeds into loss/ACK/CC
%% tracking.
%%
%% Pure and stateless: the chosen frames, keys, and packet numbers are
%% inputs. Frame selection, ACK generation, retransmission, packet-number
%% assignment, and all anti-amplification/CC/loss state stay in the loop;
%% this module assembles whatever it is handed. The loop gates the result
%% against the §8.1 anti-amplification budget (it owns `roadrunner_quic_amp`)
%% before sending, so this module never caps or defers.
%%
%% Two paddings, deliberately distinct: every packet's plaintext is padded
%% to the RFC 9001 §5.4.2 header-protection-sample minimum before sealing,
%% and a datagram that carries an Initial is padded once at the end to the
%% RFC 9000 §14.1 minimum of 1200 bytes with trailing zero bytes
%% (`roadrunner_quic_recv` stops at them). The trailing pad is valid only
%% when the datagram's last packet is long-header, so coalescing an Initial
%% with a 1-RTT (short-header) packet is rejected: a server never holds
%% 1-RTT keys while still sending Initials, so it never arises.
%%
%% A sent-record's `length` is the bare per-packet wire size; the §14.1
%% trailing pad belongs to the datagram, not any packet, so the loop
%% accounts anti-amplification and congestion-control datagram bytes via
%% the returned datagram's size. The record also carries the packet's
%% frames so the loop can retransmit them if it is later declared lost.

-export([datagram/3]).

-export_type([level/0, entry/0, sent/0]).

%% The QUIC v1 version number (RFC 9000 §15); this is a v1-only endpoint.
-define(QUIC_V1, 16#00000001).
%% RFC 9000 §14.1: a datagram carrying an Initial packet is >= 1200 bytes.
-define(MIN_INITIAL_DATAGRAM, 1200).
%% RFC 9001 §5.4.2: the header-protection sample is 16 bytes at 4 past the
%% packet-number start, so the plaintext must seal to at least that; 4
%% bytes of plaintext covers the worst case (a 1-byte packet number).
-define(MIN_SAMPLE_PLAINTEXT, 4).
%% AEAD authentication tag length (RFC 9001 §5.3).
-define(TAG_LEN, 16).

-type level() :: initial | handshake | application.

-type entry() :: #{
    frames := [roadrunner_quic_frame:frame()],
    keys := roadrunner_quic_keys:keys(),
    pn := non_neg_integer(),
    %% 1-RTT key phase (application level only); defaults to 0.
    key_phase => 0 | 1
}.

-type sent() :: #{
    level := level(),
    pn := non_neg_integer(),
    length := non_neg_integer(),
    ack_eliciting := boolean(),
    frames := [roadrunner_quic_frame:frame()]
}.

-doc """
Assemble one UDP datagram from the per-level send entries. `Entries` maps
each encryption level to send to its `#{frames, keys, pn}` (plus an
optional `key_phase` for the application level); packets are built in
Initial, Handshake, 1-RTT order. `DCID` is the destination connection id
(the peer's chosen source id) and `SCID` the server's source id (used by
long headers only). Returns the datagram bytes and one sent-record per
packet, in datagram order.
""".
-spec datagram(#{level() => entry()}, binary(), binary()) -> {binary(), [sent()]}.
datagram(Entries, DCID, SCID) ->
    {Packets, Sent} = build_levels([initial, handshake, application], Entries, DCID, SCID),
    {pad_datagram(iolist_to_binary(Packets), Entries), Sent}.

%% =============================================================================
%% Internal
%% =============================================================================

%% Build a packet for each present level in the given order; body recursion
%% so the wires and records come out in datagram order.
-spec build_levels([level()], #{level() => entry()}, binary(), binary()) ->
    {[binary()], [sent()]}.
build_levels([], _Entries, _DCID, _SCID) ->
    {[], []};
build_levels([Level | Rest], Entries, DCID, SCID) ->
    case Entries of
        #{Level := Entry} ->
            {Wire, Record} = build_packet(Level, Entry, DCID, SCID),
            {Wires, Records} = build_levels(Rest, Entries, DCID, SCID),
            {[Wire | Wires], [Record | Records]};
        #{} ->
            build_levels(Rest, Entries, DCID, SCID)
    end.

%% Encode + seal + header-protect one packet, returning the wire bytes and
%% its sent-record.
-spec build_packet(level(), entry(), binary(), binary()) -> {binary(), sent()}.
build_packet(Level, #{frames := Frames, keys := Keys, pn := PN} = Entry, DCID, SCID) ->
    #{key := Key, iv := IV, hp := HP} = Keys,
    Plaintext = pad_plaintext(iolist_to_binary([roadrunner_quic_frame:encode(F) || F <- Frames])),
    PNLen = roadrunner_quic_packet:pn_length(PN),
    Header = header(Level, DCID, SCID, PN, byte_size(Plaintext) + ?TAG_LEN, key_phase(Entry)),
    Sealed = roadrunner_quic_aead:seal(Key, IV, PN, Header, Plaintext),
    Protected = roadrunner_quic_aead:protect_header(HP, Header, Sealed, byte_size(Header) - PNLen),
    Wire = <<Protected/binary, Sealed/binary>>,
    Record = #{
        level => Level,
        pn => PN,
        length => byte_size(Wire),
        ack_eliciting => ack_eliciting(Frames),
        frames => Frames
    },
    {Wire, Record}.

%% The 1-RTT key phase (application level only); defaults to 0.
-spec key_phase(entry()) -> 0 | 1.
key_phase(#{key_phase := Phase}) -> Phase;
key_phase(#{}) -> 0.

%% The unprotected header through the packet number (the AEAD associated
%% data). A long header's Length must count the sealed payload, so it is
%% built with a placeholder of the sealed size; a short header has no
%% Length field and carries the key phase.
-spec header(level(), binary(), binary(), non_neg_integer(), non_neg_integer(), 0 | 1) ->
    binary().
header(application, DCID, _SCID, PN, _SealedSize, KeyPhase) ->
    [Header, _] = roadrunner_quic_packet:encode_short(DCID, PN, <<>>, false, KeyPhase),
    Header;
header(Level, DCID, SCID, PN, SealedSize, _KeyPhase) ->
    [Header, _] = roadrunner_quic_packet:encode_long(Level, ?QUIC_V1, DCID, SCID, #{
        pn => PN, payload => <<0:(SealedSize * 8)>>
    }),
    Header.

%% Pad a packet's plaintext to the header-protection-sample minimum with
%% PADDING frames (zero bytes) before it is sealed (RFC 9001 §5.4.2).
-spec pad_plaintext(binary()) -> binary().
pad_plaintext(Plaintext) when byte_size(Plaintext) >= ?MIN_SAMPLE_PLAINTEXT ->
    Plaintext;
pad_plaintext(Plaintext) ->
    <<Plaintext/binary, 0:((?MIN_SAMPLE_PLAINTEXT - byte_size(Plaintext)) * 8)>>.

%% Pad a datagram that carries an Initial packet to the RFC 9000 §14.1
%% minimum with trailing zero bytes. Coalescing an Initial with a 1-RTT
%% packet is a contract violation: the 1-RTT short header has no Length, so
%% the trailing pad would fold into its ciphertext and the peer could not
%% decrypt it. A server never has 1-RTT keys while still sending Initials,
%% so this never arises; reject it rather than emit a corrupt datagram.
-spec pad_datagram(binary(), #{level() => entry()}) -> binary().
pad_datagram(_Datagram, #{initial := _, application := _}) ->
    error(initial_with_application_coalesced);
pad_datagram(Datagram, #{initial := _}) when byte_size(Datagram) < ?MIN_INITIAL_DATAGRAM ->
    <<Datagram/binary, 0:((?MIN_INITIAL_DATAGRAM - byte_size(Datagram)) * 8)>>;
pad_datagram(Datagram, _Entries) ->
    Datagram.

%% A packet is ack-eliciting if it carries any frame other than PADDING,
%% ACK, or CONNECTION_CLOSE (RFC 9002 §2).
-spec ack_eliciting([roadrunner_quic_frame:frame()]) -> boolean().
ack_eliciting(Frames) ->
    lists:any(fun is_ack_eliciting/1, Frames).

-spec is_ack_eliciting(roadrunner_quic_frame:frame()) -> boolean().
is_ack_eliciting(padding) -> false;
is_ack_eliciting({ack, _, _, _, _, _}) -> false;
is_ack_eliciting({connection_close, _, _, _, _}) -> false;
is_ack_eliciting(_) -> true.
