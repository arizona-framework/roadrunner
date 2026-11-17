%% The QUIC per-packet records, shared by the modules that build one and
%% the modules that read one on every packet: the connection state builds
%% each send entry and reads each sent and decoded packet, the send and
%% receive pipelines read the keys, and the connection state reads the loss
%% detector's congestion signal on every ACK. Matching them by field keeps
%% those reads off a function call per field. Private: not part of the
%% roadrunner API.

%% One direction's packet-protection keys at one encryption level (RFC 9001
%% §5), owned by `roadrunner_quic_keys`. The keys of a 1-RTT key update
%% generation (§6.1) carry no header-protection key (`hp` is `undefined`):
%% a key update keeps the one the connection has.
-record(quic_keys, {
    key :: roadrunner_quic_aead:aead_key(),
    iv :: binary(),
    hp = undefined :: roadrunner_quic_aead:hp() | undefined
}).

%% The 1-RTT receive keys, owned by `roadrunner_quic_recv`: the current
%% generation's keys and Key Phase bit, the next generation the peer moves
%% to when it updates (RFC 9001 §6.3), and, for a while after an update,
%% the previous generation, kept for packets numbered below `prev_below`
%% (the lowest packet number seen in the current phase, §6.5).
-record(quic_phased_keys, {
    key :: roadrunner_quic_aead:aead_key(),
    iv :: binary(),
    hp :: roadrunner_quic_aead:hp(),
    phase :: 0 | 1,
    next :: #quic_keys{},
    prev = undefined :: #quic_keys{} | undefined,
    prev_below = undefined :: non_neg_integer() | undefined
}).

%% One packet to send, owned by `roadrunner_quic_send`: its frames, keys
%% and packet number, the 1-RTT Key Phase bit (application level only), and
%% the size to expand a 1-RTT packet to with PADDING frames (application
%% level only; a packet already as large stays as it is).
-record(quic_entry, {
    frames :: [roadrunner_quic_frame:frame()],
    keys :: #quic_keys{},
    pn :: non_neg_integer(),
    key_phase = 0 :: 0 | 1,
    pad_to = 0 :: non_neg_integer()
}).

%% One packet sent, owned by `roadrunner_quic_send`, for loss, ACK and
%% congestion-control tracking: its level, packet number, bare wire size,
%% whether it is ack-eliciting, and its frames, to retransmit if it is
%% declared lost.
-record(quic_sent, {
    level :: roadrunner_quic_send:level(),
    pn :: non_neg_integer(),
    length :: non_neg_integer(),
    ack_eliciting :: boolean(),
    frames :: [roadrunner_quic_frame:frame()]
}).

%% One packet received and opened, owned by `roadrunner_quic_recv`. Only an
%% application packet carries its 1-RTT Key Phase bit and the key generation
%% that opened it; the others leave both `undefined`.
-record(quic_decoded, {
    level :: roadrunner_quic_recv:level(),
    pn :: non_neg_integer(),
    frames :: [roadrunner_quic_frame:frame()],
    key_phase = undefined :: 0 | 1 | undefined,
    generation = undefined :: roadrunner_quic_recv:generation() | undefined
}).

%% The congestion-control signal of the loss detector's most recent ACK or
%% loss pass, owned by `roadrunner_quic_loss`: the acknowledged bytes, the
%% send times of the largest acknowledged and the latest lost ack-eliciting
%% packets, and whether the loss shows persistent congestion (RFC 9002 §7).
-record(quic_cc_signal, {
    acked_bytes = 0 :: non_neg_integer(),
    largest_acked_time = undefined :: non_neg_integer() | undefined,
    largest_lost_time = undefined :: non_neg_integer() | undefined,
    persistent_congestion = false :: boolean()
}).
