-module(roadrunner_quic_recv).
-moduledoc false.

%% QUIC v1 receive pipeline (RFC 9001 §5, RFC 9000 §12.2/§A), pure.
%%
%% Turns one received UDP datagram into the decoded packets it carries: it
%% splits coalesced packets, classifies each header's encryption level,
%% selects that level's keys, removes header protection, reconstructs the
%% full packet number from the largest received in that space (RFC 9000
%% §A.3), AEAD-decrypts (the unprotected header is the associated data),
%% and decodes the frames. It composes the leaves (`roadrunner_quic_packet`,
%% `roadrunner_quic_aead`, `roadrunner_quic_frame`) and owns only the one
%% step none of them does: packet-number reconstruction.
%%
%% Pure and stateless: the per-level keys and per-space largest-received
%% packet number are inputs, never owned or mutated here. The connection
%% loop owns the PN spaces, records each decoded PN, and applies the
%% frames (ACK/stream/flow/CC, anti-amplification, events); this module's
%% job ends at decoded frames. The largest-received map is a per-datagram
%% snapshot, not re-threaded between coalesced packets of the same space
%% (safe because the minimal packet-number window, 256, exceeds any
%% coalesced run).
%%
%% Per packet it yields `{ok, Decoded}` (decrypted, frames decoded),
%% `{drop, Reason}` for an unsupported packet or one with no keys,
%% `{held, Packet}` for a 1-RTT packet when no 1-RTT keys are given (the
%% packet still protected, so the loop can keep it and decrypt it once the
%% handshake completes, RFC 9001 §5.7),
%% `{auth_failed, Level}` for a packet that fails authentication (both
%% silently dropped, never the whole datagram, RFC 9001 §5.4.2; the
%% failure is reported apart so the loop can count it toward the AEAD
%% integrity limit, §6.6), or `{frame_error, Level, Reason}` when an
%% authenticated packet holds a malformed frame, carries no frames (RFC
%% 9000 §12.4), or sets the header reserved bits (§17.2/§17.3.1); those
%% last two have `Reason = protocol_violation`. Each is a connection error
%% the loop must act on, kept distinct from a drop. A decrypt failure drops
%% only that packet and the loop continues with the rest of the datagram.
%%
%% 1-RTT keys change with key updates (RFC 9001 §6), so the application
%% keys may carry more than one generation: the current keys with their key
%% phase, the next generation the peer moves to when it updates (always
%% ready, so a flipped Key Phase bit costs the same as any packet and
%% reveals nothing through timing, §6.3/§9.5), and, for a while after an
%% update, the previous generation for packets reordered from before it
%% (§6.5). A packet whose Key Phase bit is the current one opens with the
%% current keys; otherwise one numbered below every packet of the current
%% phase opens with the previous keys, and any other with the next keys.
%% The decoded packet names the generation that opened it; deciding whether
%% a packet that opened with the next keys completes a key update is the
%% loop's job. The header-protection key is the same for every generation
%% (§6.1), so it is removed before the generation is chosen.

-export([datagram/4]).
%% Exported for direct unit coverage of the RFC 9000 §A.3 windows; the
%% `+/-window` branches aren't reachable through the minimal-width encode
%% path used by the round-trip tests.
-export([reconstruct_pn/3]).

-export_type([level/0, keys/0, generation/0, decoded/0, outcome/0]).

%% The three QUIC packet-number spaces (RFC 9000 §12.3); a 1-RTT
%% short-header packet belongs to the application space.
-type level() :: initial | handshake | application.

%% A level's receive keys. The application keys may also carry the key
%% update generations (see the module comment): `phase` is the Key Phase
%% bit of the current keys and `next` the generation after them; `prev` is
%% the previous generation, kept for packets numbered below `prev_below`
%% (the lowest packet number seen in the current phase). Without `phase`
%% the keys open every packet, whatever its Key Phase bit.
-type keys() :: #{
    key := roadrunner_quic_aead:aead_key(),
    iv := binary(),
    hp := roadrunner_quic_aead:hp(),
    phase => 0 | 1,
    next => roadrunner_quic_keys:packet_keys(),
    prev => roadrunner_quic_keys:packet_keys(),
    prev_below => non_neg_integer()
}.

%% The 1-RTT key generation that opened a packet (RFC 9001 §6).
-type generation() :: previous | current | next.

-type decoded() :: #{
    level := level(),
    pn := non_neg_integer(),
    frames := [roadrunner_quic_frame:frame()],
    %% Present only for application packets: the 1-RTT Key Phase bit and
    %% the key generation that opened the packet.
    key_phase => 0 | 1,
    generation => generation()
}.

-type outcome() ::
    {ok, decoded()}
    | {drop, atom()}
    | {held, binary()}
    | {auth_failed, level()}
    | {frame_error, level(), term()}.

-doc """
Decode every packet in a received datagram. `Keys` maps each available
encryption level to its packet-protection keys, `Largest` maps each space
to its largest received packet number (a level absent from `Largest` is
treated as a fresh space). `DCIDLen` is the server's fixed connection-ID
length, used to locate the packet number of short-header packets. Returns
one outcome per packet, in datagram order.
""".
-spec datagram(binary(), non_neg_integer(), #{level() => keys()}, #{level() => non_neg_integer()}) ->
    [outcome()].
datagram(Datagram, DCIDLen, Keys, Largest) ->
    case roadrunner_quic_packet:coalesced_split(Datagram) of
        {ok, Packet, Rest} ->
            [packet(Packet, DCIDLen, Keys, Largest) | datagram(Rest, DCIDLen, Keys, Largest)];
        %% End of datagram, trailing padding, or a header whose boundary
        %% can't be parsed: stop. Packets already decoded are returned.
        done ->
            [];
        {error, _Reason} ->
            []
    end.

%% =============================================================================
%% Internal
%% =============================================================================

-spec packet(binary(), non_neg_integer(), #{level() => keys()}, #{level() => non_neg_integer()}) ->
    outcome().
packet(Packet, DCIDLen, Keys, Largest) ->
    maybe
        {ok, Level} ?= classify(Packet),
        {ok, #{hp := HP} = LevelKeys} ?= level_keys(Level, Packet, Keys),
        {ok, PNOffset} ?= roadrunner_quic_packet:pn_offset(Packet, DCIDLen),
        {ok, Header, PNLen, TruncPN, Ciphertext} ?=
            roadrunner_quic_aead:unprotect_header(HP, Packet, PNOffset),
        PN = reconstruct_pn(level_largest(Level, Largest), PNLen, TruncPN),
        {Generation, #{key := Key, iv := IV}} = generation_keys(Header, PN, LevelKeys),
        {ok, Plaintext} ?= open(Level, Key, IV, PN, Header, Ciphertext),
        %% RFC 9000 §17.2 / §17.3.1: the header's reserved bits MUST be 0.
        %% Checked only after the packet authenticates (open/6 above) so a
        %% forged packet cannot spuriously close the connection; a non-zero
        %% value is a PROTOCOL_VIOLATION the loop acts on, not a silent drop.
        case reserved_bits_zero(Level, Header) of
            true -> decode_frames(Level, Generation, PN, Header, Plaintext);
            false -> {frame_error, Level, protocol_violation}
        end
    else
        {drop, _} = Drop -> Drop;
        {held, _} = Held -> Held;
        {auth_failed, _} = Failed -> Failed;
        {error, Reason} -> {drop, Reason}
    end.

%% Encryption level from the (header-protection-independent) first byte:
%% long-header type bits select Initial/Handshake; a short header is
%% 1-RTT (application). 0-RTT and Retry are unsupported for a server-only
%% v1 endpoint.
-spec classify(binary()) -> {ok, level()} | {drop, unsupported_packet}.
classify(<<1:1, 1:1, 0:2, _:4, _/binary>>) -> {ok, initial};
classify(<<1:1, 1:1, 2:2, _:4, _/binary>>) -> {ok, handshake};
classify(<<0:1, 1:1, _:6, _/binary>>) -> {ok, application};
classify(_) -> {drop, unsupported_packet}.

%% A level's keys. A 1-RTT packet with none is handed back still protected
%% rather than dropped: the loop withholds the 1-RTT keys until the
%% handshake completes (RFC 9001 §5.7) and keeps such a packet until then.
-spec level_keys(level(), binary(), #{level() => keys()}) ->
    {ok, keys()} | {held, binary()} | {drop, no_keys}.
level_keys(Level, Packet, Keys) ->
    case {Level, Keys} of
        {_, #{Level := LevelKeys}} -> {ok, LevelKeys};
        {application, #{}} -> {held, Packet};
        {_, #{}} -> {drop, no_keys}
    end.

-spec level_largest(level(), #{level() => non_neg_integer()}) -> non_neg_integer() | undefined.
level_largest(Level, Largest) ->
    case Largest of
        #{Level := N} -> N;
        #{} -> undefined
    end.

%% Reconstruct the full packet number from the truncated wire value and
%% the largest received in this space (RFC 9000 §A.3). A fresh space
%% (`undefined`) uses the truncated value directly.
-doc false.
-spec reconstruct_pn(non_neg_integer() | undefined, 1..4, non_neg_integer()) -> non_neg_integer().
reconstruct_pn(undefined, _PNLen, TruncPN) ->
    TruncPN;
reconstruct_pn(Largest, PNLen, TruncPN) ->
    Win = 1 bsl (PNLen * 8),
    HalfWin = Win bsr 1,
    Expected = Largest + 1,
    Candidate = (Expected band bnot (Win - 1)) bor TruncPN,
    if
        Candidate =< Expected - HalfWin andalso Candidate < (1 bsl 62) - Win -> Candidate + Win;
        Candidate > Expected + HalfWin andalso Candidate >= Win -> Candidate - Win;
        true -> Candidate
    end.

%% The key generation to open a packet with (RFC 9001 §6.5): the current
%% keys when the unprotected Key Phase bit matches theirs; otherwise the
%% previous keys for a packet numbered below every packet of the current
%% phase, and the next keys for any other. Only 1-RTT keys carry a phase,
%% and keys without one open every packet. Each choice opens the packet
%% exactly once, so the time it takes does not tell which keys were tried.
-spec generation_keys(binary(), non_neg_integer(), keys()) ->
    {generation(), roadrunner_quic_keys:packet_keys() | keys()}.
generation_keys(<<FirstByte, _/binary>>, PN, #{phase := Phase, next := Next} = Keys) ->
    case roadrunner_quic_packet:key_phase(FirstByte) of
        Phase ->
            {current, Keys};
        _Flipped ->
            case Keys of
                #{prev := Prev, prev_below := Below} when PN < Below -> {previous, Prev};
                #{} -> {next, Next}
            end
    end;
generation_keys(_Header, _PN, Keys) ->
    {current, Keys}.

%% Normalise the AEAD open result (a bare `error`) to the tagged
%% authentication failure the packet/4 maybe expects.
-spec open(
    level(), roadrunner_quic_aead:aead_key(), binary(), non_neg_integer(), binary(), binary()
) ->
    {ok, binary()} | {auth_failed, level()}.
open(Level, Key, IV, PN, AAD, Sealed) ->
    case roadrunner_quic_aead:open(Key, IV, PN, AAD, Sealed) of
        {ok, _} = Ok -> Ok;
        error -> {auth_failed, Level}
    end.

-spec decode_frames(level(), generation(), non_neg_integer(), binary(), binary()) ->
    {ok, decoded()} | {frame_error, level(), term()}.
decode_frames(Level, Generation, PN, Header, Plaintext) ->
    case roadrunner_quic_frame:decode_all(Plaintext) of
        %% RFC 9000 §12.4: a packet with no frames is a PROTOCOL_VIOLATION.
        {ok, []} -> {frame_error, Level, protocol_violation};
        {ok, Frames} -> {ok, decoded(Level, Generation, PN, Header, Frames)};
        {error, Reason} -> {frame_error, Level, Reason}
    end.

-spec decoded(level(), generation(), non_neg_integer(), binary(), [roadrunner_quic_frame:frame()]) ->
    decoded().
decoded(application, Generation, PN, <<FirstByte, _/binary>>, Frames) ->
    #{
        level => application,
        pn => PN,
        frames => Frames,
        key_phase => roadrunner_quic_packet:key_phase(FirstByte),
        generation => Generation
    };
decoded(Level, _Generation, PN, _Header, Frames) ->
    #{level => Level, pn => PN, frames => Frames}.

%% RFC 9000 §17.2 (long header) / §17.3.1 (short header): the reserved
%% bits of the unprotected first byte are 0 in a conformant packet.
-spec reserved_bits_zero(level(), binary()) -> boolean().
reserved_bits_zero(Level, <<FirstByte, _/binary>>) ->
    FirstByte band reserved_mask(Level) =:= 0.

%% Reserved-bit mask: 0x18 in a 1-RTT short header, 0x0c in a long header
%% (the two bits between the type / key-phase fields and the
%% packet-number length).
-spec reserved_mask(level()) -> non_neg_integer().
reserved_mask(application) -> 16#18;
reserved_mask(_Long) -> 16#0c.
