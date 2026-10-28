-module(roadrunner_quic_conn_state).
-moduledoc false.

%% The pure decision core of the native QUIC connection (RFC 9000/9001).
%%
%% `roadrunner_quic_connection` is the thin proc_lib shell that owns the
%% socket, timers, and message loop; this module owns the whole `#state{}`
%% and every decision. Each entry takes the wall-clock `Now` (ms) and a
%% message and returns `{NewState, [effect()]}` for the shell to perform.
%% Keeping the brain pure (recv/send/crypto all run here, since the leaves
%% are pure) is what makes the connection eunit-reachable for the 100%
%% gate; the shell only does the irreducible I/O.
%%
%% Effects: `{send, Datagram}` (hand to the socket), `{arm_timer, Kind,
%% AtMs}` ((re)arm a timer), `{emit, Owner, Event}` (async owner
%% notification, e.g. `{connected, Info}`), `{reply, To, Ref, Result}`
%% (answer a synchronous control call), `{register_cid, CID}` /
%% `{unregister_cid, CID}` (route a connection id to this connection in the
%% listener's registry, or stop routing it), `{register_reset, Token}` /
%% `{unregister_reset, Token}` (the same for a client stateless reset
%% token), `{send_to, Peer, Datagram}` (a
%% probing packet for an address other than the peer's), and `{migrate,
%% Peer}` (the peer moved: every later `{send, _}` goes to `Peer`; it always
%% leads the effects that follow it).
%%
%% A connection keeps up to three packet-number spaces (Initial, Handshake,
%% Application). The server reads with the peer's keys and writes with its
%% own; CRYPTO is reassembled per space (a `roadrunner_quic_stream` with no
%% FIN). Initial state is discarded once a Handshake packet decrypts and
%% Handshake state once the handshake is confirmed (RFC 9001 §4.9), which
%% also keeps the send pass from ever coalescing an Initial with a 1-RTT
%% packet. The send pass collects, per space in order, an ACK frame, the
%% TLS flight / retransmits, and (at the Application level) HANDSHAKE_DONE
%% plus outbound STREAM data sliced within the send-flow windows, packs them
%% with `roadrunner_quic_send`, gates the datagram against the §8.1
%% anti-amplification budget, and records each sent packet for loss
%% recovery.
%%
%% The peer may update the 1-RTT keys (RFC 9001 §6). A packet that opens
%% with the next generation's keys commits the update only once it has
%% authenticated, so a forged packet with a flipped Key Phase bit changes
%% nothing; the commit moves both directions to the next generation and
%% flips the Key Phase bit our packets carry, and the previous receive keys
%% stay for three PTOs for reordered packets. The server starts a key update
%% of its own well before its send keys reach the AEAD confidentiality limit
%% (§6.6): only its send keys move then, and the receive keys follow when
%% the peer's response arrives in the new phase. If the limit comes with no
%% update allowed, the connection closes with AEAD_LIMIT_REACHED rather than
%% overuse the keys.
%%
%% The client's 1-RTT keys arrive with the server's first flight, but a
%% server MUST NOT process 1-RTT packets before the handshake completes
%% (RFC 9001 §5.7). Until the client Finished verifies, each 1-RTT packet is
%% held unopened (a few at most) and opened once it does, including one
%% coalesced behind that Finished in the same datagram.
%%
%% Each endpoint addresses its peer with connection ids the peer chose (RFC
%% 9000 §5.1). Once the handshake is confirmed the server issues spare ids
%% with NEW_CONNECTION_ID, as many as the client accepts (its
%% active_connection_id_limit, capped here), each with a stateless reset
%% token derived from it under the listener's reset key (§10.3.2); every
%% issued id routes to this connection until the client retires it, and a
%% retired one is replaced so the client keeps a spare (§5.1.2). The
%% client's own spare ids are kept by sequence number, and the ones its
%% Retire Prior To asks for are retired; the server keeps addressing the id
%% it uses unless that one is retired.
%%
%% The client's spare ids each come with a stateless reset token (RFC 9000
%% §10.3), which the listener routes here, since a reset from a client that
%% has lost its state routes by no connection id. A datagram whose first
%% packet does not decrypt (or that holds none) is compared with the tokens
%% of the client ids in use toward the address it came from (§10.3.1 MUST),
%% in constant time; one ending in such a token moves the connection to the
%% draining period, sending nothing more.
%%
%% The client may move to a new address (RFC 9000 §9). Once the handshake is
%% confirmed, the highest-numbered non-probing packet from a new address moves
%% the connection there: later packets go to it, addressed with a client id
%% never used toward another address (§9.5), limited to three times what the
%% address sent until a PATH_CHALLENGE answered from it validates it (§8.2,
%% §9.3.1), and the path left behind is challenged too (§9.3.3). Validation
%% that times out returns the connection to the last validated path
%% (§9.3.2). Each move, back included, tells the owner the address the
%% connection now uses with `{peer_changed, Peer}`. On validation the
%% congestion controller and RTT estimate start over for the new path,
%% unless only the port changed, the usual sign of a NAT rebinding (§9.4). A 1-RTT packet held across the handshake never moves
%% it: only one from the handshake's address is held, and it is processed as
%% received there. A probing packet from another address moves nothing:
%% its PATH_CHALLENGE is answered there (§8.2.2, §9.1). Every packet carrying
%% PATH_CHALLENGE or PATH_RESPONSE fills a 1200-byte datagram where the
%% anti-amplification limit allows (§8.2.1, §8.2.2).
%%
%% Once it has validated the client's address, at the handshake's
%% confirmation and again when a migrated client's new IP address is
%% validated (RFC 9000 §9.3 SHOULD), the server sends the client a NEW_TOKEN
%% (§8.1.3) sealed for that IP, so the client's next connection counts as
%% validated from its first packet. A connection the listener started with
%% such a token (`address_validated`) begins with the anti-amplification
%% limit lifted.
%%
%% Congestion control and probe transmission are deferred: the connection
%% sends within the anti-amplification and flow limits (the MUSTs) and a
%% probe timeout only re-checks for losses and backs off. Wiring NewReno and
%% sending an explicit probe both need the loss layer to surface acked bytes
%% / sent times / the oldest unacknowledged frames, a separate follow-up.

-export([
    new/2,
    handle_datagram/4,
    handle_timeout/3,
    handle_call/5,
    handle_send/7,
    handle_send_final/4,
    handle_consumed/4,
    peername/1,
    phase/1,
    routes/1,
    reset_routes/1
]).
%% Exported for direct eunit branch coverage of the idle-timeout negotiation.
-export([negotiated_idle_timeout/2]).
%% Exported for direct eunit branch coverage of retransmit packing: a CRYPTO
%% split and an unsplittable frame need a lost multi-packet handshake flight
%% to reach through a connection.
-export([fit_frames/2]).
%% Exported so tests can observe the congestion window's growth and backoff.
-export([cwnd/1]).
%% Exported for direct eunit branch coverage of the AEAD integrity limit
%% (RFC 9001 §6.6): no test can forge the 2^52 packets that reach it.
-export([auth_failed/3]).
%% Exported for direct eunit branch coverage of the AEAD confidentiality limit
%% (RFC 9001 §6.6): no test can seal the 2^22 packets that start a key update
%% of our own, nor the 2^23 that close the connection.
-export([key_limit/3]).

-export_type([t/0, config/0, effect/0, event/0, info/0]).

%% RFC 9000 §17.2: the server uses a fixed-length SCID so short headers demux.
-define(SCID_LEN, 8).
%% RFC 9000 §18.2: the active_connection_id_limit when a side does not send
%% one (and the smallest value it may send).
-define(DEFAULT_ACTIVE_CID_LIMIT, 2).
%% The most connection ids the server keeps active per connection, however
%% many the client accepts (RFC 9000 §5.1.1 lets an endpoint limit them):
%% enough for the client to migrate and probe a path more, while every one is
%% a routing row in the listener's registry.
-define(ACTIVE_CID_LIMIT, 4).
%% RFC 9000 §8.2.1 / §8.2.2: a datagram carrying PATH_CHALLENGE or
%% PATH_RESPONSE is expanded to the smallest allowed maximum datagram size.
-define(MIN_PATH_DATAGRAM, 1200).
%% The PATH_CHALLENGEs a validation sends before it gives up (RFC 9000
%% §8.2.4): one at its start and one each interval, abandoned after three.
-define(VALIDATION_CHALLENGES, 3).
%% Challenges kept for a client stranded at the address a failed validation
%% left (`rechallenge_stranded/1`).
-define(STRANDED_CHALLENGES, 2).
%% The largest datagram of a bare PATH_CHALLENGE: a short header with a
%% 20-byte connection id and a 4-byte packet number, the 9-byte frame and
%% the AEAD tag.
-define(BARE_CHALLENGE, 50).
%% A CRYPTO slice budget that leaves room for the packet header, an ACK
%% frame, and the AEAD tag within the 1200-byte datagram (RFC 9000 §14).
-define(CRYPTO_BUDGET, 1000).
%% CRYPTO bytes held per level ahead of what TLS has consumed. RFC 9000 §7.5
%% asks for at least 4096; a client's handshake messages (its ClientHello
%% and Finished) fit far inside this.
-define(CRYPTO_BUFFER_LIMIT, 65536).
%% How long a 1-RTT ACK may wait for a packet to ride in (RFC 9000 §13.2.1),
%% in milliseconds: inside the 25 ms max_ack_delay a peer assumes when, as
%% here, none is advertised (§18.2), with room for timer lateness.
-define(ACK_DELAY, 20).
%% The ACK Delay field's scale: microseconds shifted right by the default
%% ack_delay_exponent of 3, since none is advertised (RFC 9000 §18.2).
-define(ACK_DELAY_EXPONENT, 3).
%% Idle-timeout fallback (RFC 9000 §10.1): used only when neither endpoint
%% advertises a max_idle_timeout, so a dead peer cannot pin the connection. The
%% live value is the negotiated minimum of the two advertised limits.
-define(IDLE_TIMEOUT, 30000).
%% The AEAD integrity limits (RFC 9001 §6.6): received packets that may fail
%% authentication within a connection before it MUST close, for
%% AEAD_AES_128_GCM and AEAD_AES_256_GCM (which share theirs) and
%% AEAD_CHACHA20_POLY1305.
-define(AES_GCM_INTEGRITY_LIMIT, (1 bsl 52)).
-define(CHACHA20_POLY1305_INTEGRITY_LIMIT, (1 bsl 36)).
%% The AEAD confidentiality limits (RFC 9001 §6.6): packets one key may
%% protect, again shared by AEAD_AES_128_GCM and AEAD_AES_256_GCM.
%% AEAD_CHACHA20_POLY1305's is above the 2^62 packet numbers there
%% are, so no connection reaches it and it is kept as that bound.
-define(AES_GCM_CONFIDENTIALITY_LIMIT, (1 bsl 23)).
-define(CHACHA20_POLY1305_CONFIDENTIALITY_LIMIT, (1 bsl 62)).

%% 1-RTT packets kept, still protected, while the handshake is in progress
%% (RFC 9001 §5.7). A client sends only a few before it sees our
%% HANDSHAKE_DONE; past this the rest are dropped and it retransmits them.
-define(HELD_LIMIT, 8).
%% TLS handshake message types carried in CRYPTO (RFC 8446 §4).
-define(CLIENT_HELLO, 1).
-define(FINISHED, 20).

-type level() :: initial | handshake | application.
-type phase() :: handshaking | connected | draining | closed.
-type address() :: {inet:ip_address(), inet:port_number()}.
%% A path a probing packet goes out on: the current one, one the client
%% probes from, or a validated address (the last validated path while the
%% current one is validated) with the client id used toward it.
-type path() :: current | probe | {validated, address(), binary()}.

%% The validation of the current path (RFC 9000 §8.2): each PATH_CHALLENGE
%% sent and whether its datagram reached 1200 bytes, the stage (the address
%% until a response proves it, then the path MTU until a response to an
%% expanded challenge does, §8.2.1), when to challenge again, and when to
%% give up (§8.2.4).
-record(validation, {
    sent = [] :: [{binary(), boolean()}],
    stage = address :: address | mtu,
    next_at :: integer(),
    abandon_at :: integer(),
    interval :: pos_integer()
}).

-record(space, {
    ack :: roadrunner_quic_ack:t(),
    loss :: roadrunner_quic_loss:t(),
    next_pn = 0 :: non_neg_integer(),
    %% CRYPTO reassembly + send buffering for this space (FIN unused).
    crypto :: roadrunner_quic_stream:t(),
    %% Contiguous CRYPTO bytes received but not yet deframed.
    crypto_in = <<>> :: binary(),
    %% Frames to (re)send: losses to retransmit, plus queued control frames.
    pending = [] :: [roadrunner_quic_frame:frame()]
}).

-record(state, {
    %% The client's Initial Destination Connection ID: derives the Initial keys
    %% and echoes as original_destination_connection_id. NOT the reply wire DCID.
    dcid :: binary(),
    scid :: binary(),
    %% The client's connection id every server packet addresses as its
    %% Destination Connection ID: its Source Connection ID from the handshake
    %% (RFC 9000 §7.2/§17.2), until the client retires that one and another of
    %% its ids takes over (§5.1.2).
    peer_scid :: binary(),
    %% The connection ids we issued that the client has not retired (RFC 9000
    %% §5.1.1), by sequence number; `scid` is sequence number 0. Each routes
    %% to this connection in the listener's registry.
    cids :: #{non_neg_integer() => binary()},
    %% The sequence number the next issued connection id takes (§5.1.1: each
    %% one increases by 1).
    next_cid_seq = 1 :: pos_integer(),
    %% The key the stateless reset token of each issued id derives from
    %% (`roadrunner_quic_cid_registry:reset_token/2`, RFC 9000 §10.3.2).
    reset_key :: binary(),
    %% The key the address validation tokens we send with NEW_TOKEN are
    %% sealed under (`roadrunner_quic_token`, RFC 9000 §8.1.3).
    token_key :: <<_:256>>,
    %% The client's connection ids we may address (RFC 9000 §5.1.2), by
    %% sequence number: its handshake Source Connection ID is 0, the rest came
    %% in NEW_CONNECTION_ID frames. `peer_cid_seq` is the one `peer_scid`
    %% holds, and `peer_retire_prior` the largest Retire Prior To received.
    peer_cids :: #{non_neg_integer() => binary()},
    %% The stateless reset tokens of the client's ids in `peer_cids` that
    %% came with one (all but the handshake's, RFC 9000 §10.3), by sequence
    %% number.
    peer_reset_tokens = #{} :: #{non_neg_integer() => <<_:128>>},
    peer_cid_seq = 0 :: non_neg_integer(),
    peer_retire_prior = 0 :: non_neg_integer(),
    %% Client ids we retired on our own (RFC 9000 §5.1.2), numbered at or
    %% above `peer_retire_prior`: a repeated NEW_CONNECTION_ID for one of them
    %% must not bring it back.
    peer_cids_retired = [] :: [non_neg_integer()],
    %% The Destination Connection ID, source address and size of the datagram
    %% being processed: a RETIRE_CONNECTION_ID must not retire that id (RFC
    %% 9000 §19.16), and the address is the path the datagram arrived on.
    rx_dcid = <<>> :: binary(),
    rx_peer :: address(),
    rx_size = 0 :: non_neg_integer(),
    %% The address non-probing packets go to: the client's handshake address
    %% until it migrates (RFC 9000 §9.3).
    peer :: address(),
    %% Our connection id the client addressed when the current path began: a
    %% datagram from a new address still sent to it may be a NAT rebinding
    %% rather than a move of the client's own (RFC 9000 §9.5).
    path_dcid :: binary(),
    %% While the current path is validated: the last validated one to return
    %% to should validation fail (RFC 9000 §9.3.2), with the client id used
    %% on it and its `path_dcid`.
    prev_path = undefined :: undefined | {address(), non_neg_integer(), binary()},
    %% An address the client probes from without having moved to it (RFC
    %% 9000 §9.1): the client id our answers there carry (§9.5) and its
    %% anti-amplification account (§8.1).
    probe_path = undefined ::
        undefined | {address(), non_neg_integer(), roadrunner_quic_amp:t()},
    %% The address a failed validation left (`keep_as_probe/1`), where the
    %% client may still be, waiting on packets that now go elsewhere.
    stranded = undefined :: undefined | address(),
    %% The validation of the current path in progress, or `undefined` once
    %% the path is validated.
    validation = undefined :: undefined | #validation{},
    %% Probing packets the next send pass sends ahead of everything else,
    %% newest-first: frames for a path, or `challenge`, a fresh PATH_CHALLENGE
    %% validating the current path.
    path_out = [] :: [challenge | {path(), [roadrunner_quic_frame:frame()]}],
    phase = handshaking :: phase(),
    tls :: roadrunner_quic_tls_server:t(),
    %% Keys to decrypt incoming packets (the peer's), by level. The 1-RTT
    %% keys also carry the key-update generations `roadrunner_quic_recv`
    %% chooses between (RFC 9001 §6).
    recv_keys :: #{level() => roadrunner_quic_recv:keys()},
    %% Keys to protect outgoing packets (the server's), by level.
    send_keys :: #{level() => roadrunner_quic_keys:keys()},
    %% The 1-RTT Key Phase bit our packets carry (RFC 9001 §6): that of the
    %% current send keys. Any key update flips it. The receive keys hold the
    %% peer's phase (`phase` in `recv_keys`); the two differ only while a key
    %% update of ours waits for the peer's response.
    key_phase = 0 :: 0 | 1,
    %% The 1-RTT secrets each key update advances with "quic ku" (§6.1): the
    %% client's for the next receive generation (the `next` keys in
    %% `recv_keys`), and the server's for the current send generation.
    recv_secret = <<>> :: binary(),
    send_secret = <<>> :: binary(),
    %% The packet-protection AEAD of the negotiated cipher suite (§5.3), set
    %% with the 1-RTT keys: every key update derives keys for it, as an update
    %% never changes the suite (§6.1), and its integrity limit applies
    %% (§6.6). Until then only the Initial packets' AES-128-GCM is in use
    %% (§5.2).
    aead = aes_128_gcm :: roadrunner_quic_aead:cipher(),
    %% Whether a 1-RTT ACK has gone out since the last key update. The peer
    %% may update again only once it has an acknowledgment of a packet it
    %% sent in the current phase (§6.1), and only our ACKs sent after the
    %% update can carry one.
    update_acked = true :: boolean(),
    %% When the previous 1-RTT receive generation is discarded (§6.5), or
    %% `undefined` with none kept.
    prev_keys_until = undefined :: integer() | undefined,
    %% 1-RTT packets protected with the current send keys, for the AEAD
    %% confidentiality limit (§6.6).
    sealed = 0 :: non_neg_integer(),
    %% The first 1-RTT packet number sent with the current send keys: an ACK
    %% of it or a later packet shows the peer has them (§6.1).
    send_phase_pn = 0 :: non_neg_integer(),
    %% When we may start a key update of our own: three PTOs after the first
    %% ACK of a packet sent with the current keys (§6.1, §6.5), `undefined`
    %% until that ACK arrives.
    own_update_at = undefined :: integer() | undefined,
    %% Received packets that failed authentication, across all keys and
    %% levels, for the AEAD integrity limit (§6.6).
    auth_failures = 0 :: non_neg_integer(),
    %% 1-RTT packets received before the client Finished verified, newest
    %% first and still protected (RFC 9001 §5.7): a server MUST NOT process
    %% them before the handshake completes, so they are neither decrypted
    %% nor acknowledged until then. At most ?HELD_LIMIT.
    held = [] :: [binary()],
    spaces :: #{level() => #space{}},
    amp :: roadrunner_quic_amp:t(),
    %% Cleared once a Handshake packet decrypts (address validated, §8.1).
    validated = false :: boolean(),
    %% The application owner: the async sink for `{emit, _, _}` events,
    %% installed by the listener (via set_owner) during handshaking.
    owner :: pid() | undefined,
    %% The `connected` payload, built once at new/1.
    info :: info(),
    %% Application streams, each with its own reassembly + flow window, keyed
    %% by stream id (peer-initiated on receive; server-initiated and client
    %% request streams on send).
    streams = #{} :: #{non_neg_integer() => stream()},
    %% The subset of `streams` ids with unsent data or an unsent FIN, kept
    %% ascending (RFC 9000 stream priority: lowest id first). The send pass
    %% walks only these instead of re-sorting and scanning every stream, so
    %% per-pass work is O(streams-with-pending-data); a fully-terminal stream
    %% leaves both this set and `streams` (pruned in `put_stream`).
    sendable = [] :: ordsets:ordset(non_neg_integer()),
    %% Deferred send replies, one per stream id: a synchronous `send_data`
    %% whose bytes did not fully flush this pass (closed flow / congestion
    %% window) is parked here instead of replied, so the stream worker (and
    %% the loop handler's Push) blocks until the buffer drains — the HTTP/3
    %% analogue of h2's defer-ack backpressure. At most one entry per stream:
    %% the worker blocks in `roadrunner_quic:await/3`, so it cannot have a
    %% second `send_data` outstanding. Released by `release_drained/1` (drain
    %% or abort) and `release_all/2` (connection teardown).
    parked = #{} :: #{non_neg_integer() => {pid(), reference()}},
    %% The owner's graceful close (`{close_when_done, Code, Reason}`): the
    %% application CONNECTION_CLOSE to send once every response is out, that
    %% is once no stream holds unsent bytes and no client request stream
    %% still waits on its response (`responses_done/1`). Checked at the end
    %% of each send pass while set; `undefined` otherwise.
    close_when_done = undefined :: {non_neg_integer(), binary()} | undefined,
    %% Next server-initiated unidirectional stream id to hand out (RFC 9000
    %% §2.1: server uni ids are 3, 7, 11, ...); the owner opens its h3
    %% control stream this way.
    next_uni = 3 :: non_neg_integer(),
    %% The peer's limit on the unidirectional streams the server may open
    %% (RFC 9000 §4.6), the counterpart of `max_streams_uni` below: seeded
    %% from the client's initial_max_streams_uni (absent -> 0, §18.2) and
    %% raised by a MAX_STREAMS (uni) frame (§19.11). `open_uni` refuses an id
    %% whose ordinal (id div 4) reaches it. No bidirectional counterpart is
    %% kept: HTTP/3 uses no server-initiated bidirectional streams (RFC 9114
    %% §6.1), so this server never opens one and a MAX_STREAMS (bidi) has
    %% nothing to unblock.
    peer_max_streams_uni = 0 :: non_neg_integer(),
    %% The stream counts we advertised the peer may open
    %% (initial_max_streams_bidi/uni, RFC 9000 §4.6): a client-initiated stream
    %% whose ordinal (id div 4) is >= the limit for its type is a
    %% STREAM_LIMIT_ERROR.
    max_streams_bidi :: non_neg_integer(),
    max_streams_uni :: non_neg_integer(),
    %% Per-type count of peer-initiated stream ordinals opened so far (1 + the
    %% highest ordinal seen). A peer frame for an ordinal below this that is no
    %% longer in `streams`, and not in `skipped`, is a late/reordered frame for
    %% a pruned stream (RFC 9000 §3): it is ignored, not recreated as a fresh
    %% stream.
    bidi_opened = 0 :: non_neg_integer(),
    uni_opened = 0 :: non_neg_integer(),
    %% Peer stream ids below the high-water that no frame has opened yet:
    %% opening a stream opens every lower one of its type (RFC 9000 §3.2), so
    %% a stream whose first frame arrives after a higher one's is still new.
    %% Bounded by the stream limit, which is checked before a stream opens.
    skipped = #{} :: #{non_neg_integer() => true},
    %% Connection-level flow control (RFC 9000 §4).
    conn_flow :: roadrunner_quic_flow:t(),
    %% When a request stream's receive credit is granted back: as its data
    %% arrives (`on_receipt`), or as the owner consumes it (`on_read`,
    %% `handle_consumed/4`), so a request body is held to one window past
    %% what its reader has read. Connection-level credit is always granted on
    %% receipt, so one slow reader never stalls the connection's other
    %% streams.
    stream_credit = on_receipt :: on_receipt | on_read,
    %% Connection-wide congestion control (RFC 9002 §7): bounds the bytes in
    %% flight across all spaces by the congestion window, grown on ACK and halved
    %% on loss.
    cc :: roadrunner_quic_cc_newreno:t(),
    %% Probe datagrams a probe timeout queued that the send pass after it lets
    %% past the congestion window (RFC 9002 §7.5: probes MUST NOT be blocked
    %% by the congestion controller); zero outside that pass.
    probes = 0 :: non_neg_integer(),
    %% The client's advertised transport parameters, captured from the
    %% ClientHello. The send windows (connection and per-stream) are seeded from
    %% these so the server never sends past what the peer granted (RFC 9000 §4.1);
    %% empty until the handshake delivers them.
    peer_params = #{} :: roadrunner_quic_transport_params:params(),
    %% Owner events and connection-id routing changes accumulated while
    %% folding a datagram's frames, drained in order at the end of
    %% handle_datagram (newest-first, reversed on drain), ahead of the sends.
    emits = [] :: [effect()],
    %% A locally-detected error to signal: {Level, WireErrorCode} for the one
    %% CONNECTION_CLOSE to transmit at that encryption level. `undefined` for a
    %% live connection or a peer-initiated close (which sends nothing back).
    pending_close = undefined :: undefined | {level(), non_neg_integer()},
    %% After our own CONNECTION_CLOSE from an established connection: the
    %% datagram that carried it, the packets received since, and the count at
    %% which to send it again (RFC 9000 §10.2.1).
    close_resend = undefined ::
        undefined | {Datagram :: binary(), Received :: non_neg_integer(), NextAt :: pos_integer()},
    %% The negotiated idle timeout in ms (RFC 9000 §10.1): the minimum of our
    %% advertised max_idle_timeout and the peer's, set from our value at birth and
    %% lowered to the negotiated minimum once the ClientHello delivers the peer's.
    idle_timeout :: non_neg_integer(),
    %% Absolute time (ms) the connection idle-times-out; reset to Now +
    %% idle_timeout on every received datagram (RFC 9000 §10.1). Always set
    %% (from new/2's birth time), so it is the timer floor when nothing is in
    %% flight. Also restarting it on the first ack-eliciting send since the
    %% last receive (§10.1) is a follow-up; receive-only is conservative
    %% (it closes no later than a strict implementation would).
    idle_deadline :: integer()
}).

-type stream() :: {roadrunner_quic_stream:t(), roadrunner_quic_flow:t()}.

-opaque t() :: #state{}.

-type config() :: #{
    dcid := binary(),
    scid := binary(),
    peer_scid := binary(),
    peer := {inet:ip_address(), inet:port_number()},
    reset_key := binary(),
    token_key := <<_:256>>,
    %% Whether the client's first Initial carried an address validation
    %% token that validated its address (RFC 9000 §8.1.3); `false` when
    %% absent.
    address_validated => boolean(),
    %% The listener's registry, for the shell to route the ids the core
    %% issues; the core itself never reads it.
    registry => roadrunner_quic_cid_registry:t(),
    cert_chain := [binary()],
    priv_key := public_key:private_key(),
    alpn := binary(),
    transport_params := roadrunner_quic_transport_params:params(),
    server_random := binary(),
    stream_credit => on_receipt | on_read
}.

%% A monotonic-clock millisecond, the same epoch `erlang:monotonic_time/1`
%% returns (negative on the BEAM), so an `arm_timer` deadline is `integer()`.
%% `{emit, Owner, Event}` is an async owner notification (the shell does
%% `Owner ! {quic, self(), Event}`); `{reply, To, Ref, Result}` answers a
%% synchronous control call.
-type effect() ::
    {send, binary()}
    | {arm_timer, atom(), integer()}
    | {emit, pid(), event()}
    | {reply, pid(), reference(), term()}
    | {register_cid, binary()}
    | {unregister_cid, binary()}
    | {register_reset, <<_:128>>}
    | {unregister_reset, <<_:128>>}
    | {send_to, address(), binary()}
    | {migrate, address()}.

%% Async owner notifications (conn -> owner). `stream_data` carries the
%% FIN-only end-of-stream as `{stream_data, Sid, <<>>, true}`.
%% `peer_changed` names the address the connection moved to (RFC 9000 §9).
%% `closed` is the terminal event: `{peer, ErrorCode}` is a peer
%% CONNECTION_CLOSE, `{peer, stateless_reset}` a client's stateless reset
%% (RFC 9000 §10.3), `{local, Reason}` a connection error we detected
%% (idle-timeout joins them later), and `drained` the owner's graceful close
%% going out once every response was sent.
-type event() ::
    {connected, info()}
    | {stream_opened, non_neg_integer()}
    | {stream_data, non_neg_integer(), binary(), boolean()}
    | {stream_reset, non_neg_integer(), non_neg_integer()}
    | {peer_changed, address()}
    | {closed, {peer, non_neg_integer() | stateless_reset} | {local, atom()} | drained}.

%% The `connected` payload. The h3 owner ignores it; it carries the
%% negotiated ALPN and the advertised transport params for forward-compat.
-type info() :: #{alpn := binary(), transport_params := roadrunner_quic_transport_params:params()}.

%% =============================================================================
%% Construction
%% =============================================================================

-doc """
Build the connection state from the per-connection config and the birth time
`Now` (ms). Bootstraps the Initial keys from the client's Destination
Connection ID (`dcid`), records the client's Source Connection ID (`peer_scid`)
as the destination every reply is addressed to (RFC 9000 §7.2), the TLS server
sequencer (the server transport parameters already carry the original/initial
connection ids), the Initial and Handshake packet-number spaces (the Application
space appears once 1-RTT keys arm), and the idle-timeout deadline anchored at
`Now`.
""".
-spec new(config(), integer()) -> t().
new(
    #{
        dcid := DCID,
        scid := SCID,
        peer_scid := PeerSCID,
        peer := Peer,
        reset_key := ResetKey,
        token_key := TokenKey,
        cert_chain := CertChain,
        priv_key := PrivKey,
        alpn := Alpn,
        transport_params := TransportParams,
        server_random := ServerRandom
    } = Config,
    Now
) ->
    Tls = roadrunner_quic_tls_server:new(#{
        cert_chain => CertChain,
        priv_key => PrivKey,
        alpn => Alpn,
        transport_params => TransportParams,
        server_random => ServerRandom,
        peer_scid => PeerSCID
    }),
    %% Seed the connection receive window and the stream-count limits from the
    %% values we advertise, so what is enforced (RFC 9000 §4.1 / §4.6) is exactly
    %% what the peer was told it may use, never a hardcoded default.
    #{
        initial_max_data := ConnMaxData,
        initial_max_streams_bidi := MaxStreamsBidi,
        initial_max_streams_uni := MaxStreamsUni
    } = TransportParams,
    %% Until the ClientHello delivers the peer's value, the idle timeout is our
    %% own advertised one (RFC 9000 §10.1).
    IdleTimeout = negotiated_idle_timeout(TransportParams, #{}),
    #state{
        dcid = DCID,
        scid = SCID,
        peer_scid = PeerSCID,
        cids = #{0 => SCID},
        reset_key = ResetKey,
        token_key = TokenKey,
        peer_cids = #{0 => PeerSCID},
        rx_peer = Peer,
        peer = Peer,
        path_dcid = SCID,
        tls = Tls,
        recv_keys = #{
            initial => roadrunner_quic_keys:for_connection(
                roadrunner_quic_keys:initial_client(DCID), open
            )
        },
        send_keys = #{
            initial => roadrunner_quic_keys:for_connection(
                roadrunner_quic_keys:initial_server(DCID), seal
            )
        },
        spaces = #{initial => new_space(), handshake => new_space()},
        amp = initial_amp(Config),
        owner = undefined,
        info = #{alpn => Alpn, transport_params => TransportParams},
        max_streams_bidi = MaxStreamsBidi,
        max_streams_uni = MaxStreamsUni,
        conn_flow = roadrunner_quic_flow:new(#{initial_max_data => ConnMaxData}),
        stream_credit = maps:get(stream_credit, Config, on_receipt),
        cc = roadrunner_quic_cc_newreno:new(),
        idle_timeout = IdleTimeout,
        idle_deadline = Now + IdleTimeout
    }.

%% A client whose first Initial carried a token that validated its address
%% (RFC 9000 §8.1.3) is spared the three-times limit from the start.
-spec initial_amp(config()) -> roadrunner_quic_amp:t().
initial_amp(#{address_validated := true}) ->
    roadrunner_quic_amp:validate(roadrunner_quic_amp:new());
initial_amp(#{}) ->
    roadrunner_quic_amp:new().

-spec new_space() -> #space{}.
new_space() ->
    #space{
        ack = roadrunner_quic_ack:new(),
        loss = roadrunner_quic_loss:new(#{}),
        crypto = roadrunner_quic_stream:new()
    }.

-doc "The peer address, answerable from the handshaking phase onward.".
-spec peername(t()) -> {ok, {inet:ip_address(), inet:port_number()}}.
peername(#state{peer = Peer}) ->
    {ok, Peer}.

-doc "The connection's current phase.".
-spec phase(t()) -> phase().
phase(#state{phase = Phase}) ->
    Phase.

-doc """
The connection ids that route datagrams to this connection: the client's
original Destination Connection ID and every id we issued that the client
has not retired (RFC 9000 §5.1).
""".
-spec routes(t()) -> [binary()].
routes(#state{dcid = DCID, cids = Cids}) ->
    [DCID | maps:values(Cids)].

-doc """
The client stateless reset tokens that route datagrams to this connection:
those of the client's ids not retired (RFC 9000 §10.3.1).
""".
-spec reset_routes(t()) -> [<<_:128>>].
reset_routes(#state{peer_reset_tokens = Tokens}) ->
    maps:values(Tokens).

%% The congestion window in bytes (RFC 9002 §7), for tests to observe its
%% slow-start growth and on-loss backoff.
-doc false.
-spec cwnd(t()) -> non_neg_integer().
cwnd(#state{cc = Cc}) ->
    roadrunner_quic_cc_newreno:cwnd(Cc).

%% =============================================================================
%% Inbound datagram
%% =============================================================================

-doc """
Process one UDP datagram received from `Peer`: account it against the
anti-amplification budget of the path it came on, decode and decrypt its
packets, fold each packet's frames into the connection state, then run a
send pass. Returns the new state and the effects to perform, led by
`{migrate, NewPeer}` when the datagram moved the connection to a new path.
""".
-spec handle_datagram(integer(), address(), binary(), t()) -> {t(), [effect()]}.
handle_datagram(Now, Peer, Datagram, State0) ->
    #state{
        amp = Amp,
        recv_keys = RecvKeys,
        phase = Before,
        idle_timeout = IdleTimeout,
        peer = Current,
        probe_path = Probe
    } = State = expire_previous_keys(Now, State0),
    Size = byte_size(Datagram),
    DCID = datagram_dcid(Datagram),
    Deadline = Now + IdleTimeout,
    %% Only bytes from an address count toward what may be sent to it (RFC
    %% 9000 §8.1): a datagram from elsewhere leaves the current path's
    %% budget alone.
    State1 =
        case Peer of
            Current ->
                State#state{
                    amp = roadrunner_quic_amp:received(Size, Amp),
                    idle_deadline = Deadline,
                    rx_dcid = DCID,
                    rx_peer = Peer,
                    rx_size = Size
                };
            _ ->
                State#state{
                    probe_path = probe_received(Peer, Size, Probe),
                    idle_deadline = Deadline,
                    rx_dcid = DCID,
                    rx_peer = Peer,
                    rx_size = Size
                }
        end,
    Outcomes = roadrunner_quic_recv:datagram(
        Datagram, ?SCID_LEN, open_keys(Before, RecvKeys), largest_map(State1)
    ),
    State2 =
        case undecrypted(Outcomes) andalso is_stateless_reset(Datagram, State1) of
            true -> process_stateless_reset(State1);
            false -> lists:foldl(fun(O, S) -> process_outcome(Now, O, S) end, State1, Outcomes)
        end,
    {State3, Effects} = finish_datagram(Now, Before, release_held(Now, State2)),
    {State3, peer_effects(Current, State3, Effects)}.

%% Whether a datagram's first packet failed to decrypt, or it held none: the
%% case in which a datagram MUST be checked for a stateless reset (RFC 9000
%% §10.3.1). One whose first packet decrypted, or was held unopened during
%% the handshake (no client token exists before it is confirmed), is not.
-spec undecrypted([roadrunner_quic_recv:outcome()]) -> boolean().
undecrypted([]) -> true;
undecrypted([{auth_failed, _Level} | _]) -> true;
undecrypted([{drop, _Reason} | _]) -> true;
undecrypted([_Outcome | _]) -> false.

%% RFC 9000 §10.3.1: a datagram of at least 21 bytes (a smaller one is no
%% Stateless Reset, §10.3) whose last 16 bytes are the stateless reset token
%% of a client id we use toward the address it came from. Tokens of ids
%% unused or retired MUST NOT count, and the comparison MUST NOT leak the
%% token through its timing, so each runs in constant time.
-spec is_stateless_reset(binary(), t()) -> boolean().
is_stateless_reset(Datagram, #state{phase = connected, rx_peer = Addr} = State) when
    byte_size(Datagram) >= 21
->
    #state{peer_reset_tokens = Tokens} = State,
    Skip = byte_size(Datagram) - 16,
    <<_:Skip/binary, Tail/binary>> = Datagram,
    lists:any(
        fun
            ({A, Seq}) when A =:= Addr ->
                case Tokens of
                    #{Seq := Token} -> crypto:hash_equals(Token, Tail);
                    #{} -> false
                end;
            (_Binding) ->
                false
        end,
        path_bindings(State)
    );
is_stateless_reset(_Datagram, _State) ->
    false.

%% Each path's address with the client id we use toward it: the current
%% path, the last validated one, and one the client probes from.
-spec path_bindings(t()) -> [{address(), non_neg_integer()}].
path_bindings(#state{peer = Peer, peer_cid_seq = Seq, prev_path = Prev, probe_path = Probe}) ->
    [{Peer, Seq} | [{Addr, S} || {Addr, S, _} <- [Prev, Probe]]].

%% A stateless reset from the client (RFC 9000 §10.3.1): it has lost the
%% connection, so this one MUST enter the draining period and send nothing
%% more, as on a CONNECTION_CLOSE from it.
-spec process_stateless_reset(t()) -> t().
process_stateless_reset(State) ->
    emit({closed, {peer, stateless_reset}}, State#state{phase = draining}).

%% The receive keys a datagram is opened with. Before the handshake completes
%% the 1-RTT keys are withheld (RFC 9001 §5.7: a server MUST NOT process, nor
%% even decrypt, 1-RTT packets until then), so the recv pipeline hands each
%% 1-RTT packet back still protected for process_outcome to hold.
-spec open_keys(phase(), #{level() => roadrunner_quic_recv:keys()}) ->
    #{level() => roadrunner_quic_recv:keys()}.
open_keys(handshaking, RecvKeys) -> maps:remove(application, RecvKeys);
open_keys(_Phase, RecvKeys) -> RecvKeys.

%% Once the handshake has completed, decrypt and process the 1-RTT packets
%% held back while it was in progress (RFC 9001 §5.7: they MAY be stored and
%% used once the handshake is complete), oldest first. Each opens against the
%% receive state as it then stands, so its packet number is reconstructed
%% from what was received before it, and a failed authentication counts
%% toward the integrity limit only now (§6.6). Every held packet came from
%% the handshake's address (process_outcome keeps no other), still the
%% connection's, as nothing moves it before the handshake is confirmed; each
%% is processed as received there, whatever address the datagram that
%% released it came from, so none can move the connection (RFC 9000 §9: a
%% client MUST NOT migrate before the handshake is confirmed, and these were
%% sent before it was). The datagram's own receive context is put back after.
-spec release_held(integer(), t()) -> t().
release_held(
    Now,
    #state{
        phase = connected, held = [_ | _] = Held, peer = Peer, rx_peer = RxPeer, rx_dcid = RxDCID
    } =
        State
) ->
    Released = lists:foldr(
        fun(Packet, S) -> open_held(Now, Packet, S) end,
        State#state{held = [], rx_peer = Peer},
        Held
    ),
    Released#state{rx_peer = RxPeer, rx_dcid = RxDCID};
release_held(_Now, State) ->
    State.

%% A held packet is processed as received with its own Destination
%% Connection ID, which a RETIRE_CONNECTION_ID in it must not retire (RFC
%% 9000 §19.16).
-spec open_held(integer(), binary(), t()) -> t().
open_held(Now, Packet, #state{recv_keys = RecvKeys} = State0) ->
    State = State0#state{rx_dcid = datagram_dcid(Packet)},
    Outcomes = roadrunner_quic_recv:datagram(Packet, ?SCID_LEN, RecvKeys, largest_map(State)),
    lists:foldl(fun(O, S) -> held_outcome(Now, O, S) end, State, Outcomes).

%% A held packet that opened with the next 1-RTT keys is a key update the
%% client began before it could have confirmed the handshake (RFC 9001 §6.1):
%% it was sent before our HANDSHAKE_DONE, and no 1-RTT packet of the client's
%% had been acknowledged (§4.1.2). That is a KEY_UPDATE_ERROR, as it was when
%% one arrived during the handshake, never a committed update.
-spec held_outcome(integer(), roadrunner_quic_recv:outcome(), t()) -> t().
held_outcome(_Now, {ok, #{generation := next}}, #state{phase = connected} = State) ->
    connection_fatal(application, key_update_error, State);
held_outcome(Now, Outcome, State) ->
    process_outcome(Now, Outcome, State).

%% Count a datagram from the address the client probes from toward what may
%% be sent there (RFC 9000 §8.1).
-spec probe_received(
    address(),
    non_neg_integer(),
    undefined | {address(), non_neg_integer(), roadrunner_quic_amp:t()}
) -> undefined | {address(), non_neg_integer(), roadrunner_quic_amp:t()}.
probe_received(Addr, Size, {Addr, Seq, Amp}) ->
    {Addr, Seq, roadrunner_quic_amp:received(Size, Amp)};
probe_received(_Addr, _Size, Probe) ->
    Probe.

%% Lead the effects with `{migrate, Peer}` when the call moved the
%% connection to another address, so the shell sends every `{send, _}` of
%% the call there, and tell the owner with `{peer_changed, Peer}` ahead of
%% the call's other events, so a request on a stream this datagram carries
%% already reports the new address. The owner hears of the move itself, not
%% of the validation that follows: the server switches on the non-probing
%% packet from the new address, before validation completes (RFC 9000
%% §9.3), so that address is where the client's requests now come from and
%% the one responses go to. A failed validation returns the connection to
%% the old address (§9.3.2), which the owner hears of the same way. An
%% owner installed later reads the current address with `peername/1`.
-spec peer_effects(address(), t(), [effect()]) -> [effect()].
peer_effects(Peer, #state{peer = Peer}, Effects) ->
    Effects;
peer_effects(_Old, #state{peer = Peer, owner = undefined}, Effects) ->
    [{migrate, Peer} | Effects];
peer_effects(_Old, #state{peer = Peer, owner = Owner}, Effects) ->
    [{migrate, Peer}, {emit, Owner, {peer_changed, Peer}} | Effects].

%% The Destination Connection ID a datagram was sent to: that of its first
%% packet, which every packet coalesced with it shares (RFC 9000 §12.2). A
%% short header carries the server's fixed-length id; a header too short to
%% hold one decodes to no packet at all.
-spec datagram_dcid(binary()) -> binary().
datagram_dcid(<<0:1, _:7, DCID:?SCID_LEN/binary, _/binary>>) ->
    DCID;
datagram_dcid(<<1:1, _:7, _Version:32, Len, DCID:Len/binary, _/binary>>) ->
    DCID;
datagram_dcid(_Datagram) ->
    <<>>.

%% After folding a datagram's frames: if a close fired during the fold,
%% transmit our CONNECTION_CLOSE for a locally-detected error (RFC 9000
%% §10.2.3) or send nothing for a peer CONNECTION_CLOSE (§10.2.2), then deliver
%% the {closed, _} emit. Otherwise run the send pass and drain owner events,
%% with {connected, _} ordered ahead of any stream events from the same
%% datagram so the owner opens its control stream before the first request.
-spec finish_datagram(integer(), phase(), t()) -> {t(), [effect()]}.
finish_datagram(_Now, draining, #state{phase = draining, close_resend = undefined} = State) ->
    %% A packet arrived during the drain window after the peer closed: absorb it
    %% silently (RFC 9000 §10.2.2). Send nothing and arm no timer, so the drain
    %% timer set on entry keeps running in the shell.
    drain_emits(State);
finish_datagram(_Now, draining, #state{phase = draining, close_resend = Resend} = State) ->
    %% A packet arrived after our own close: the peer may not have seen it, so
    %% answer with the same CONNECTION_CLOSE again (RFC 9000 §10.2.1), but only
    %% at exponentially spaced packet counts so the answers stay far fewer than
    %% the packets that draw them. No timer: the drain timer keeps running.
    {State1, Emits} = drain_emits(State),
    case Resend of
        {Datagram, Received, NextAt} when Received + 1 >= NextAt ->
            {State1#state{close_resend = {Datagram, Received + 1, NextAt * 2}}, [
                {send, Datagram} | Emits
            ]};
        {Datagram, Received, NextAt} ->
            {State1#state{close_resend = {Datagram, Received + 1, NextAt}}, Emits}
    end;
finish_datagram(Now, _Before, #state{phase = draining, pending_close = undefined} = State) ->
    %% Just entered draining via a peer CONNECTION_CLOSE: release any parked
    %% send replies (the send pass is skipped here, so a parked worker would
    %% otherwise stall the whole drain window), deliver {closed, _}, and arm
    %% the drain timer; send nothing.
    {State1, Releases} = release_all({error, closed}, State),
    {State2, EmitEffects} = drain_emits(State1),
    {State2, [{arm_timer, drain, drain_deadline(Now, State2)} | Releases ++ EmitEffects]};
finish_datagram(Now, _Before, #state{phase = draining} = State) ->
    %% Just entered draining via a locally-detected error: send our one
    %% CONNECTION_CLOSE, release any parked send replies, deliver {closed, _},
    %% and arm the drain timer. An established connection's address is
    %% validated, so the close always fits the §8.1 budget (send_close emits
    %% exactly one datagram).
    {State1, [{send, Datagram} = Close]} = send_close(State),
    {State2, Releases} = release_all({error, closed}, State1),
    {State3, EmitEffects} = drain_emits(State2#state{close_resend = {Datagram, 0, 1}}),
    {State3, [Close, {arm_timer, drain, drain_deadline(Now, State3)} | Releases ++ EmitEffects]};
finish_datagram(_Now, _Before, #state{phase = closed, pending_close = undefined} = State) ->
    drain_emits(State);
finish_datagram(_Now, _Before, #state{phase = closed} = State) ->
    {State1, CloseEffects} = send_close(State),
    {State2, EmitEffects} = drain_emits(State1),
    case CloseEffects of
        [] -> {State2, EmitEffects};
        [Close] -> {State2, [Close | EmitEffects]}
    end;
finish_datagram(Now, Before, State) ->
    {State3, SendEffects} = send_pass(Now, State),
    {State4, Emits} = take_emits(State3),
    %% {connected, _} first (so the owner opens its control stream before the
    %% first request), then the datagram's owner events in arrival order, then
    %% the sends; reverse the newest-first emits onto the sends in one pass.
    {State4, connected_effects(Before, State4, lists:reverse(Emits, SendEffects))}.

%% Owner events accumulate (newest-first) in #state.emits while the
%% datagram's frames are folded; hand them back in arrival order and clear.
-spec drain_emits(t()) -> {t(), [effect()]}.
drain_emits(State) ->
    {State1, Emits} = take_emits(State),
    {State1, lists:reverse(Emits)}.

%% Take the owner events newest-first (as accumulated) and clear them, for a
%% caller that will reverse them onto a tail itself.
-spec take_emits(t()) -> {t(), [effect()]}.
take_emits(#state{emits = Emits} = State) ->
    {State#state{emits = []}, Emits}.

%% Queue an owner event for the current datagram (dropped if no owner yet).
-spec emit(event(), t()) -> t().
emit(_Event, #state{owner = undefined} = State) ->
    State;
emit(Event, #state{owner = Owner, emits = Emits} = State) ->
    State#state{emits = [{emit, Owner, Event} | Emits]}.

%% Queue a shell effect for the current datagram alongside the owner events:
%% a connection-id routing change, performed ahead of the datagram's sends.
-spec queue_effect(effect(), t()) -> t().
queue_effect(Effect, #state{emits = Emits} = State) ->
    State#state{emits = [Effect | Emits]}.

%% Emit `{connected, Info}` exactly when this datagram drove the
%% handshaking -> connected transition AND an owner is installed. With no
%% owner yet (the listener has not run set_owner), the emit is deferred to
%% install_owner. The two sites are mutually exclusive, so it fires once.
-spec connected_effects(phase(), t(), [effect()]) -> [effect()].
connected_effects(handshaking, #state{phase = connected, owner = Owner, info = Info}, Tail) when
    is_pid(Owner)
->
    [{emit, Owner, {connected, Info}} | Tail];
connected_effects(_Before, _State, Tail) ->
    Tail.

%% =============================================================================
%% Control calls (owner / listener -> conn, synchronous)
%% =============================================================================

-doc """
Answer a synchronous control call: the shell forwards `{quic_call, From,
Ref, Request}` here and performs the returned `{reply, From, Ref, Result}`
(plus any deferred `{emit, _, _}`). Owner and listener calls into the
connection are synchronous; the connection only ever notifies the owner
with async `{emit, _, _}` effects, so it never blocks on the owner.
""".
-spec handle_call(pid(), reference(), Request, integer(), t()) -> {t(), [effect()]} when
    Request ::
        peername
        | tls_info
        | {set_owner, pid()}
        | open_uni
        | {reset_stream, non_neg_integer(), non_neg_integer()}
        | {stop_sending, non_neg_integer(), non_neg_integer()}
        | {close, non_neg_integer()}
        | {close, non_neg_integer(), binary()}
        | {close_when_done, non_neg_integer(), binary()}.
handle_call(From, Ref, peername, _Now, #state{peer = Peer} = State) ->
    {State, [{reply, From, Ref, {ok, Peer}}]};
handle_call(From, Ref, tls_info, _Now, #state{aead = Aead} = State) ->
    {State, [{reply, From, Ref, {ok, tls_info(Aead)}}]};
handle_call(From, Ref, {set_owner, Owner}, _Now, State) ->
    {State1, EmitEffects} = install_owner(Owner, State),
    {State1, [{reply, From, Ref, ok} | EmitEffects]};
handle_call(From, Ref, open_uni, Now, #state{next_uni = Id, peer_max_streams_uni = Max} = State) ->
    case Id div 4 of
        Ordinal when Ordinal < Max ->
            %% Allocate the next server-initiated unidirectional stream id. The
            %% stream itself is created lazily on the first send_data; the h3
            %% layer writes the stream-type byte + SETTINGS, never this layer.
            {State#state{next_uni = Id + 4}, [{reply, From, Ref, {ok, Id}}]};
        _ ->
            %% The peer's limit is reached (RFC 9000 §4.6: an endpoint MUST
            %% NOT exceed it): refuse the open, and tell the peer with a
            %% STREAMS_BLOCKED carrying the limit (§4.6 / §19.14 SHOULD).
            State1 = queue_frame(application, {streams_blocked, uni, Max}, State),
            {State2, SendEffects} = send_pass(Now, State1),
            {State2, [{reply, From, Ref, {error, stream_limit}} | SendEffects]}
    end;
handle_call(From, Ref, {reset_stream, Sid, ErrorCode}, Now, State) ->
    {State1, SendEffects} = do_reset_stream(Sid, ErrorCode, Now, State),
    {State1, [{reply, From, Ref, ok} | SendEffects]};
handle_call(From, Ref, {stop_sending, Sid, ErrorCode}, Now, State) ->
    {State1, SendEffects} = do_stop_sending(Sid, ErrorCode, Now, State),
    {State1, [{reply, From, Ref, ok} | SendEffects]};
handle_call(From, Ref, {close, ErrorCode}, Now, State) ->
    {State1, CloseEffects} = owner_close(ErrorCode, <<>>, Now, State),
    {State1, [{reply, From, Ref, ok} | CloseEffects]};
handle_call(From, Ref, {close, ErrorCode, Reason}, Now, State) ->
    {State1, CloseEffects} = owner_close(ErrorCode, Reason, Now, State),
    {State1, [{reply, From, Ref, ok} | CloseEffects]};
handle_call(
    From, Ref, {close_when_done, ErrorCode, Reason}, Now, #state{phase = connected} = State
) ->
    %% A graceful close (RFC 9114 §5.2): the owner sent its GOAWAY and closes
    %% once the requests it accepted are answered. The answers are on this
    %% connection's streams, so it is this side that sees the last one go:
    %% the send pass closes as soon as none is left, here when none is.
    {State1, Effects} = send_pass(Now, State#state{close_when_done = {ErrorCode, Reason}}),
    {State1, [{reply, From, Ref, ok} | Effects]};
handle_call(From, Ref, {close_when_done, _ErrorCode, _Reason}, _Now, State) ->
    %% Already closing: the owner hears that close's own {closed, _}.
    {State, [{reply, From, Ref, ok}]}.

-doc """
The owner consumed `Bytes` of a request stream whose credit it holds
(`stream_credit => on_read`): count them, and once enough of the stream's
window is consumed grant the peer a fresh MAX_STREAM_DATA and flush it. A
stream already gone (ended, pruned, reset) has no credit left to grant.
""".
-spec handle_consumed(non_neg_integer(), non_neg_integer(), integer(), t()) -> {t(), [effect()]}.
handle_consumed(Sid, Bytes, Now, #state{streams = Streams} = State) ->
    case Streams of
        #{Sid := {Stream, Flow}} ->
            Consumed = roadrunner_quic_flow:on_data_consumed(Bytes, Flow),
            {Flow1, State1} = grant_stream_credit(Sid, Consumed, State),
            send_pass(Now, put_stream(Sid, Stream, Flow1, State1));
        #{} ->
            {State, []}
    end.

%% The owner closes the connection (RFC 9000 §10.2.2): send one application
%% CONNECTION_CLOSE (0x1d, carrying the h3 error code and reason phrase) at the
%% 1-RTT level and linger in `draining` for 3x PTO so the peer's reordered
%% packets are absorbed before the shell tears down. The owner triggered this, so
%% no {closed, _} is emitted back; this runs only once the connection is
%% established (1-RTT keys present), which is the only state the owner has a
%% connection to close in. Distinct from connection_fatal/send_close (a
%% locally-detected transport error during datagram processing): this is the
%% application-variant close and never coalesces with other frames.
-spec owner_close(non_neg_integer(), binary(), integer(), t()) -> {t(), [effect()]}.
owner_close(ErrorCode, Reason, Now, #state{send_keys = SendKeys} = State) ->
    case SendKeys of
        #{application := _} ->
            send_owner_close(ErrorCode, Reason, Now, State);
        #{} ->
            %% The owner closed before the handshake completed (e.g. the
            %% connection_handler refusing on max_clients): there are no 1-RTT
            %% keys to carry an application CONNECTION_CLOSE, so close silently
            %% and let the client time out. No 1-RTT packets exist to drain.
            {State#state{phase = closed}, []}
    end.

-spec send_owner_close(non_neg_integer(), binary(), integer(), t()) -> {t(), [effect()]}.
send_owner_close(ErrorCode, Reason, Now, #state{peer_scid = DCID, scid = SCID} = State) ->
    Space = space(application, State),
    PN = Space#space.next_pn,
    Frame = {connection_close, application, ErrorCode, undefined, Reason},
    Entry = #{application => entry(application, [Frame], PN, State)},
    {Datagram, _Sent} = roadrunner_quic_send:datagram(Entry, DCID, SCID),
    State1 = put_space(
        application, Space#space{next_pn = PN + 1}, State#state{phase = draining}
    ),
    %% Release any parked send reply: a streaming worker can be mid-Push when
    %% the owner closes, and this path skips the send pass.
    {State2, Releases} = release_all({error, closed}, State1),
    {State2, [{send, Datagram}, {arm_timer, drain, drain_deadline(Now, State2)} | Releases]}.

%% Abandon the send side of a stream and tell the peer with a RESET_STREAM (RFC
%% 9000 §19.4): discard the unsent buffer, record the bytes already sent as the
%% Final Size, queue the frame at the application level, and flush it. The h3
%% layer uses this to abort a response stream.
-spec do_reset_stream(non_neg_integer(), non_neg_integer(), integer(), t()) -> {t(), [effect()]}.
do_reset_stream(Sid, ErrorCode, Now, State) ->
    {Stream, Flow, State1} = stream_for_send(Sid, State),
    FinalSize = roadrunner_quic_stream:send_offset(Stream),
    Stream1 = roadrunner_quic_stream:stop_sending(Stream),
    State2 = put_stream(Sid, Stream1, Flow, State1),
    State3 = queue_frame(application, {reset_stream, Sid, ErrorCode, FinalSize}, State2),
    send_pass(Now, State3).

%% Ask the peer to stop sending on a stream with a STOP_SENDING (RFC 9000
%% §19.5): queue the frame at the application level and flush it. The h3 layer
%% uses this to decline a request body it will not read.
-spec do_stop_sending(non_neg_integer(), non_neg_integer(), integer(), t()) -> {t(), [effect()]}.
do_stop_sending(Sid, ErrorCode, Now, State) ->
    State1 = queue_frame(application, {stop_sending, Sid, ErrorCode}, State),
    send_pass(Now, State1).

%% Install the owner. When the handshake already completed before the owner
%% was set (the deferred path), emit the once-only `{connected, Info}` now;
%% normally the listener sets the owner during handshaking, so the emit
%% instead rides out of handle_datagram at the transition.
-spec install_owner(pid(), t()) -> {t(), [effect()]}.
install_owner(Owner, #state{phase = connected, info = Info} = State) ->
    {State#state{owner = Owner}, [{emit, Owner, {connected, Info}}]};
install_owner(Owner, State) ->
    {State#state{owner = Owner}, []}.

-doc """
Buffer outbound stream data and run a send pass: the shell forwards
`{quic_send, From, Ref, Sid, IoData, Fin}` here. The data is enqueued on the
stream's send buffer (the stream is created on first reference), an optional
FIN is flagged, then the queued bytes are flushed as STREAM frames within the
connection and per-stream send-flow credit. Replies `ok`, or `{error, closed}`
on a draining connection, which sends no application data (RFC 9000 §10.2.2).
""".
-spec handle_send(pid(), reference(), non_neg_integer(), iodata(), boolean(), integer(), t()) ->
    {t(), [effect()]}.
handle_send(From, Ref, _Sid, _IoData, _Fin, _Now, #state{phase = draining} = State) ->
    {State, [{reply, From, Ref, {error, closed}}]};
handle_send(From, Ref, Sid, IoData, Fin, Now, State) ->
    State1 = enqueue_send(Sid, IoData, Fin, State),
    {State2, SendEffects} = send_pass(Now, State1),
    case park_send(Sid, From, Ref, State2) of
        {parked, State3} ->
            %% Backpressure: the bytes did not fully flush, so withhold the
            %% reply. The worker blocks in `await/3` until `release_drained/1`
            %% (from a later send pass once the window opens, or on abort)
            %% emits it. Bytes already went out in SendEffects.
            {State3, SendEffects};
        {reply, Result} ->
            {State2, [{reply, From, Ref, Result} | SendEffects]}
    end.

-doc """
Buffer a stream's final write, with its FIN, and run a send pass: the shell
forwards `{quic_send_final, Sid, IoData}` here. Unlike `handle_send/7` it is
never answered, so it never parks: the writer (a stream worker's buffered
response) has nothing left to send, and the connection owns the bytes from
here, including any that flow control holds back. Dropped on a draining
connection, which sends no application data (RFC 9000 §10.2.2).
""".
-spec handle_send_final(non_neg_integer(), iodata(), integer(), t()) -> {t(), [effect()]}.
handle_send_final(_Sid, _IoData, _Now, #state{phase = draining} = State) ->
    {State, []};
handle_send_final(Sid, IoData, Now, State) ->
    send_pass(Now, enqueue_send(Sid, IoData, true, State)).

%% Decide a send's reply: park (withhold) it iff this is a client-initiated
%% bidi request stream (`Sid rem 4 =:= 0`, where response workers write) that
%% is still present, not abandoned, and did not fully drain this pass —
%% mirroring `release_result/2`. An abandoned stream (peer reset / STOP_SENDING)
%% replies `{error, closed}` at once so the worker does not park on a dead
%% stream. A fully-drained or pruned send, or a server-uni control send
%% (`Sid rem 4 =/= 0`, which the conn-loop owner makes synchronously and must
%% never block), replies `ok`.
-spec park_send(non_neg_integer(), pid(), reference(), t()) ->
    {parked, t()} | {reply, ok | {error, closed}}.
park_send(Sid, From, Ref, #state{streams = Streams, parked = Parked} = State) when
    Sid rem 4 =:= 0
->
    case Streams of
        #{Sid := {Stream, _Flow}} ->
            case roadrunner_quic_stream:send_abandoned(Stream) of
                true ->
                    {reply, {error, closed}};
                false ->
                    case roadrunner_quic_stream:send_pending(Stream) of
                        true -> {parked, State#state{parked = Parked#{Sid => {From, Ref}}}};
                        false -> {reply, ok}
                    end
            end;
        #{} ->
            {reply, ok}
    end;
park_send(_Sid, _From, _Ref, _State) ->
    {reply, ok}.

%% Append outbound bytes to a stream's send buffer (creating the stream on
%% first reference) and flag the FIN when this is the final write.
-spec enqueue_send(non_neg_integer(), iodata(), boolean(), t()) -> t().
enqueue_send(Sid, IoData, Fin, State) ->
    {Stream0, Flow, State1} = stream_for_send(Sid, State),
    Stream1 = roadrunner_quic_stream:enqueue(IoData, Stream0),
    Stream2 =
        case Fin of
            true -> roadrunner_quic_stream:finish(Stream1);
            false -> Stream1
        end,
    put_stream(Sid, Stream2, Flow, State1).

%% Look up a stream for sending, or create it without announcing. Sends go to
%% the server's own streams or to existing client request streams, never to a
%% peer stream the owner has not already seen via {stream_opened, _}.
-spec stream_for_send(non_neg_integer(), t()) ->
    {roadrunner_quic_stream:t(), roadrunner_quic_flow:t(), t()}.
stream_for_send(
    Sid,
    #state{streams = Streams, info = #{transport_params := TP}, peer_params = PeerParams} = State
) ->
    case Streams of
        #{Sid := {Stream, Flow}} ->
            {Stream, Flow, State};
        #{} ->
            %% A server-first stream (response on a client request stream, or a
            %% server control / QPACK stream): seed its send window from what the
            %% client granted for that stream type, like the receive path does.
            Flow = roadrunner_quic_flow:new(#{
                initial_max_data => stream_recv_window(Sid, TP),
                peer_initial_max_data => peer_stream_send_window(Sid, PeerParams)
            }),
            {roadrunner_quic_stream:new(), Flow, State}
    end.

-spec process_outcome(integer(), roadrunner_quic_recv:outcome(), t()) -> t().
process_outcome(_Now, _Outcome, #state{phase = Phase} = State) when
    Phase =:= closed; Phase =:= draining
->
    %% A close fired on an earlier packet in this datagram, or a packet arrived
    %% during the drain window: skip the rest so we neither act on their frames
    %% nor discard (via validate_on_handshake) the space and keys a pending local
    %% close still needs to send its frame.
    State;
process_outcome(
    Now,
    {ok, #{generation := next, pn := PN} = Decoded},
    #state{key_phase = Phase, recv_keys = #{application := #{phase := RecvPhase}}} = State
) when Phase =/= RecvPhase ->
    %% Our send keys are a generation ahead: this is the peer's response to
    %% our own key update (RFC 9001 §6.2), its send keys now the ones ours
    %% moved to. Only the receive keys move; the update is not a new one.
    process_packet(Now, Decoded, promote_recv_keys(Now, PN, State));
process_outcome(Now, {ok, #{generation := next, pn := PN} = Decoded}, State) ->
    %% The packet authenticated with the next 1-RTT keys, so the peer has
    %% updated its keys (RFC 9001 §6.2). Only now, after that trial decryption
    %% succeeded, is the update committed: a forged packet with a flipped Key
    %% Phase bit fails it and changes nothing.
    case key_update_permitted(State) of
        true -> process_packet(Now, Decoded, commit_key_update(Now, PN, State));
        false -> connection_fatal(application, key_update_error, State)
    end;
process_outcome(
    Now,
    {ok, #{generation := current, pn := PN} = Decoded},
    #state{recv_keys = #{application := #{prev_below := Below} = Keys} = RecvKeys} = State
) when PN < Below ->
    %% A current-phase packet reordered ahead of the one that began the phase:
    %% only packets numbered below it can be from the previous phase (§6.5), so
    %% the previous keys never open a packet numbered above one the newer keys
    %% opened (§6.4).
    Keys1 = Keys#{prev_below := PN},
    process_packet(Now, Decoded, State#state{recv_keys = RecvKeys#{application := Keys1}});
process_outcome(Now, {ok, Decoded}, State) ->
    process_packet(Now, Decoded, State);
process_outcome(_Now, {auth_failed, Level}, #state{auth_failures = Failures} = State) ->
    auth_failed(Level, Failures + 1, State);
process_outcome(_Now, {drop, _Reason}, State) ->
    State;
process_outcome(
    Now, {held, Packet}, #state{phase = connected, held = Held, rx_peer = Peer, peer = Peer} = State
) ->
    %% A 1-RTT packet coalesced behind the Handshake packet whose Finished,
    %% earlier in this datagram, just completed the handshake (RFC 9001 §5.7
    %% suggests a client coalesce them so the server can process the 1-RTT
    %% packet at once): process it now, after any held from before.
    release_held(Now, State#state{held = [Packet | Held]});
process_outcome(_Now, {held, Packet}, #state{held = Held, rx_peer = Peer, peer = Peer} = State) when
    length(Held) < ?HELD_LIMIT
->
    %% A 1-RTT packet ahead of the client Finished (RFC 9001 §5.7): keep it,
    %% unprocessed and unacknowledged, until the handshake completes.
    State#state{held = [Packet | Held]};
process_outcome(_Now, {held, _Packet}, State) ->
    %% The hold is full, or the packet came from an address other than the
    %% handshake's: drop it, as §5.7 also allows. A 1-RTT packet held across
    %% the handshake was sent before the client could confirm it, when a
    %% client MUST NOT migrate (RFC 9000 §9), so one from elsewhere neither
    %% moves the connection nor is answered there. The client resends its
    %% frames once our acknowledgments show the packet lost.
    State;
process_outcome(_Now, {frame_error, Level, protocol_violation}, State) ->
    %% A protocol violation the recv pipeline flagged after the packet
    %% authenticated (non-zero reserved bits, RFC 9000 §17.2/§17.3.1, or no
    %% frames, §12.4): close with PROTOCOL_VIOLATION.
    connection_fatal(Level, protocol_violation, State);
process_outcome(_Now, {frame_error, Level, _Reason}, State) ->
    %% A malformed authenticated frame: truncated, of an unknown type, or with
    %% a field outside its range (RFC 9000 §12.4, §19).
    connection_fatal(Level, frame_encoding_error, State).

%% Fold a decrypted packet's frames into the connection and record it for
%% acknowledgment.
-spec process_packet(integer(), roadrunner_quic_recv:decoded(), t()) -> t().
process_packet(Now, #{level := Level, pn := PN, frames := Frames}, #state{spaces = Spaces} = State) ->
    case Spaces of
        #{Level := _} ->
            State1 = on_path(Now, Level, PN, Frames, validate_on_handshake(Level, State)),
            State2 = lists:foldl(
                fun(Frame, S) -> process_frame(Now, Level, Frame, S) end, State1, Frames
            ),
            record_received(Now, Level, PN, Frames, State2);
        #{} ->
            %% A packet for a discarded space (e.g. a late Initial); ignore.
            State
    end.

%% RFC 9001 §6.1: the peer MUST NOT update its keys before the handshake is
%% confirmed (at the server, once it completes, §4.1.2), nor update again
%% before it has an acknowledgment of a packet it sent in the current phase,
%% which only an ACK of ours sent since the last update can be. §6.2 lets an
%% endpoint treat a second update that comes too soon as a KEY_UPDATE_ERROR,
%% and §6.7 names that code for key-update errors, so both close with it.
-spec key_update_permitted(t()) -> boolean().
key_update_permitted(#state{phase = connected, update_acked = true}) -> true;
key_update_permitted(#state{}) -> false.

%% Commit a peer key update (RFC 9001 §6.2) once a packet has authenticated
%% with the next keys: the receive keys move to the next generation, and the
%% send keys follow in the same step, before any ACK of this packet can go
%% out (§6.2).
-spec commit_key_update(integer(), non_neg_integer(), t()) -> t().
commit_key_update(Now, PN, State) ->
    advance_send_keys(promote_recv_keys(Now, PN, State)).

%% Move the receive keys to the next generation once a packet from the peer
%% authenticates with them, on its own update or on its response to ours. The
%% next keys become the current ones; the current ones stay as the previous
%% generation for packets reordered from before the update, until three PTOs
%% from now (RFC 9001 §6.5), with the packet that began the phase as the
%% bound below which they apply. The generation after the new one is derived
%% now, so it is ready before the peer's next update and no later packet's
%% timing depends on deriving keys (§6.3, §9.5). The peer may update again
%% only once our ACK of this new phase goes out (§6.1), so that is awaited
%% afresh. The header-protection keys stay (§6.1).
-spec promote_recv_keys(integer(), non_neg_integer(), t()) -> t().
promote_recv_keys(
    Now,
    PN,
    #state{
        recv_keys = #{application := Recv} = RecvKeys,
        recv_secret = RecvSecret,
        aead = Aead
    } = State
) ->
    #{key := Key, iv := IV, phase := Phase, next := #{key := NextKey, iv := NextIV}} = Recv,
    {RecvSecret1, AfterNext} = roadrunner_quic_keys:update(Aead, RecvSecret),
    Recv1 = Recv#{
        key := NextKey,
        iv := NextIV,
        phase := 1 - Phase,
        next := roadrunner_quic_keys:for_connection(AfterNext, open),
        prev => #{key => Key, iv => IV},
        prev_below => PN
    },
    #space{loss = Loss} = space(application, State),
    State#state{
        recv_keys = RecvKeys#{application := Recv1},
        recv_secret = RecvSecret1,
        update_acked = false,
        prev_keys_until = Now + 3 * roadrunner_quic_loss:get_pto(Loss)
    }.

%% Move the send keys to the next generation (RFC 9001 §6.1) and flip the
%% Key Phase bit our packets carry: every later packet is protected with the
%% new keys (§6.4). The count toward the confidentiality limit starts over
%% for them (§6.6), and the next packet number is the first of the new phase,
%% which the peer must acknowledge before we may update again (§6.1).
-spec advance_send_keys(t()) -> t().
advance_send_keys(
    #state{
        send_keys = #{application := Send} = SendKeys,
        send_secret = SendSecret,
        aead = Aead,
        key_phase = Phase
    } = State
) ->
    {SendSecret1, SendNext} = roadrunner_quic_keys:update(Aead, SendSecret),
    #{key := SendKey, iv := SendIV} = roadrunner_quic_keys:for_connection(SendNext, seal),
    #space{next_pn = NextPN} = space(application, State),
    State#state{
        send_keys = SendKeys#{application := Send#{key := SendKey, iv := SendIV}},
        send_secret = SendSecret1,
        key_phase = 1 - Phase,
        sealed = 0,
        send_phase_pn = NextPN,
        own_update_at = undefined
    }.

%% Before each packet goes out, hold the current send keys to the AEAD
%% confidentiality limit (RFC 9001 §6.6), given `Sealed` packets already
%% protected with them (the state's own count; the tests pass a larger one).
%% Halfway to the limit we start a key update of our own as soon as §6.1 and
%% §6.5 allow one: that leaves the other half of the keys' budget, millions
%% of packets, for the peer's ACK of the current phase and the three-PTO
%% wait after it. If the limit comes first, the connection closes with
%% AEAD_LIMIT_REACHED while one packet is left for the CONNECTION_CLOSE, so
%% the keys never protect more than the limit (§6.6 RECOMMENDS closing before
%% an update becomes impossible).
-doc false.
-spec key_limit(non_neg_integer(), integer(), t()) -> t().
key_limit(Sealed, Now, #state{aead = Aead} = State) ->
    case confidentiality_limit(Aead) of
        Limit when Sealed < Limit bsr 1 ->
            State;
        Limit ->
            case own_update_permitted(Now, State) of
                true -> advance_send_keys(State);
                false when Sealed < Limit - 1 -> State#state{sealed = Sealed};
                false -> connection_fatal(application, aead_limit_reached, State)
            end
    end.

%% The TLS session as `ssl:connection_information/1` reports a TLS 1.3 one:
%% the suite's AEAD, its hash as the PRF (RFC 8446 §B.4), the key exchange
%% and MAC folded into the suite.
-spec tls_info(roadrunner_quic_aead:cipher()) -> ssl:connection_info().
tls_info(Aead) ->
    [
        {protocol, 'tlsv1.3'},
        {selected_cipher_suite, #{
            cipher => Aead, mac => aead, prf => suite_hash(Aead), key_exchange => any
        }}
    ].

-spec suite_hash(roadrunner_quic_aead:cipher()) -> sha256 | sha384.
suite_hash(aes_256_gcm) -> sha384;
suite_hash(_Aead) -> sha256.

-spec confidentiality_limit(roadrunner_quic_aead:cipher()) -> pos_integer().
confidentiality_limit(aes_128_gcm) -> ?AES_GCM_CONFIDENTIALITY_LIMIT;
confidentiality_limit(aes_256_gcm) -> ?AES_GCM_CONFIDENTIALITY_LIMIT;
confidentiality_limit(chacha20_poly1305) -> ?CHACHA20_POLY1305_CONFIDENTIALITY_LIMIT.

%% RFC 9001 §6.1: we may start a key update only once the handshake is
%% confirmed and the peer has acknowledged a packet sent with the current
%% keys, and §6.5 asks for three PTOs after that ACK (`own_update_at`). The
%% peer must also have answered our last update (its phase is ours again), or
%% a second update would put our keys two generations ahead of what it can
%% open.
-spec own_update_permitted(integer(), t()) -> boolean().
own_update_permitted(
    Now,
    #state{
        phase = connected,
        own_update_at = At,
        key_phase = Phase,
        recv_keys = #{application := #{phase := Phase}}
    }
) when is_integer(At), Now >= At ->
    true;
own_update_permitted(_Now, #state{}) ->
    false.

%% The first ACK of a 1-RTT packet sent with the current keys shows the peer
%% has them (RFC 9001 §6.1); a key update of ours may follow three PTOs later
%% (§6.5). The largest acknowledged packet is always among those the ACK
%% acknowledges.
-spec ack_of_send_phase(integer(), level(), non_neg_integer(), t()) -> t().
ack_of_send_phase(
    Now,
    application,
    Largest,
    #state{phase = connected, own_update_at = undefined, send_phase_pn = First} = State
) when Largest >= First ->
    #space{loss = Loss} = space(application, State),
    State#state{own_update_at = Now + 3 * roadrunner_quic_loss:get_pto(Loss)};
ack_of_send_phase(_Now, _Level, _Largest, State) ->
    State.

%% Drop the previous 1-RTT receive keys once their three PTOs have passed
%% (RFC 9001 §6.5): by then the peer has declared any packet from before the
%% update lost. Checked as each datagram arrives, so no packet opens with
%% them later; their secret was never kept.
-spec expire_previous_keys(integer(), t()) -> t().
expire_previous_keys(
    Now, #state{prev_keys_until = Until, recv_keys = #{application := Keys} = RecvKeys} = State
) when is_integer(Until), Now >= Until ->
    State#state{
        prev_keys_until = undefined,
        recv_keys = RecvKeys#{application := maps:without([prev, prev_below], Keys)}
    };
expire_previous_keys(_Now, State) ->
    State.

%% Count a received packet that failed authentication (RFC 9001 §6.6). Past
%% the integrity limit of the negotiated AEAD, counted across all keys, the
%% connection MUST close at once with AEAD_LIMIT_REACHED and process no more
%% packets.
-doc false.
-spec auth_failed(level(), non_neg_integer(), t()) -> t().
auth_failed(Level, Failures, #state{aead = Aead} = State) ->
    case integrity_limit(Aead) of
        Limit when Failures > Limit -> connection_fatal(Level, aead_limit_reached, State);
        _Limit -> State#state{auth_failures = Failures}
    end.

-spec integrity_limit(roadrunner_quic_aead:cipher()) -> pos_integer().
integrity_limit(aes_128_gcm) -> ?AES_GCM_INTEGRITY_LIMIT;
integrity_limit(aes_256_gcm) -> ?AES_GCM_INTEGRITY_LIMIT;
integrity_limit(chacha20_poly1305) -> ?CHACHA20_POLY1305_INTEGRITY_LIMIT.

%% A decrypted Handshake packet proves the client received the server's
%% Initial: lift the 3x anti-amplification limit (RFC 9000 §8.1) and
%% discard the Initial space and keys (RFC 9001 §4.9.1).
-spec validate_on_handshake(level(), t()) -> t().
validate_on_handshake(handshake, #state{validated = false, amp = Amp} = State) ->
    discard_space(initial, State#state{validated = true, amp = roadrunner_quic_amp:validate(Amp)});
validate_on_handshake(_Level, State) ->
    State.

-spec record_received(integer(), level(), non_neg_integer(), [roadrunner_quic_frame:frame()], t()) ->
    t().
record_received(Now, Level, PN, Frames, #state{spaces = Spaces} = State) ->
    case Spaces of
        #{Level := Space} ->
            Ack = roadrunner_quic_ack:record(
                PN, roadrunner_quic_send:ack_eliciting(Frames), Now, Space#space.ack
            ),
            put_space(Level, Space#space{ack = Ack}, State);
        #{} ->
            %% The space was discarded while folding this packet's frames
            %% (the handshake just confirmed); there is nothing left to ack.
            State
    end.

%% =============================================================================
%% Per-frame handlers
%% =============================================================================

-spec process_frame(integer(), level(), roadrunner_quic_frame:frame(), t()) -> t().
process_frame(_Now, _Level, _Frame, #state{phase = Phase} = State) when
    Phase =:= closed; Phase =:= draining
->
    %% A CONNECTION_CLOSE earlier in this packet already closed the connection, or
    %% the packet arrived during the drain window; ignore the remaining frames
    %% (RFC 9000 §10.2.2).
    State;
process_frame(
    _Now, application, {connection_close, _Variant, ErrorCode, _FrameType, _Reason}, State
) ->
    process_close(ErrorCode, State);
process_frame(_Now, _Level, {connection_close, transport, ErrorCode, _FrameType, _Reason}, State) ->
    process_close(ErrorCode, State);
process_frame(
    _Now, Level, {connection_close, application, _ErrorCode, _FrameType, _Reason}, State
) ->
    %% The application CONNECTION_CLOSE (0x1d) is 0-RTT/1-RTT only (RFC 9000
    %% §19.19); one decoded from an Initial/Handshake packet is a protocol
    %% violation.
    connection_fatal(Level, protocol_violation, State);
process_frame(_Now, Level, {crypto, Offset, Data}, State) ->
    process_crypto(Level, Offset, Data, State);
process_frame(Now, Level, {ack, _, _, _, _, _} = Ack, State) ->
    process_ack(Now, Level, Ack, State);
process_frame(_Now, application, {stream, Sid, Offset, Data, Fin}, State) ->
    process_stream(Sid, Offset, Data, Fin, State);
process_frame(_Now, application, {reset_stream, Sid, ErrorCode, FinalSize}, State) ->
    process_reset_stream(Sid, ErrorCode, FinalSize, State);
process_frame(_Now, application, {max_data, Max}, #state{conn_flow = ConnFlow} = State) ->
    %% Peer raised the connection-level send limit (RFC 9000 §4.1): grow the
    %% send window so a transfer past the initial grant keeps flowing. The send
    %% pass at the end of the datagram serves any stream this unblocks.
    State#state{conn_flow = roadrunner_quic_flow:on_max_data_received(Max, ConnFlow)};
process_frame(_Now, application, {max_stream_data, Sid, Max}, State) ->
    case is_sendable_stream(Sid, State) of
        true -> on_max_stream_data(Sid, Max, State);
        false -> connection_fatal(application, stream_state_error, State)
    end;
process_frame(_Now, application, {stop_sending, Sid, ErrorCode}, State) ->
    case is_sendable_stream(Sid, State) of
        true -> process_stop_sending(Sid, ErrorCode, State);
        false -> connection_fatal(application, stream_state_error, State)
    end;
process_frame(
    _Now, application, {max_streams, uni, Max}, #state{peer_max_streams_uni = Current} = State
) when Max > Current ->
    %% The peer raised the limit on the unidirectional streams the server may
    %% open (RFC 9000 §19.11). One that does not raise it falls through to the
    %% catch-all below: limits only grow, so it MUST be ignored.
    State#state{peer_max_streams_uni = Max};
process_frame(_Now, application, {retire_connection_id, Seq}, State) ->
    retire_cid(Seq, State);
process_frame(_Now, application, {new_connection_id, Seq, Prior, CID, Token}, State) ->
    new_peer_cid(Seq, Prior, CID, Token, State);
process_frame(_Now, _Level, padding, State) ->
    State;
process_frame(_Now, _Level, ping, State) ->
    State;
process_frame(_Now, Level, handshake_done, State) ->
    %% Only a server sends HANDSHAKE_DONE (RFC 9000 §19.20).
    connection_fatal(Level, protocol_violation, State);
process_frame(_Now, Level, {new_token, _Token}, State) ->
    %% Only a server sends NEW_TOKEN (RFC 9000 §19.7).
    connection_fatal(Level, protocol_violation, State);
process_frame(_Now, application, {path_challenge, Data}, State) ->
    answer_challenge(Data, State);
process_frame(Now, application, {path_response, Data}, State) ->
    path_response(Now, Data, State);
process_frame(_Now, application, _Frame, State) ->
    %% The other 1-RTT frames are accepted but not acted on: a MAX_STREAMS
    %% (bidi), since the server opens no bidirectional streams (RFC 9114 §6.1),
    %% or (uni) that does not raise the limit (RFC 9000 §19.11), and the
    %% BLOCKED signals.
    State;
process_frame(_Now, Level, _Frame, State) ->
    %% RFC 9000 §12.4 / §12.5: Initial and Handshake packets carry only
    %% PADDING, PING, ACK, CRYPTO and a transport CONNECTION_CLOSE, all
    %% handled above; any other frame there is a PROTOCOL_VIOLATION.
    connection_fatal(Level, protocol_violation, State).

%% Whether a stream id names a stream the server sends on, the only kind a
%% MAX_STREAM_DATA or STOP_SENDING can address (RFC 9000 §19.10, §19.5): a
%% client-initiated bidirectional stream, or a server-initiated
%% unidirectional one already opened. The others are receive-only (client
%% unidirectional) or were never created (the server opens no
%% bidirectional streams), and a frame naming one is a STREAM_STATE_ERROR.
-spec is_sendable_stream(non_neg_integer(), t()) -> boolean().
is_sendable_stream(Sid, _State) when Sid band 3 =:= 0 ->
    true;
is_sendable_stream(Sid, #state{next_uni = NextUni}) when Sid band 3 =:= 3 ->
    Sid < NextUni;
is_sendable_stream(_Sid, _State) ->
    false.

%% Raise a stream's send limit from a received MAX_STREAM_DATA (RFC 9000 §4.1).
%% Only a tracked stream can have unsent data to unblock; a grant for an unknown
%% id is ignored.
-spec on_max_stream_data(non_neg_integer(), non_neg_integer(), t()) -> t().
on_max_stream_data(Sid, Max, #state{streams = Streams} = State) ->
    case Streams of
        #{Sid := {Stream, Flow}} ->
            put_stream(Sid, Stream, roadrunner_quic_flow:on_max_data_received(Max, Flow), State);
        #{} ->
            State
    end.

%% =============================================================================
%% Connection ids (RFC 9000 §5.1)
%% =============================================================================

%% Keep the client supplied with spare connection ids (RFC 9000 §5.1.1):
%% issue fresh ones until as many are active as it accepts, its
%% active_connection_id_limit (2 when absent, §18.2; the handshake's id
%% counts), capped at ?ACTIVE_CID_LIMIT. Only a confirmed connection gets
%% here: the handshake's confirmation issues the first spares, and a
%% RETIRE_CONNECTION_ID, a 1-RTT frame, is held unprocessed until then (RFC
%% 9001 §5.7).
-spec issue_cids(t()) -> t().
issue_cids(#state{cids = Cids, peer_params = PeerParams} = State) ->
    Limit = maps:get(active_connection_id_limit, PeerParams, ?DEFAULT_ACTIVE_CID_LIMIT),
    issue_cids(min(Limit, ?ACTIVE_CID_LIMIT) - map_size(Cids), State).

-spec issue_cids(integer(), t()) -> t().
issue_cids(Count, State) when Count > 0 ->
    issue_cids(Count - 1, issue_cid(State));
issue_cids(_Count, State) ->
    State.

%% Issue one connection id: a fresh random one of the fixed length (so short
%% headers still demux, RFC 9000 §5.1, and nothing links it to the others)
%% with the next sequence number, announced in a NEW_CONNECTION_ID that
%% retires nothing, carrying its stateless reset token (§10.3.2). The
%% register_cid effect rides ahead of the datagram's sends, so the id routes
%% here before the client can learn it.
-spec issue_cid(t()) -> t().
issue_cid(#state{cids = Cids, next_cid_seq = Seq, reset_key = Key} = State) ->
    CID = crypto:strong_rand_bytes(?SCID_LEN),
    Token = roadrunner_quic_cid_registry:reset_token(Key, CID),
    State1 = queue_effect(
        {register_cid, CID}, State#state{cids = Cids#{Seq => CID}, next_cid_seq = Seq + 1}
    ),
    queue_frame(application, {new_connection_id, Seq, 0, CID, Token}, State1).

%% The client retires one of our connection ids (RFC 9000 §19.16). A
%% sequence number we never issued is a PROTOCOL_VIOLATION (a MUST). So is
%% retiring the id the datagram itself was sent to, which the client MUST
%% NOT do; §19.16 lets us treat it as one, and we do, since a client that
%% retires the id it is using is left addressing an id it gave up. An id
%% already retired (a retransmitted frame) changes nothing. Otherwise the id
%% stops routing here and a replacement keeps the client supplied (§5.1.1).
-spec retire_cid(non_neg_integer(), t()) -> t().
retire_cid(Seq, #state{next_cid_seq = Next} = State) when Seq >= Next ->
    connection_fatal(application, protocol_violation, State);
retire_cid(Seq, #state{cids = Cids, rx_dcid = RxDCID} = State) ->
    case Cids of
        #{Seq := RxDCID} ->
            connection_fatal(application, protocol_violation, State);
        #{Seq := CID} ->
            issue_cids(
                queue_effect({unregister_cid, CID}, State#state{cids = maps:remove(Seq, Cids)})
            );
        #{} ->
            State
    end.

%% A NEW_CONNECTION_ID from the client (RFC 9000 §19.15). A client that chose
%% a zero-length connection id MUST NOT send one, so that is a
%% PROTOCOL_VIOLATION. A repeat of a frame already processed changes nothing
%% (§19.15 MUST NOT treat it as an error), while a sequence number reused for
%% another id may be treated as a PROTOCOL_VIOLATION, and is. An id numbered
%% below the largest Retire Prior To is retired at once (§19.15 MUST); a
%% repeat of such a frame draws the RETIRE_CONNECTION_ID again, which the
%% client ignores, rather than holding every such number. An id we retired
%% on our own stays retired. Any other id joins the ids we may address, with
%% its stateless reset token routed here (§10.3.1), and then the ids below
%% its Retire Prior To are retired (§5.1.2). More active ids than we
%% advertised in active_connection_id_limit is a CONNECTION_ID_LIMIT_ERROR
%% (§5.1.1 MUST).
-spec new_peer_cid(non_neg_integer(), non_neg_integer(), binary(), <<_:128>>, t()) -> t().
new_peer_cid(_Seq, _Prior, _CID, _Token, #state{peer_scid = <<>>} = State) ->
    connection_fatal(application, protocol_violation, State);
new_peer_cid(
    Seq,
    Prior,
    CID,
    Token,
    #state{peer_cids = PeerCids, peer_retire_prior = Retired, peer_cids_retired = Dropped} = State
) ->
    case PeerCids of
        #{Seq := CID} ->
            State;
        #{Seq := _Other} ->
            connection_fatal(application, protocol_violation, State);
        #{} when Seq < Retired ->
            queue_frame(application, {retire_connection_id, Seq}, State);
        #{} ->
            case lists:member(Seq, Dropped) of
                true -> State;
                false -> add_peer_cid(Seq, Prior, CID, Token, State)
            end
    end.

-spec add_peer_cid(non_neg_integer(), non_neg_integer(), binary(), <<_:128>>, t()) -> t().
add_peer_cid(
    Seq, Prior, CID, Token, #state{peer_cids = PeerCids, peer_reset_tokens = Tokens} = State
) ->
    Added = queue_effect({register_reset, Token}, State#state{
        peer_cids = PeerCids#{Seq => CID}, peer_reset_tokens = Tokens#{Seq => Token}
    }),
    State1 = retire_prior(Prior, Added),
    #state{peer_cids = Active, info = #{transport_params := OurParams}} = State1,
    case maps:get(active_connection_id_limit, OurParams, ?DEFAULT_ACTIVE_CID_LIMIT) of
        Limit when map_size(Active) > Limit ->
            connection_fatal(application, connection_id_limit_error, State1);
        _Limit ->
            State1
    end.

%% Honour an increased Retire Prior To (RFC 9000 §5.1.2): stop using every
%% client id numbered below it and retire each with a RETIRE_CONNECTION_ID.
%% A path whose id goes stops being one we can return to or answer on. When
%% the id we address is among them, the lowest-numbered id left that no
%% other path uses takes over; the frame that raised the value carries one
%% numbered at or above it, so one is always left. A Retire Prior To that
%% does not increase the largest received is ignored (§19.15 MUST).
-spec retire_prior(non_neg_integer(), t()) -> t().
retire_prior(Prior, #state{peer_retire_prior = Retired} = State) when Prior =< Retired ->
    State;
retire_prior(
    Prior,
    #state{
        peer_cids = PeerCids,
        peer_cid_seq = Current,
        peer_cids_retired = Dropped,
        prev_path = Prev,
        probe_path = Probe
    } = State
) ->
    {Gone, Kept} = maps:fold(
        fun
            (Seq, _CID, {G, K}) when Seq < Prior -> {[Seq | G], K};
            (Seq, CID, {G, K}) -> {G, K#{Seq => CID}}
        end,
        {[], #{}},
        PeerCids
    ),
    State1 = lists:foldl(
        fun(Seq, S) ->
            queue_frame(application, {retire_connection_id, Seq}, forget_reset_token(Seq, S))
        end,
        State#state{
            peer_cids = Kept,
            peer_retire_prior = Prior,
            peer_cids_retired = [Seq || Seq <- Dropped, Seq >= Prior],
            prev_path = unless_retired(Prior, Prev),
            probe_path = unless_retired(Prior, Probe)
        },
        Gone
    ),
    case Kept of
        #{Current := _} -> State1;
        #{} -> use_peer_cid(unused_peer_cid(State1), State1)
    end.

%% A path binding whose client id a Retire Prior To leaves alone.
-spec unless_retired(non_neg_integer(), Path) -> Path | undefined when
    Path :: undefined | tuple().
unless_retired(Prior, {_Addr, Seq, _} = Path) when Seq >= Prior ->
    Path;
unless_retired(_Prior, _Path) ->
    undefined.

%% Address the current path with the client id numbered `Seq`.
-spec use_peer_cid(non_neg_integer(), t()) -> t().
use_peer_cid(Seq, #state{peer_cids = PeerCids} = State) ->
    #{Seq := CID} = PeerCids,
    State#state{peer_cid_seq = Seq, peer_scid = CID}.

%% The lowest-numbered client id no path uses (RFC 9000 §9.5: an id is
%% never used toward more than one address), or `none`.
-spec unused_peer_cid(t()) -> non_neg_integer() | none.
unused_peer_cid(#state{peer_cids = PeerCids} = State) ->
    case [Seq || Seq <- lists:sort(maps:keys(PeerCids)), not peer_cid_bound(Seq, State)] of
        [Seq | _] -> Seq;
        [] -> none
    end.

%% Whether a path uses the client id numbered `Seq`.
-spec peer_cid_bound(non_neg_integer(), t()) -> boolean().
peer_cid_bound(Seq, #state{peer_cid_seq = Seq}) -> true;
peer_cid_bound(Seq, #state{prev_path = {_Addr, Seq, _PathDcid}}) -> true;
peer_cid_bound(Seq, #state{probe_path = {_Addr, Seq, _Amp}}) -> true;
peer_cid_bound(_Seq, #state{}) -> false.

%% Retire a client id no path uses any more (RFC 9000 §5.1.2: an endpoint
%% SHOULD retire an id once it no longer uses the address it was used
%% toward), which also asks the client for a replacement. An id another path
%% still uses stays.
-spec release_peer_cid(non_neg_integer(), t()) -> t().
release_peer_cid(Seq, #state{peer_cids = PeerCids, peer_cids_retired = Dropped} = State) ->
    case peer_cid_bound(Seq, State) of
        true ->
            State;
        false ->
            queue_frame(
                application,
                {retire_connection_id, Seq},
                forget_reset_token(Seq, State#state{
                    peer_cids = maps:remove(Seq, PeerCids), peer_cids_retired = [Seq | Dropped]
                })
            )
    end.

%% A retired client id's stateless reset token stops routing here and no
%% longer counts (RFC 9000 §10.3: a token is invalidated with its id).
-spec forget_reset_token(non_neg_integer(), t()) -> t().
forget_reset_token(Seq, #state{peer_reset_tokens = Tokens} = State) ->
    case Tokens of
        #{Seq := Token} ->
            queue_effect({unregister_reset, Token}, State#state{
                peer_reset_tokens = maps:remove(Seq, Tokens)
            });
        #{} ->
            State
    end.

%% =============================================================================
%% Paths and connection migration (RFC 9000 §8.2, §9)
%% =============================================================================

%% Follow the client to the address an authenticated 1-RTT packet came from
%% (RFC 9000 §9.3). A packet from the current address, sent to the id the
%% client uses there, changes nothing, which costs the common case two
%% comparisons; one sent to another of our ids (the client may switch at any
%% time, §5.1.2) makes that the id the current path uses. Only a confirmed
%% connection moves (§9: a client MUST NOT migrate before), only on a
%% non-probing packet (§9.1, §9.2), and only on the highest-numbered one
%% received, so a reordered older packet never moves it back (§9.3).
-spec on_path(integer(), level(), non_neg_integer(), [roadrunner_quic_frame:frame()], t()) -> t().
on_path(
    _Now,
    _Level,
    _PN,
    _Frames,
    #state{rx_peer = Peer, peer = Peer, rx_dcid = DCID, path_dcid = DCID} = State
) ->
    State;
on_path(
    _Now, application, PN, _Frames, #state{rx_peer = Peer, peer = Peer, rx_dcid = DCID} = State
) ->
    case highest_received(PN, State) of
        true -> State#state{path_dcid = DCID};
        false -> State
    end;
on_path(_Now, _Level, _PN, _Frames, #state{rx_peer = Peer, peer = Peer} = State) ->
    State;
on_path(Now, application, PN, Frames, #state{phase = connected} = State) ->
    case lists:all(fun is_probing/1, Frames) orelse not highest_received(PN, State) of
        true -> State;
        false -> migrate(Now, State)
    end;
on_path(_Now, _Level, _PN, _Frames, State) ->
    State.

%% RFC 9000 §9.1: the probing frames; a packet of nothing else is a probing
%% packet.
-spec is_probing(roadrunner_quic_frame:frame()) -> boolean().
is_probing({path_challenge, _Data}) -> true;
is_probing({path_response, _Data}) -> true;
is_probing({new_connection_id, _Seq, _Prior, _CID, _Token}) -> true;
is_probing(padding) -> true;
is_probing(_Frame) -> false.

%% Whether a 1-RTT packet numbered `PN` is the highest-numbered received.
-spec highest_received(non_neg_integer(), t()) -> boolean().
highest_received(PN, State) ->
    #space{ack = Ack} = space(application, State),
    case roadrunner_quic_ack:largest(Ack) of
        undefined -> true;
        Largest -> PN > Largest
    end.

%% Move to the datagram's source address. Back on the last validated path,
%% validation is skipped (RFC 9000 §9.3: an address validated before may
%% be); a new address needs a client id never used toward another (§9.5),
%% and with none to spare the connection stays where it is until the client
%% provides one (§9.3).
-spec migrate(integer(), t()) -> t().
migrate(_Now, #state{rx_peer = Addr, prev_path = {Addr, _Seq, _PathDcid}} = State) ->
    return_to_prev(State);
migrate(Now, State) ->
    case path_cid(State) of
        none -> State;
        Seq -> move_to(Now, Seq, State)
    end.

%% The client id to address the datagram's source address with: the one our
%% answers to its probes there already carry, else one no path uses, else,
%% when the client still addresses the id it used on the current path, the
%% current one (RFC 9000 §9.5 MAY: an address change the client did not
%% make, such as a NAT rebinding). A client that chose a zero-length id has
%% only that one for every path. `none` when the address has no id to use.
-spec path_cid(t()) -> non_neg_integer() | none.
path_cid(#state{peer_scid = <<>>, peer_cid_seq = Seq}) ->
    Seq;
path_cid(#state{rx_peer = Addr, probe_path = {Addr, Seq, _Amp}}) ->
    Seq;
path_cid(#state{rx_dcid = RxDCID, path_dcid = RxDCID, peer_cid_seq = Current} = State) ->
    case unused_peer_cid(State) of
        none -> Current;
        Seq -> Seq
    end;
path_cid(State) ->
    unused_peer_cid(State).

%% Move the connection to the datagram's source address, addressed with the
%% client id numbered `Seq` (RFC 9000 §9.3 MUST: later packets go there),
%% and start validating it (§9.3 MUST). Until then it may be sent three
%% times what it sent (§9.3.1, §8.1), counting what it sent while probing.
%% Leaving a validated path makes it the one to return to (§9.3.2) and
%% challenges it too (§9.3.3 MUST), which draws a non-probing packet from a
%% client still there, moving the connection back. Leaving a path still
%% being validated abandons that validation (§9.3), keeps the last validated
%% path as the one to return to, and retires the abandoned path's client id
%% unless another path still uses it.
-spec move_to(integer(), non_neg_integer(), t()) -> t().
move_to(
    Now,
    Seq,
    #state{
        rx_peer = Addr,
        rx_size = Size,
        rx_dcid = RxDCID,
        peer = Old,
        peer_scid = OldDCID,
        peer_cid_seq = OldSeq,
        path_dcid = OldPathDcid,
        validation = Validation,
        probe_path = Probe
    } = State
) ->
    {Amp, Probe1} =
        case Probe of
            {Addr, _Seq, ProbeAmp} -> {ProbeAmp, undefined};
            _ -> {roadrunner_quic_amp:received(Size, roadrunner_quic_amp:new()), Probe}
        end,
    Moved = use_peer_cid(Seq, State#state{
        peer = Addr, path_dcid = RxDCID, amp = Amp, probe_path = Probe1
    }),
    State1 =
        case Validation of
            undefined ->
                queue_path(
                    {validated, Old, OldDCID},
                    [{path_challenge, crypto:strong_rand_bytes(8)}],
                    Moved#state{prev_path = {Old, OldSeq, OldPathDcid}}
                );
            #validation{} ->
                release_peer_cid(OldSeq, Moved)
        end,
    start_validation(Now, address, State1).

%% Back to the last validated path, as it was (RFC 9000 §9.3.2, §9.3): the
%% address, the client id and the lifted anti-amplification limit; the
%% congestion controller and RTT estimate were never reset for the path
%% left, which is abandoned and its client id retired unless another path
%% uses it.
-spec return_to_prev(t()) -> t().
return_to_prev(#state{prev_path = {Addr, Seq, PathDcid}, peer_cid_seq = Left} = State) ->
    Returned = use_peer_cid(Seq, State#state{
        peer = Addr,
        path_dcid = PathDcid,
        amp = roadrunner_quic_amp:validate(roadrunner_quic_amp:new()),
        validation = undefined,
        prev_path = undefined
    }),
    release_peer_cid(Left, Returned).

%% Keep the path a failed validation leaves as the address the client
%% probes from, with its client id and anti-amplification account (RFC 9000
%% §8.1, §9.5), instead of retiring the id. A client that really moved
%% there, whose challenges or responses were lost, keeps sending from it,
%% and its next non-probing packet moves the connection back with that id.
%% Retiring it would be sent on the old path, which such a client no longer
%% reads, so no replacement would come and the connection could never move
%% again. It takes over from any earlier probing address, whose id is
%% retired unless another path uses it.
-spec keep_as_probe(t()) -> t().
keep_as_probe(#state{peer = Addr, peer_cid_seq = Seq, amp = Amp, probe_path = Old} = State) ->
    Kept = State#state{probe_path = {Addr, Seq, Amp}, stranded = Addr},
    case Old of
        {_OldAddr, OldSeq, _OldAmp} -> release_peer_cid(OldSeq, Kept);
        undefined -> Kept
    end.

%% Start (or restart, for the path MTU) the validation of the current path
%% with a fresh PATH_CHALLENGE (RFC 9000 §8.2.1). A challenge goes out again
%% every interval, no more often than a probe timeout would allow (§9.4
%% MUST NOT be more aggressive, §8.2.1 SHOULD NOT exceed the Initial
%% cadence), and the validation is abandoned after three intervals: three
%% times the larger of the current probe timeout and one from the initial
%% RTT (§8.2.4).
-spec start_validation(integer(), address | mtu, t()) -> t().
start_validation(Now, Stage, State) ->
    #space{loss = Loss} = space(application, State),
    Interval = max(
        roadrunner_quic_loss:get_pto(Loss),
        roadrunner_quic_loss:get_pto(roadrunner_quic_loss:new(#{}))
    ),
    queue_challenge(State#state{
        validation = #validation{
            stage = Stage,
            next_at = Now + Interval,
            abandon_at = Now + 3 * Interval,
            interval = Interval
        }
    }).

-spec queue_challenge(t()) -> t().
queue_challenge(#state{path_out = Out} = State) ->
    State#state{path_out = [challenge | Out]}.

-spec queue_path(path(), [roadrunner_quic_frame:frame()], t()) -> t().
queue_path(Path, Frames, #state{path_out = Out} = State) ->
    State#state{path_out = [{Path, Frames} | Out]}.

%% RFC 9000 §8.2.2: answer a PATH_CHALLENGE with a PATH_RESPONSE echoing
%% it, on the path it arrived on (MUST). From an address the connection is
%% not on, the answer is a probing packet there (§9.1), addressed with a
%% client id kept for that address (§9.5), and dropped when the client left
%% none for it.
-spec answer_challenge(binary(), t()) -> t().
answer_challenge(Data, #state{rx_peer = Peer, peer = Peer} = State) ->
    queue_path(current, [{path_response, Data}], State);
answer_challenge(
    Data, #state{rx_peer = Addr, prev_path = {Addr, Seq, _PathDcid}, peer_cids = PeerCids} = State
) ->
    #{Seq := DCID} = PeerCids,
    queue_path({validated, Addr, DCID}, [{path_response, Data}], State);
answer_challenge(Data, State) ->
    case probe_path(State) of
        none -> State;
        State1 -> queue_path(probe, [{path_response, Data}], State1)
    end.

%% Keep a client id for the address the client probes from (RFC 9000 §9.5),
%% with an anti-amplification account of its own (§8.1) that this datagram
%% opens. A new probing address takes over from the last one, whose id is
%% retired unless another path uses it.
-spec probe_path(t()) -> t() | none.
probe_path(#state{rx_peer = Addr, probe_path = {Addr, _Seq, _Amp}} = State) ->
    State;
probe_path(#state{rx_peer = Addr, rx_size = Size, probe_path = Old} = State) ->
    case path_cid(State) of
        none ->
            none;
        Seq ->
            Amp = roadrunner_quic_amp:received(Size, roadrunner_quic_amp:new()),
            Bound = State#state{probe_path = {Addr, Seq, Amp}},
            case Old of
                {_OldAddr, OldSeq, _OldAmp} -> release_peer_cid(OldSeq, Bound);
                undefined -> Bound
            end
    end.

%% A PATH_RESPONSE echoing a challenge the current path's validation sent
%% validates it (RFC 9000 §8.2.3), whatever path it arrives on. One answering
%% a challenge whose datagram reached 1200 bytes validates the path MTU too;
%% one answering a smaller challenge validates only the address, and a
%% second validation with an expanded datagram follows (§8.2.1 MUST). Any
%% other response, such as one to a challenge of an abandoned validation, is
%% ignored rather than closing the connection (§19.18 MAY).
-spec path_response(integer(), binary(), t()) -> t().
path_response(Now, Data, #state{validation = #validation{sent = Sent, stage = Stage}} = State) ->
    case lists:keyfind(Data, 1, Sent) of
        {Data, true} ->
            path_validated(Now, Stage, State);
        {Data, false} when Stage =:= address ->
            start_validation(Now, mtu, confirm_address(Now, State));
        _ ->
            State
    end;
path_response(_Now, _Data, State) ->
    State.

%% The current path is validated: the last validated path is no longer the
%% one to return to, and its client id is retired unless a path uses it.
-spec path_validated(integer(), address | mtu, t()) -> t().
path_validated(Now, address, State) ->
    path_validated(Now, mtu, confirm_address(Now, State));
path_validated(_Now, mtu, #state{prev_path = Prev} = State) ->
    Validated = State#state{validation = undefined, prev_path = undefined},
    case Prev of
        {_Addr, Seq, _PathDcid} -> release_peer_cid(Seq, Validated);
        undefined -> Validated
    end.

%% The client owns its new address: lift the anti-amplification limit
%% (RFC 9000 §8.1), and start the congestion controller and RTT estimate
%% over for the new path (§9.4 MUST), unless only the port changed, which a
%% NAT rebinding usually causes and §9.4 lets the path keep both for. A new
%% IP address also gets a token of its own (§9.3 SHOULD), the ones sent
%% before being sealed for the old one.
-spec confirm_address(integer(), t()) -> t().
confirm_address(Now, #state{amp = Amp, peer = {Ip, _Port}, prev_path = Prev} = State) ->
    Confirmed = State#state{amp = roadrunner_quic_amp:validate(Amp)},
    case Prev of
        {{Ip, _PrevPort}, _Seq, _PathDcid} ->
            Confirmed;
        _ ->
            #space{loss = Loss} = Space = space(application, Confirmed),
            queue_new_token(
                put_space(
                    application,
                    Space#space{loss = roadrunner_quic_loss:reset_rtt(Now, Loss)},
                    Confirmed#state{cc = roadrunner_quic_cc_newreno:new_path(Now)}
                )
            )
    end.

%% Send the client a NEW_TOKEN sealed for the IP address of the current
%% path, validated by now (RFC 9000 §8.1.3, §19.7).
-spec queue_new_token(t()) -> t().
queue_new_token(#state{token_key = Key, peer = {Ip, _Port}} = State) ->
    queue_frame(application, {new_token, roadrunner_quic_token:new(Key, Ip)}, State).

%% Send one queued probing packet ahead of the send pass's other packets. A
%% `challenge` is a fresh PATH_CHALLENGE (RFC 9000 §8.2.1 MUST: unpredictable
%% data, a different payload each time, §13.3) on the current path, recorded
%% so its response validates the path.
-spec send_path(integer(), challenge | {path(), [roadrunner_quic_frame:frame()]}, t(), [effect()]) ->
    {t(), [effect()]}.
send_path(Now, challenge, #state{validation = #validation{sent = Sent} = V} = State, Acc) ->
    Data = crypto:strong_rand_bytes(8),
    case path_packet(Now, current, [{path_challenge, Data}], State) of
        {Datagram, State1} ->
            Expanded = byte_size(Datagram) >= ?MIN_PATH_DATAGRAM,
            {State1#state{validation = V#validation{sent = [{Data, Expanded} | Sent]}}, [
                {send, Datagram} | Acc
            ]};
        none ->
            {State, Acc}
    end;
send_path(Now, {Path, Frames}, State, Acc) ->
    case path_packet(Now, Path, Frames, State) of
        {Datagram, State1} -> {State1, [path_send(Path, Datagram, State1) | Acc]};
        none -> {State, Acc}
    end.

-spec path_send(path(), binary(), t()) -> effect().
path_send(current, Datagram, _State) ->
    {send, Datagram};
path_send({validated, Addr, _DCID}, Datagram, _State) ->
    {send_to, Addr, Datagram};
path_send(probe, Datagram, #state{probe_path = {Addr, _Seq, _Amp}}) ->
    {send_to, Addr, Datagram}.

%% Build a probing packet for a path: one 1-RTT packet of its frames,
%% expanded to fill a 1200-byte datagram (RFC 9000 §8.2.1, §8.2.2) as far as
%% the path's anti-amplification limit allows (MUST NOT exceed it), and
%% dropped if even the bare packet would exceed it. On the current path it
%% counts like any packet; on another it is kept out of the bytes in flight,
%% so its loss neither shrinks the current path's congestion window nor
%% arms a probe timeout there (§9.4 lets probe packets be excepted). `none`
%% when the probing address has lost its client id since the packet was
%% queued (a Retire Prior To in the same packet).
-spec path_packet(integer(), path(), [roadrunner_quic_frame:frame()], t()) ->
    {binary(), t()} | none.
path_packet(Now, Path, Frames, #state{scid = SCID, sealed = Sealed} = State) ->
    case path_target(Path, State) of
        none ->
            none;
        {DCID, Budget} ->
            #space{next_pn = PN} = Space = space(application, State),
            Entry = (entry(application, Frames, PN, State))#{pad_to => path_pad(Budget)},
            {Datagram, [Sent]} = roadrunner_quic_send:datagram(#{application => Entry}, DCID, SCID),
            case byte_size(Datagram) =< Budget of
                true ->
                    State1 = put_space(
                        application, Space#space{next_pn = PN + 1}, State#state{sealed = Sealed + 1}
                    ),
                    {Datagram, path_sent(Now, Path, Sent, byte_size(Datagram), State1)};
                false ->
                    none
            end
    end.

%% A probing packet fills a 1200-byte datagram when the anti-amplification
%% limit allows it (RFC 9000 §8.2.1 MUST) and otherwise goes bare: a smaller
%% datagram cannot validate the path MTU anyway, and the budget it would
%% spend is what lets a lost challenge be sent again.
-spec path_pad(non_neg_integer() | infinity) -> non_neg_integer().
path_pad(Budget) when Budget >= ?MIN_PATH_DATAGRAM -> ?MIN_PATH_DATAGRAM;
path_pad(_Budget) -> 0.

%% The client id and anti-amplification budget for a path's probing packet.
-spec path_target(path(), t()) -> {binary(), non_neg_integer() | infinity} | none.
path_target(current, #state{peer_scid = DCID, amp = Amp}) ->
    {DCID, roadrunner_quic_amp:budget(Amp)};
path_target({validated, _Addr, DCID}, #state{}) ->
    {DCID, infinity};
path_target(probe, #state{probe_path = {_Addr, Seq, Amp}, peer_cids = PeerCids}) ->
    #{Seq := DCID} = PeerCids,
    {DCID, roadrunner_quic_amp:budget(Amp)};
path_target(_Path, #state{}) ->
    none.

-spec path_sent(integer(), path(), roadrunner_quic_send:sent(), non_neg_integer(), t()) -> t().
path_sent(Now, current, Sent, Size, #state{amp = Amp} = State) ->
    record_one_sent(Now, Sent, State#state{amp = roadrunner_quic_amp:sent(Size, Amp)});
path_sent(Now, {validated, _Addr, _DCID}, Sent, _Size, State) ->
    record_one_sent(Now, Sent#{ack_eliciting := false}, State);
path_sent(Now, probe, Sent, Size, #state{probe_path = {Addr, Seq, Amp}} = State) ->
    record_one_sent(Now, Sent#{ack_eliciting := false}, State#state{
        probe_path = {Addr, Seq, roadrunner_quic_amp:sent(Size, Amp)}
    }).

%% Reassemble CRYPTO, deframe complete handshake messages, and drive the
%% TLS sequencer. A frame reaching more than ?CRYPTO_BUFFER_LIMIT bytes past
%% what TLS has consumed (the delivered prefix less the bytes still waiting
%% to deframe) would make us hold that much, out of order or as one
%% unfinished message: close with CRYPTO_BUFFER_EXCEEDED (RFC 9000 §7.5).
-spec process_crypto(level(), non_neg_integer(), binary(), t()) -> t().
process_crypto(Level, Offset, Data, State) ->
    #space{crypto = Crypto0, crypto_in = CryptoIn} = Space = space(Level, State),
    Consumed = roadrunner_quic_stream:recv_offset(Crypto0) - byte_size(CryptoIn),
    case Offset + byte_size(Data) - Consumed of
        Held when Held > ?CRYPTO_BUFFER_LIMIT ->
            connection_fatal(Level, crypto_buffer_exceeded, State);
        _ ->
            reassemble_crypto(Level, Offset, Data, Space, State)
    end.

-spec reassemble_crypto(level(), non_neg_integer(), binary(), #space{}, t()) -> t().
reassemble_crypto(Level, Offset, Data, Space, State) ->
    {ok, NewBytes, _Fin, Crypto} = roadrunner_quic_stream:receive_data(
        Offset, Data, false, Space#space.crypto
    ),
    Buffer = <<(Space#space.crypto_in)/binary, NewBytes/binary>>,
    {Messages, Rest} = deframe(Buffer),
    State1 = put_space(Level, Space#space{crypto = Crypto, crypto_in = Rest}, State),
    lists:foldl(
        fun(Message, S) -> process_handshake_message(Level, Message, S) end, State1, Messages
    ).

%% A handshake message that closed the connection ends the fold: the messages
%% after it in the same CRYPTO data are not processed (RFC 9000 §10.2), so a
%% Finished behind a fatal message cannot confirm the handshake.
-spec process_handshake_message(level(), {byte(), binary()}, t()) -> t().
process_handshake_message(_Level, _Message, #state{phase = Phase} = State) when
    Phase =:= closed; Phase =:= draining
->
    State;
process_handshake_message(Level, Message, State) ->
    process_handshake(Level, Message, State).

%% Decode every complete handshake message, leaving trailing partial bytes.
-spec deframe(binary()) -> {[{byte(), binary()}], binary()}.
deframe(Buffer) ->
    case roadrunner_quic_tls_handshake:decode(Buffer) of
        {ok, {Type, Body}, Rest} ->
            {More, Tail} = deframe(Rest),
            {[{Type, Body} | More], Tail};
        {more, _} ->
            {[], Buffer}
    end.

-spec process_handshake(level(), {byte(), binary()}, t()) -> t().
process_handshake(
    initial,
    {?CLIENT_HELLO, Body},
    #state{tls = Tls, info = #{transport_params := #{initial_max_data := OurMaxData} = OurParams}} =
        State
) ->
    case roadrunner_quic_tls_server:process_client_hello(Body, Tls) of
        {ok, #{initial := InitialFlight, handshake := HandshakeFlight}, Installs, PeerParams, Tls1} ->
            %% Seed the connection send window from the client's advertised
            %% initial_max_data (absent -> 0, RFC 9000 §18.2), not a default. Safe
            %% to re-create conn_flow here: no 1-RTT data flows before the
            %% handshake completes.
            ConnFlow = roadrunner_quic_flow:new(#{
                initial_max_data => OurMaxData,
                peer_initial_max_data => maps:get(initial_max_data, PeerParams, 0)
            }),
            %% Lower the idle timeout to the negotiated minimum (RFC 9000 §10.1)
            %% now that the peer's advertised value is known.
            IdleTimeout = negotiated_idle_timeout(OurParams, PeerParams),
            State1 = install_keys(
                Installs,
                State#state{
                    tls = Tls1,
                    peer_params = PeerParams,
                    %% The limit on the server's own unidirectional streams
                    %% (absent -> 0, RFC 9000 §18.2).
                    peer_max_streams_uni = maps:get(initial_max_streams_uni, PeerParams, 0),
                    conn_flow = ConnFlow,
                    idle_timeout = IdleTimeout
                }
            ),
            State2 = queue_crypto(initial, InitialFlight, State1),
            queue_crypto(handshake, HandshakeFlight, State2);
        {retry, HelloRetryRequest, Tls1} ->
            %% No usable key share: ask for one (RFC 8446 §4.1.4). The
            %% HelloRetryRequest goes out in Initial CRYPTO like a ServerHello
            %% (RFC 9001 §4.7), and the client's second ClientHello follows in
            %% the same Initial CRYPTO stream, landing back here.
            queue_crypto(initial, HelloRetryRequest, State#state{tls = Tls1});
        {error, Reason} ->
            connection_fatal(initial, Reason, State)
    end;
process_handshake(handshake, {?FINISHED, Body}, #state{tls = Tls} = State) ->
    case roadrunner_quic_tls_server:process_client_finished(Body, Tls) of
        ok ->
            %% Handshake confirmed: discard the Handshake space (RFC 9001
            %% §4.9.2), become connected, and send HANDSHAKE_DONE at the
            %% application level, with the spare connection ids the client
            %% may move to (RFC 9000 §5.1.1) and a token for its next
            %% connection (§8.1.3).
            State1 = discard_space(handshake, State#state{phase = connected}),
            queue_new_token(queue_frame(application, handshake_done, issue_cids(State1)));
        {error, Reason} ->
            connection_fatal(handshake, Reason, State)
    end;
process_handshake(Level, {_Type, _Body}, State) ->
    %% An out-of-sequence or unknown handshake message (RFC 8446 unexpected
    %% message); connection-fatal like the other handshake failures.
    connection_fatal(Level, unexpected_message, State).

%% Arm the keys derived from the traffic secrets the TLS flight produced
%% (RFC 9001 §5.1), for the negotiated suite's AEAD (§5.3): server secrets
%% protect outgoing packets, client secrets decrypt incoming ones; the
%% Application space appears with its keys. The 1-RTT secrets and the AEAD
%% are kept for key updates (§6.1), and the receive side gets the next
%% generation's keys at once (§6.3): they are ready before the peer's first
%% update, in key phase 0.
-spec install_keys([roadrunner_quic_tls_server:install()], t()) -> t().
install_keys(Installs, State) ->
    lists:foldl(fun install_key/2, State, Installs).

-spec install_key(roadrunner_quic_tls_server:install(), t()) -> t().
install_key({application, server, Aead, Secret}, State) ->
    install_send_keys(application, Aead, Secret, State#state{send_secret = Secret});
install_key({Level, server, Aead, Secret}, State) ->
    install_send_keys(Level, Aead, Secret, State);
install_key({application, client, Aead, Secret}, #state{recv_keys = RecvKeys} = State) ->
    Keys = connection_keys(Aead, Secret, open),
    {NextSecret, Next} = roadrunner_quic_keys:update(Aead, Secret),
    AppKeys = Keys#{phase => 0, next => roadrunner_quic_keys:for_connection(Next, open)},
    ensure_space(application, State#state{
        recv_keys = RecvKeys#{application => AppKeys}, recv_secret = NextSecret, aead = Aead
    });
install_key({Level, client, Aead, Secret}, #state{recv_keys = RecvKeys} = State) ->
    ensure_space(Level, State#state{
        recv_keys = RecvKeys#{Level => connection_keys(Aead, Secret, open)}
    }).

-spec install_send_keys(level(), roadrunner_quic_aead:cipher(), binary(), t()) -> t().
install_send_keys(Level, Aead, Secret, #state{send_keys = SendKeys} = State) ->
    ensure_space(Level, State#state{
        send_keys = SendKeys#{Level => connection_keys(Aead, Secret, seal)}
    }).

%% A traffic secret's packet-protection keys for an AEAD, prepared for this
%% process.
-spec connection_keys(roadrunner_quic_aead:cipher(), binary(), seal | open) ->
    roadrunner_quic_keys:keys().
connection_keys(Aead, Secret, Direction) ->
    roadrunner_quic_keys:for_connection(
        roadrunner_quic_keys:traffic_keys(Aead, Secret), Direction
    ).

-spec ensure_space(level(), t()) -> t().
ensure_space(Level, #state{spaces = Spaces} = State) ->
    case Spaces of
        #{Level := _} -> State;
        #{} -> State#state{spaces = Spaces#{Level => new_space()}}
    end.

%% Forget a packet-number space and its keys (RFC 9001 §4.9).
-spec discard_space(level(), t()) -> t().
discard_space(Level, #state{spaces = Spaces, recv_keys = RK, send_keys = SK} = State) ->
    State#state{
        spaces = maps:remove(Level, Spaces),
        recv_keys = maps:remove(Level, RK),
        send_keys = maps:remove(Level, SK)
    }.

%% Buffer outbound CRYPTO bytes for a level (sent as CRYPTO frames).
-spec queue_crypto(level(), iolist(), t()) -> t().
queue_crypto(Level, Bytes, State) ->
    Space = space(Level, State),
    put_space(
        Level,
        Space#space{crypto = roadrunner_quic_stream:enqueue(Bytes, Space#space.crypto)},
        State
    ).

%% Queue a control frame to send at a level. The pending list is flushed into
%% one packet wholesale and frame order within a packet is irrelevant, so a
%% frame is consed on rather than appended.
-spec queue_frame(level(), roadrunner_quic_frame:frame(), t()) -> t().
queue_frame(Level, Frame, State) ->
    Space = space(Level, State),
    put_space(Level, Space#space{pending = [Frame | Space#space.pending]}, State).

-spec process_ack(integer(), level(), tuple(), t()) -> t().
process_ack(Now, Level, {ack, Largest, _, _, _, _} = Ack, State) ->
    case space(Level, State) of
        #space{next_pn = NextPN} when Largest >= NextPN ->
            %% RFC 9000 §13.1: an ACK for a packet never sent in this space.
            connection_fatal(Level, protocol_violation, State);
        Space ->
            ack_of_send_phase(Now, Level, Largest, apply_ack(Now, Level, Ack, Space, State))
    end.

-spec apply_ack(integer(), level(), tuple(), #space{}, t()) -> t().
apply_ack(Now, Level, Ack, Space, #state{cc = Cc} = State) ->
    case roadrunner_quic_loss:on_ack_received(Ack, Now, Space#space.loss) of
        {error, negative_ack_range} ->
            %% RFC 9000 §19.3.1: a range reaching below packet number 0.
            connection_fatal(Level, frame_encoding_error, State);
        {Loss, _Acked, Lost} ->
            Cc1 = apply_cc_signal(roadrunner_quic_loss:cc_signal(Loss), Now, Cc),
            put_space(
                Level,
                Space#space{
                    loss = Loss,
                    pending = lists:reverse(retransmittable(Lost, State), Space#space.pending)
                },
                State#state{cc = Cc1}
            )
    end.

%% Feed the loss layer's congestion signal to NewReno in the RFC 9002 Appendix
%% A.7 order: react to any loss first (a congestion event, Appendix B.8, then
%% the collapse to the minimum window on persistent congestion, §7.6.2), then
%% grow the window for the acknowledged bytes. Loss first means an ACK that both
%% acknowledges and reveals loss holds the window for the packets sent before
%% the new recovery period, while persistent congestion ends recovery so the
%% same ACK grows the collapsed window in slow start. A defined largest-acked
%% send time means the largest acked was ack-eliciting, so the acked bytes are
%% positive; `undefined` (nothing newly acked, a non-ack-eliciting largest, or
%% a timer pass) skips the growth.
-spec apply_cc_signal(roadrunner_quic_loss:cc_signal(), integer(), roadrunner_quic_cc_newreno:t()) ->
    roadrunner_quic_cc_newreno:t().
apply_cc_signal(
    #{
        acked_bytes := AckedBytes,
        largest_acked_time := AckedTime,
        largest_lost_time := LostTime,
        persistent_congestion := Persistent
    },
    Now,
    Cc
) ->
    Reduced =
        case LostTime of
            undefined -> Cc;
            _ -> roadrunner_quic_cc_newreno:on_congestion_event(LostTime, Now, Cc)
        end,
    Collapsed =
        case Persistent of
            true -> roadrunner_quic_cc_newreno:on_persistent_congestion(Reduced);
            false -> Reduced
        end,
    case AckedTime of
        undefined -> Collapsed;
        _ -> roadrunner_quic_cc_newreno:on_packets_acked(AckedBytes, AckedTime, Collapsed)
    end.

%% =============================================================================
%% Application streams (peer-initiated, receive side)
%% =============================================================================

%% Reassemble a peer STREAM frame, charging the increase in its highest
%% received offset against the connection and per-stream receive windows
%% (RFC 9000 §4.1), so retransmitted or overlapping bytes never re-consume
%% the window. A STREAM frame on a server-initiated id is the peer writing to
%% a stream it cannot send on (RFC 9000 §19.8). A flow-control overrun, a
%% final-size violation, or that stream-state error is a peer-reachable
%% connection error: it closes the connection gracefully via connection_fatal/2
%% ({closed, {local, Reason}}), not a crash (transmitting a CONNECTION_CLOSE to
%% the peer is a later slice). Emits {stream_opened, Sid} on a peer stream's
%% first frame and {stream_data, Sid,
%% Bin, Fin} (including the FIN-only {<<>>, true}). Granting more credit
%% (MAX_DATA / MAX_STREAM_DATA) and seeding the windows from the advertised
%% transport parameters are send-side follow-ups.
-spec process_stream(non_neg_integer(), non_neg_integer(), binary(), boolean(), t()) -> t().
process_stream(Sid, _Offset, _Data, _Fin, State) when Sid rem 4 =:= 1; Sid rem 4 =:= 3 ->
    connection_fatal(application, stream_state_error, State);
process_stream(Sid, _Offset, _Data, _Fin, #state{max_streams_bidi = Max} = State) when
    Sid rem 4 =:= 0, Sid div 4 >= Max
->
    connection_fatal(application, stream_limit_error, State);
process_stream(Sid, _Offset, _Data, _Fin, #state{max_streams_uni = Max} = State) when
    Sid rem 4 =:= 2, Sid div 4 >= Max
->
    connection_fatal(application, stream_limit_error, State);
process_stream(Sid, Offset, Data, Fin, State) ->
    case ensure_stream(Sid, State) of
        closed ->
            %% Late/reordered STREAM frame for a pruned stream (RFC 9000 §3): the
            %% packet is still acknowledged, but the frame is ignored.
            State;
        {ok, Stream0, StreamFlow0, State1} ->
            #state{conn_flow = ConnFlow} = State1,
            Delta = max(
                0, Offset + byte_size(Data) - roadrunner_quic_flow:bytes_received(StreamFlow0)
            ),
            maybe
                {ok, ConnFlow1} ?= roadrunner_quic_flow:on_data_received(Delta, ConnFlow),
                {ok, StreamFlow1} ?= roadrunner_quic_flow:on_data_received(Delta, StreamFlow0),
                {ok, Deliverable, FinReached, Stream1} ?=
                    roadrunner_quic_stream:receive_data(Offset, Data, Fin, Stream0),
                {ConnFlow2, State2} = grant_conn_credit(ConnFlow1, State1),
                {StreamFlow2, State3} = grant_stream_credit(Sid, StreamFlow1, State2),
                State4 = put_stream(Sid, Stream1, StreamFlow2, State3#state{conn_flow = ConnFlow2}),
                deliver_stream(Sid, Deliverable, FinReached, State4)
            else
                {error, Reason} -> connection_fatal(application, Reason, State)
            end
    end.

%% Refill the connection-level receive window as the peer consumes it (RFC 9000
%% §4.1): once more than the refill threshold is used, advertise a fresh window
%% with a MAX_DATA frame so a large upload keeps flowing instead of stalling at
%% the initial grant.
-spec grant_conn_credit(roadrunner_quic_flow:t(), t()) -> {roadrunner_quic_flow:t(), t()}.
grant_conn_credit(ConnFlow, State) ->
    case roadrunner_quic_flow:should_send_max_data(ConnFlow) of
        true ->
            {NewMax, ConnFlow1} = roadrunner_quic_flow:grant_max_data(ConnFlow),
            {ConnFlow1, queue_frame(application, {max_data, NewMax}, State)};
        false ->
            {ConnFlow, State}
    end.

%% Refill a stream's receive window the same way, with MAX_STREAM_DATA.
-spec grant_stream_credit(non_neg_integer(), roadrunner_quic_flow:t(), t()) ->
    {roadrunner_quic_flow:t(), t()}.
grant_stream_credit(Sid, StreamFlow, State) ->
    case roadrunner_quic_flow:should_send_max_data(StreamFlow) of
        true ->
            {NewMax, StreamFlow1} = roadrunner_quic_flow:grant_max_data(StreamFlow),
            {StreamFlow1, queue_frame(application, {max_stream_data, Sid, NewMax}, State)};
        false ->
            {StreamFlow, State}
    end.

%% A RESET_STREAM aborts the peer's send side and surfaces the abort code. On
%% a server-initiated id it is the peer resetting a stream it cannot send on
%% (RFC 9000 §19.4 STREAM_STATE_ERROR).
-spec process_reset_stream(non_neg_integer(), non_neg_integer(), non_neg_integer(), t()) -> t().
process_reset_stream(Sid, _ErrorCode, _FinalSize, State) when Sid rem 4 =:= 1; Sid rem 4 =:= 3 ->
    connection_fatal(application, stream_state_error, State);
process_reset_stream(Sid, _ErrorCode, _FinalSize, #state{max_streams_bidi = Max} = State) when
    Sid rem 4 =:= 0, Sid div 4 >= Max
->
    connection_fatal(application, stream_limit_error, State);
process_reset_stream(Sid, _ErrorCode, _FinalSize, #state{max_streams_uni = Max} = State) when
    Sid rem 4 =:= 2, Sid div 4 >= Max
->
    connection_fatal(application, stream_limit_error, State);
process_reset_stream(Sid, ErrorCode, FinalSize, State) ->
    case ensure_stream(Sid, State) of
        closed ->
            %% Late/reordered RESET_STREAM for a pruned stream (RFC 9000 §3).
            State;
        {ok, Stream0, Flow, State1} ->
            case roadrunner_quic_stream:reset(FinalSize, Stream0) of
                {ok, Stream1} ->
                    emit({stream_reset, Sid, ErrorCode}, put_stream(Sid, Stream1, Flow, State1));
                {error, Reason} ->
                    connection_fatal(application, Reason, State)
            end
    end.

%% Peer STOP_SENDING (RFC 9000 §3.5): the peer will not read more of our
%% response on this stream. Abandon our send side — `stop_sending/1` discards
%% the unsent buffer and marks the stream send-stopped, so a parked send reply
%% releases with `{error, closed}` (via `release_drained/1` at the end of this
%% datagram) instead of `ok` — and surface it to the owner as a stream reset so
%% a response worker stops (reusing the reset routing) rather than buffering more
%% onto a stopped stream. A frame for a stream we hold no send state for is
%% ignored, like a late RESET_STREAM.
-spec process_stop_sending(non_neg_integer(), non_neg_integer(), t()) -> t().
process_stop_sending(Sid, ErrorCode, #state{streams = Streams} = State) ->
    case Streams of
        #{Sid := {Stream0, Flow}} ->
            Stream1 = roadrunner_quic_stream:stop_sending(Stream0),
            State1 = put_stream(Sid, Stream1, Flow, State),
            emit({stream_reset, Sid, ErrorCode}, State1);
        #{} ->
            State
    end.

%% A well-placed peer CONNECTION_CLOSE (transport at any level, or application
%% at 1-RTT) ends the connection: surface it to the owner and move to the
%% terminal phase so the send pass is skipped. An established connection lingers
%% in `draining` (closing_phase/1) to absorb the peer's reordered 1-RTT packets;
%% a handshake-phase close ends at once.
-spec process_close(non_neg_integer(), t()) -> t().
process_close(ErrorCode, State) ->
    emit({closed, {peer, ErrorCode}}, State#state{phase = closing_phase(State)}).

%% Close this single, isolated connection on a peer-reachable protocol error
%% (flow control §4.1, final size §4.5, stream state §19.8, an out-of-place
%% application CONNECTION_CLOSE §19.19, or a failed TLS handshake): record a
%% CONNECTION_CLOSE to transmit at the triggering packet's level (Level), move to
%% the terminal phase so the fold short-circuits and the shell tears down cleanly
%% (no crash, no slot leak), and surface a terminal {closed, {local, Reason}} to
%% the owner. An established connection lingers in `draining` (closing_phase/1).
-spec connection_fatal(level(), atom(), t()) -> t().
connection_fatal(Level, Reason, State) ->
    State1 = State#state{
        phase = closing_phase(State),
        pending_close = {close_level(Level, State), close_code(Reason)}
    },
    emit({closed, {local, Reason}}, State1).

%% The level to send a CONNECTION_CLOSE at: the triggering packet's, except
%% once the handshake is confirmed, when it MUST be 1-RTT (RFC 9000 §10.2.3);
%% the Handshake keys are gone by then.
-spec close_level(level(), t()) -> level().
close_level(_Level, #state{phase = connected}) -> application;
close_level(Level, _State) -> Level.

%% The terminal phase a close moves to (RFC 9000 §10.2): an established
%% connection lingers in `draining` for 3x PTO so the peer's reordered 1-RTT
%% packets are absorbed before its connection id is freed; a close during the
%% handshake has no 1-RTT packets to absorb, so it ends immediately (and a
%% handshake flood cannot accrue lingering draining connections).
-spec closing_phase(t()) -> phase().
closing_phase(#state{phase = connected}) -> draining;
closing_phase(_State) -> closed.

%% The absolute time the drain window ends: three PTOs from now (RFC 9000 §10.2),
%% the largest across the still-present spaces.
-spec drain_deadline(integer(), t()) -> integer().
drain_deadline(Now, State) ->
    Now + 3 * max_pto(State).

-spec max_pto(t()) -> non_neg_integer().
max_pto(#state{spaces = Spaces}) ->
    maps:fold(
        fun(_Level, #space{loss = Loss}, Acc) -> max(Acc, roadrunner_quic_loss:get_pto(Loss)) end,
        0,
        Spaces
    ).

%% Map a connection-error reason to its CONNECTION_CLOSE wire error code: a TLS
%% handshake failure becomes a CRYPTO_ERROR (RFC 9001 §4.8: 0x0100 + alert), a
%% transport error maps directly (RFC 9000 §20).
-spec close_code(atom()) -> non_neg_integer().
close_code(Reason) when
    Reason =:= flow_control_error;
    Reason =:= final_size_error;
    Reason =:= stream_state_error;
    Reason =:= stream_limit_error;
    Reason =:= protocol_violation;
    Reason =:= crypto_buffer_exceeded;
    Reason =:= frame_encoding_error;
    Reason =:= transport_parameter_error;
    Reason =:= key_update_error;
    Reason =:= aead_limit_reached;
    Reason =:= connection_id_limit_error
->
    roadrunner_quic_error:code_int(Reason);
close_code(unexpected_message) ->
    %% A handshake message TLS does not expect where it arrived, such as a
    %% KeyUpdate (RFC 9001 §6: 0x010a) or an EndOfEarlyData, which QUIC
    %% removes (§8.3): the TLS unexpected_message alert (10).
    roadrunner_quic_error:code_int({crypto_error, 10});
close_code(Reason) when Reason =:= missing_transport_params; Reason =:= missing_extension ->
    %% RFC 9001 §8.2: a ClientHello without the quic_transport_parameters
    %% extension MUST close with 0x016d, a CRYPTO_ERROR carrying the TLS
    %% missing_extension alert (109); so does one without supported_groups or
    %% key_share (RFC 8446 §9.2).
    roadrunner_quic_error:code_int({crypto_error, 109});
close_code(illegal_parameter) ->
    %% A key share that is not a valid public value for its group (RFC 8446
    %% §4.2.8.2), or a second ClientHello that does not answer the
    %% HelloRetryRequest (§4.1.2): the TLS illegal_parameter alert (47).
    roadrunner_quic_error:code_int({crypto_error, 47});
close_code(protocol_version) ->
    %% A ClientHello that does not offer TLS 1.3 (RFC 8446 §4.2.1, RFC 9001
    %% §4.2): the TLS protocol_version alert (70).
    roadrunner_quic_error:code_int({crypto_error, 70});
close_code(_TlsReason) ->
    %% Every other connection_fatal reason is a TLS handshake failure (a
    %% malformed or rejected ClientHello, a bad Finished, or an unexpected
    %% message); RFC 9001 §4.8 carries these as CRYPTO_ERROR (0x0100 + alert).
    %% TLS alert 40 (handshake_failure); a per-alert mapping is a refinement.
    roadrunner_quic_error:code_int({crypto_error, 40}).

%% Build and send exactly one CONNECTION_CLOSE at the recorded level (the
%% triggering packet's level, which the peer can decrypt), advancing that
%% space's packet number. Only the close travels (RFC 9000 §10.2.3); no other
%% queued frame is drained. The close always fits the §8.1 budget: it answers a
%% received packet, so 3x bytes-received covers a <=1200-byte close.
-spec send_close(t()) -> {t(), [effect()]}.
send_close(
    #state{pending_close = {Level, ErrorCode}, peer_scid = DCID, scid = SCID, amp = Amp} = State
) ->
    Space = space(Level, State),
    PN = Space#space.next_pn,
    Frame = {connection_close, transport, ErrorCode, 0, <<>>},
    Entry = #{Level => entry(Level, [Frame], PN, State)},
    {Datagram, _Sent} = roadrunner_quic_send:datagram(Entry, DCID, SCID),
    case roadrunner_quic_amp:can_send(byte_size(Datagram), Amp) of
        false ->
            %% An Initial close is padded to 1200; for an undersized or spoofed
            %% peer Initial that would exceed the §8.1 3x budget, so drop it
            %% (no amplification reflector). The connection still closes and the
            %% owner still learns via the {closed, _} emit, same as a silent
            %% close.
            {State, []};
        true ->
            Amp1 = roadrunner_quic_amp:sent(byte_size(Datagram), Amp),
            State1 = put_space(Level, Space#space{next_pn = PN + 1}, State#state{amp = Amp1}),
            {State1, [{send, Datagram}]}
    end.

%% Look up a peer stream and return `{ok, Stream, Flow, State}`: an existing
%% entry, or a fresh one for a genuinely new id (announced with
%% {stream_opened, Sid}). A first frame of a new id advances the per-type
%% high-water; an id at or below the high-water that is no longer tracked was
%% opened and pruned, so `closed` is returned and the frame ignored (RFC 9000
%% §3). Server-initiated ids never reach here (rejected upstream).
-spec ensure_stream(non_neg_integer(), t()) ->
    {ok, roadrunner_quic_stream:t(), roadrunner_quic_flow:t(), t()} | closed.
ensure_stream(Sid, #state{streams = Streams, skipped = Skipped} = State) ->
    case Streams of
        #{Sid := {Stream, Flow}} ->
            {ok, Stream, Flow, State};
        #{} when is_map_key(Sid, Skipped) ->
            open_stream(Sid, State#state{skipped = maps:remove(Sid, Skipped)});
        #{} ->
            case opened_before(Sid, State) of
                true -> closed;
                false -> open_stream(Sid, State)
            end
    end.

%% Whether `Sid`'s ordinal is below the per-type high-water: it was opened
%% earlier and, since it is no longer in `streams`, has been pruned.
-spec opened_before(non_neg_integer(), t()) -> boolean().
opened_before(Sid, #state{bidi_opened = Opened}) when Sid rem 4 =:= 0 ->
    Sid div 4 < Opened;
opened_before(Sid, #state{uni_opened = Opened}) ->
    Sid div 4 < Opened.

%% Create a fresh peer stream, advance the per-type high-water past its ordinal,
%% and announce it with {stream_opened, Sid}.
-spec open_stream(non_neg_integer(), t()) ->
    {ok, roadrunner_quic_stream:t(), roadrunner_quic_flow:t(), t()}.
open_stream(
    Sid,
    #state{info = #{transport_params := TP}, peer_params = PeerParams, stream_credit = Credit} =
        State
) ->
    Stream = roadrunner_quic_stream:new(),
    Flow = roadrunner_quic_flow:new(#{
        initial_max_data => stream_recv_window(Sid, TP),
        peer_initial_max_data => peer_stream_send_window(Sid, PeerParams)
    }),
    {ok, Stream, request_flow(Sid, Credit, Flow),
        emit({stream_opened, Sid}, bump_opened(Sid, State))}.

%% A client request stream (bidirectional) under `stream_credit => on_read`
%% grants its credit as the owner consumes its data.
-spec request_flow(non_neg_integer(), on_receipt | on_read, roadrunner_quic_flow:t()) ->
    roadrunner_quic_flow:t().
request_flow(Sid, on_read, Flow) when Sid rem 4 =:= 0 ->
    roadrunner_quic_flow:hold(Flow);
request_flow(_Sid, _Credit, Flow) ->
    Flow.

%% The send window for a stream the server writes to: the limit the client
%% advertised for that stream type (RFC 9000 §18.2; absent -> 0). A
%% client-initiated bidi (request) stream where the server sends the response
%% uses initial_max_stream_data_bidi_local; a server-initiated uni (control /
%% QPACK) stream uses initial_max_stream_data_uni. A client uni stream is
%% receive-only for the server, so 0.
-spec peer_stream_send_window(non_neg_integer(), roadrunner_quic_transport_params:params()) ->
    non_neg_integer().
peer_stream_send_window(Sid, PeerParams) when Sid rem 4 =:= 0 ->
    maps:get(initial_max_stream_data_bidi_local, PeerParams, 0);
peer_stream_send_window(Sid, PeerParams) when Sid rem 4 =:= 3 ->
    maps:get(initial_max_stream_data_uni, PeerParams, 0);
peer_stream_send_window(_Sid, _PeerParams) ->
    0.

%% The effective idle timeout (RFC 9000 §10.1): the minimum of the two advertised
%% max_idle_timeout values, or the only non-zero one. A zero or absent value on a
%% side means "no limit from me"; with neither side advertising one we fall back
%% to ?IDLE_TIMEOUT so a dead peer cannot pin the connection open.
-spec negotiated_idle_timeout(
    roadrunner_quic_transport_params:params(), roadrunner_quic_transport_params:params()
) -> non_neg_integer().
negotiated_idle_timeout(OurParams, PeerParams) ->
    Ours = maps:get(max_idle_timeout, OurParams, 0),
    Peer = maps:get(max_idle_timeout, PeerParams, 0),
    case {Ours, Peer} of
        {0, 0} -> ?IDLE_TIMEOUT;
        {0, P} -> P;
        {O, 0} -> O;
        {O, P} -> min(O, P)
    end.

%% Advance the per-type high-water past `Sid`'s ordinal, recording any ids it
%% jumps over as skipped (still to open). Opening a bidi stream also tops up
%% the peer's bidi-stream credit.
-spec bump_opened(non_neg_integer(), t()) -> t().
bump_opened(Sid, #state{bidi_opened = Opened} = State) when Sid rem 4 =:= 0 ->
    grant_max_streams_bidi(
        skip_below(Sid, Opened, State#state{bidi_opened = max(Opened, Sid div 4 + 1)})
    );
bump_opened(Sid, #state{uni_opened = Opened} = State) ->
    skip_below(Sid, Opened, State#state{uni_opened = max(Opened, Sid div 4 + 1)}).

%% Record the ids of `Sid`'s type from ordinal `Opened` up to (not including)
%% `Sid`'s own as skipped. A stream at or below the high-water (the next one,
%% or a skipped one opening late) leaves no gap.
-spec skip_below(non_neg_integer(), non_neg_integer(), t()) -> t().
skip_below(Sid, Opened, #state{skipped = Skipped} = State) when Sid div 4 > Opened ->
    Gap = [Ordinal * 4 + Sid rem 4 || Ordinal <- lists:seq(Opened, Sid div 4 - 1)],
    State#state{skipped = maps:merge(Skipped, maps:from_keys(Gap, true))};
skip_below(_Sid, _Opened, State) ->
    State.

%% Keep the peer in bidi-stream credit (RFC 9000 §4.6): once the opened count is
%% within a quarter-window of the advertised limit, raise the limit to a fresh
%% window above what is opened and queue a MAX_STREAMS so the peer can keep
%% opening request streams. Mirrors the receive-flow MAX_DATA refill
%% (`roadrunner_quic_flow`, the 3/4 threshold); the window is the originally
%% advertised `initial_max_streams_bidi`.
-spec grant_max_streams_bidi(t()) -> t().
grant_max_streams_bidi(
    #state{
        bidi_opened = Opened,
        max_streams_bidi = Max,
        info = #{transport_params := #{initial_max_streams_bidi := Window}}
    } = State
) ->
    case Opened > Max - Window * 3 div 4 of
        true ->
            NewMax = Opened + Window,
            queue_frame(
                application, {max_streams, bidi, NewMax}, State#state{max_streams_bidi = NewMax}
            );
        false ->
            State
    end.

%% Our advertised receive window for a stream by type (RFC 9000 §18.2):
%% client-initiated bidirectional streams (Sid rem 4 == 0) get
%% initial_max_stream_data_bidi_remote; every other type gets
%% initial_max_stream_data_uni. The receive path passes only client-initiated
%% ids; the send path (stream_for_send) also passes server uni ids, where the
%% receive window is moot since the server never receives there.
-spec stream_recv_window(non_neg_integer(), roadrunner_quic_transport_params:params()) ->
    non_neg_integer().
stream_recv_window(Sid, #{initial_max_stream_data_bidi_remote := Bidi}) when Sid rem 4 =:= 0 ->
    Bidi;
stream_recv_window(_Sid, #{initial_max_stream_data_uni := Uni}) ->
    Uni.

-spec put_stream(non_neg_integer(), roadrunner_quic_stream:t(), roadrunner_quic_flow:t(), t()) ->
    t().
put_stream(Sid, Stream, Flow, #state{streams = Streams, sendable = Sendable} = State) ->
    %% The single writer of `streams`. A fully-terminal stream (both directions
    %% finished) is pruned so the map stays bounded to live streams; the
    %% high-water keeps a late frame for its id from recreating it. Otherwise it
    %% is stored and the `sendable` working set kept in step (unsent data/FIN
    %% joins it, a drained one leaves it). An abandoned send side (peer
    %% RESET_STREAM left `aborted`, or STOP_SENDING / local reset set
    %% `send_stopped`) leaves `sendable` even with buffered bytes, so the send
    %% pass never emits STREAM frames on a stream the peer reset.
    case roadrunner_quic_stream:is_terminal(Stream) of
        true ->
            State#state{
                streams = maps:remove(Sid, Streams),
                sendable = ordsets:del_element(Sid, Sendable)
            };
        false ->
            Sendable1 =
                case
                    roadrunner_quic_stream:send_pending(Stream) andalso
                        not roadrunner_quic_stream:send_abandoned(Stream)
                of
                    true -> ordsets:add_element(Sid, Sendable);
                    false -> ordsets:del_element(Sid, Sendable)
                end,
            State#state{streams = Streams#{Sid => {Stream, Flow}}, sendable = Sendable1}
    end.

%% Emit {stream_data, ...} when there are newly-contiguous bytes OR the FIN
%% was reached (the FIN-only {<<>>, true} end-of-stream the h3 layer needs).
-spec deliver_stream(non_neg_integer(), binary(), boolean(), t()) -> t().
deliver_stream(Sid, Deliverable, FinReached, State) when Deliverable =/= <<>>; FinReached ->
    emit({stream_data, Sid, Deliverable, FinReached}, State);
deliver_stream(_Sid, _Deliverable, _FinReached, State) ->
    State.

%% =============================================================================
%% Outbound send pass
%% =============================================================================

-spec send_pass(integer(), t()) -> {t(), [effect()]}.
send_pass(Now, #state{phase = Before} = State) ->
    case drain_send(Now, State, []) of
        {#state{phase = Before} = State1, RevSends} ->
            %% Release any parked send reply whose stream drained (or was
            %% aborted) this pass. The release effects ride AFTER the reversed
            %% sends so the bytes are on the wire before the worker is told it
            %% may send more (`perform/3` folds effects left-to-right). This is
            %% the single choke point: every flow / congestion relief
            %% (MAX_STREAM_DATA, MAX_DATA, an ACK growing cwnd) runs in the
            %% datagram fold before `finish_datagram` calls `send_pass`, so the
            %% scan here catches them all.
            {State2, Releases} = release_drained(State1),
            %% `drain_send` returns the send effects newest-first; reverse them
            %% into order and fold the releases + the (single) timer effect
            %% (or a graceful close) onto the end in the same pass, rather than
            %% a second traversal to append them.
            {State3, Tail} = pass_tail(Now, State2),
            {State3, lists:reverse(RevSends, Releases ++ Tail)};
        {State1, RevSends} ->
            %% The send keys reached the confidentiality limit with no key
            %% update allowed (`key_limit/3`): the connection closed mid-pass.
            %% The close goes out after what the pass already sent, as it
            %% would for a close found while folding a datagram.
            {State2, Effects} = finish_datagram(Now, Before, State1),
            {State2, lists:reverse(RevSends, Effects)}
    end.

%% What follows a send pass's sends: the (single) timer effect, or, when the
%% owner asked for a graceful close and the last response just went out, the
%% CONNECTION_CLOSE with its drain timer and the `{closed, drained}` that
%% tells the owner the close happened. The parked replies are all released
%% by then: a parked stream holds unsent bytes, so it holds the close too.
-spec pass_tail(integer(), t()) -> {t(), [effect()]}.
pass_tail(_Now, #state{close_when_done = undefined} = State) ->
    {State, timer_effects(State)};
pass_tail(Now, #state{close_when_done = {ErrorCode, Reason}, owner = Owner} = State) ->
    case responses_done(State) of
        true ->
            {State1, CloseEffects} = send_owner_close(
                ErrorCode, Reason, Now, State#state{close_when_done = undefined}
            ),
            {State1, CloseEffects ++ [{emit, Owner, {closed, drained}}]};
        false ->
            {State, timer_effects(State)}
    end.

%% Every response is delivered: no stream holds unsent bytes or an unsent FIN
%% (the `sendable` set, so bytes flow control holds back keep the connection
%% open, the owner's own control-stream GOAWAY among them), no client request
%% stream (RFC 9000 §2.1: `Sid rem 4 =:= 0`) the peer started still waits on
%% our FIN, and the peer has acknowledged everything sent, with nothing lost
%% left to resend. A CONNECTION_CLOSE ends retransmission (RFC 9000 §10.2),
%% so closing once the last FIN is only sent would cut short a response whose
%% last packet is lost; a graceful shutdown lets requests complete (RFC 9114
%% §5.2). A response whose final write is still on its way to this
%% connection leaves its stream waiting, so a close never overtakes it. A
%% stream reset by either side waits on nothing (`send_owed/1`). A peer that
%% never acknowledges is bounded by the listener's drain deadline.
-spec responses_done(t()) -> boolean().
responses_done(#state{sendable = [], streams = Streams} = State) ->
    all_acknowledged(space(application, State)) andalso
        no_response_owed(maps:next(maps:iterator(Streams)));
responses_done(#state{}) ->
    false.

%% Nothing ack-eliciting the peer has yet to acknowledge, and nothing found
%% lost waiting to go out again (after a send pass, only the
%% anti-amplification limit of a path being validated can hold it back).
-spec all_acknowledged(#space{}) -> boolean().
all_acknowledged(#space{pending = Pending, loss = Loss}) ->
    Pending =:= [] andalso roadrunner_quic_loss:bytes_in_flight(Loss) =:= 0.

-spec no_response_owed(none | {non_neg_integer(), stream(), maps:iterator()}) -> boolean().
no_response_owed(none) ->
    true;
no_response_owed({Sid, {Stream, _Flow}, Iter}) ->
    case Sid rem 4 =:= 0 andalso roadrunner_quic_stream:send_owed(Stream) of
        true -> false;
        false -> no_response_owed(maps:next(Iter))
    end.

%% Release each parked reply whose stream can no longer make progress toward
%% draining: the stream is gone (pruned after its FIN flushed -> `ok`), its
%% send side was abandoned by a reset / STOP_SENDING (`send_abandoned/1` ->
%% `{error, closed}`, so a streaming worker does not treat the data as sent
%% and re-send to a dead stream), or it fully drained (`ok`). A stream still
%% holding unsent bytes stays parked. Each released entry is removed from
%% `parked`, so a later scan in the same datagram cannot double-reply.
-spec release_drained(t()) -> {t(), [effect()]}.
release_drained(#state{parked = Parked, streams = Streams} = State) ->
    {Parked1, Effects} = maps:fold(
        fun(Sid, {From, Ref}, {Acc, Eff}) ->
            case release_result(Sid, Streams) of
                keep -> {Acc#{Sid => {From, Ref}}, Eff};
                Result -> {Acc, [{reply, From, Ref, Result} | Eff]}
            end
        end,
        {#{}, []},
        Parked
    ),
    {State#state{parked = Parked1}, Effects}.

%% The reply value for a parked stream id, or `keep` to leave it parked.
-spec release_result(non_neg_integer(), #{non_neg_integer() => stream()}) ->
    ok | {error, closed} | keep.
release_result(Sid, Streams) ->
    case Streams of
        #{Sid := {Stream, _Flow}} ->
            case roadrunner_quic_stream:send_abandoned(Stream) of
                true ->
                    {error, closed};
                false ->
                    case roadrunner_quic_stream:send_pending(Stream) of
                        true -> keep;
                        false -> ok
                    end
            end;
        #{} ->
            %% Pruned (terminal: its FIN flushed) — the send completed.
            ok
    end.

%% Release every parked reply with `Result`, clearing the map. Used by the
%% connection-teardown paths (draining / closed / owner close / idle) that
%% skip `send_pass`, so a parked worker unblocks promptly instead of stalling
%% until its conn monitor fires on the eventual process exit.
-spec release_all(term(), t()) -> {t(), [effect()]}.
release_all(Result, #state{parked = Parked} = State) ->
    Effects = [{reply, From, Ref, Result} || {From, Ref} <- maps:values(Parked)],
    {State#state{parked = #{}}, Effects}.

%% Build and send one datagram per iteration until nothing is pending or
%% the anti-amplification budget blocks; roll back the built state if the
%% datagram cannot be sent. Returns the send effects newest-first (the caller
%% reverses them and adds the timer effect).
-spec drain_send(integer(), t(), [effect()]) -> {t(), [effect()]}.
drain_send(Now, State, Acc) ->
    %% The present encryption levels are invariant across a send burst (spaces
    %% are added or discarded only on the receive path), so resolve them once
    %% here rather than on every packet built in the loop.
    drain_send(Now, present_levels(State), State, Acc).

-spec drain_send(integer(), [level()], t(), [effect()]) -> {t(), [effect()]}.
drain_send(Now, Levels, #state{sealed = Sealed, phase = Phase} = State0, Acc) ->
    case key_limit(Sealed, Now, State0) of
        #state{phase = Phase} = State -> drain_built(Now, Levels, State, Acc);
        Closed -> {Closed, Acc}
    end.

-spec drain_built(integer(), [level()], t(), [effect()]) -> {t(), [effect()]}.
drain_built(Now, Levels, #state{path_out = [Path | Rest]} = State, Acc) ->
    %% A queued probing packet goes first, through the same key-limit check
    %% as every packet; it bypasses the congestion window, like a probe
    %% (RFC 9002 §7.5), so a path validation never waits on it.
    {State1, Acc1} = send_path(Now, Path, State#state{path_out = Rest}, Acc),
    drain_send(Now, Levels, State1, Acc1);
drain_built(Now, Levels, State, Acc) ->
    case build_first(Levels, Now, State) of
        none ->
            {State, Acc};
        {Entries, Built} ->
            #state{peer_scid = DCID, scid = SCID, amp = Amp, cc = Cc, probes = Probes} = State,
            {Datagram, Sent} = roadrunner_quic_send:datagram(Entries, DCID, SCID),
            %% Gate ack-eliciting datagrams on the congestion window (RFC 9002
            %% §7); ACK-only datagrams are not congestion-controlled and always
            %% pass, and so do the probes a probe timeout queued (§7.5). On a
            %% block, return the pre-build State so the consumed ACK / stream
            %% slice stays pending for the next pass.
            AckEliciting = lists:any(fun(#{ack_eliciting := Elicit}) -> Elicit end, Sent),
            CcOk =
                not AckEliciting orelse Probes > 0 orelse
                    roadrunner_quic_cc_newreno:can_send(total_bytes_in_flight(State), Cc),
            case {roadrunner_quic_amp:can_send(byte_size(Datagram) + reserve(State), Amp), CcOk} of
                {false, _} ->
                    %% The anti-amplification limit holds the datagram back
                    %% until the client sends more (RFC 9000 §8.1). An ACK it
                    %% carried still goes alone if that fits: a due ACK left
                    %% unsent keeps its deadline in the past, which would
                    %% re-arm the timer at once and starve the path
                    %% validation's own timer behind it.
                    send_ack_only(
                        Now, Levels, State#state{amp = roadrunner_quic_amp:block(Amp)}, Acc
                    );
                {true, false} ->
                    %% The window holds the data back, but not an ACK riding
                    %% with it: send that alone, or a peer waiting on it and a
                    %% probe timeout waiting behind its deadline both stall.
                    send_ack_only(Now, Levels, State, Acc);
                {true, true} ->
                    Recorded = record_sent(Now, Sent, Built),
                    Amp1 = roadrunner_quic_amp:sent(byte_size(Datagram), Amp),
                    Probes1 =
                        case AckEliciting of
                            true -> max(0, Probes - 1);
                            false -> Probes
                        end,
                    drain_send(
                        Now,
                        Levels,
                        Recorded#state{amp = Amp1, probes = Probes1},
                        [{send, Datagram} | Acc]
                    )
            end
    end.

%% Budget the anti-amplification limit keeps from data and ACKs on a path
%% still being validated (RFC 9000 §8.1): room for the challenges its
%% validation has yet to send and for those a client stranded by its failure
%% would draw (`rechallenge_stranded/1`). The limit grows only with what the
%% client sends, and a client that stops receiving stops sending: data
%% spending the whole budget would leave a lost challenge no retry and the
%% validation failing on one loss.
-spec reserve(t()) -> non_neg_integer().
reserve(#state{validation = #validation{sent = Sent}}) ->
    max(0, ?VALIDATION_CHALLENGES - length(Sent) + ?STRANDED_CHALLENGES) * ?BARE_CHALLENGE;
reserve(#state{}) ->
    0.

%% The ACK-only packet for the first level with an ACK due, sent while the
%% congestion window (RFC 9002 §7: ACK-only packets are not congestion
%% controlled) or the anti-amplification limit holds back the data it would
%% have carried. The limit still bounds the ACK alone (RFC 9000 §8.1 MUST).
-spec send_ack_only(integer(), [level()], t(), [effect()]) -> {t(), [effect()]}.
send_ack_only(Now, Levels, State, Acc) ->
    case build_ack_only(Levels, Now, State) of
        none ->
            {State, Acc};
        {Entries, Built} ->
            #state{peer_scid = DCID, scid = SCID, amp = Amp} = State,
            {Datagram, Sent} = roadrunner_quic_send:datagram(Entries, DCID, SCID),
            case roadrunner_quic_amp:can_send(byte_size(Datagram) + reserve(State), Amp) of
                true ->
                    Recorded = record_sent(Now, Sent, Built),
                    Amp1 = roadrunner_quic_amp:sent(byte_size(Datagram), Amp),
                    {Recorded#state{amp = Amp1}, [{send, Datagram} | Acc]};
                false ->
                    {State, Acc}
            end
    end.

-spec build_ack_only([level()], integer(), t()) -> none | {#{level() => map()}, t()}.
build_ack_only([], _Now, _State) ->
    none;
build_ack_only([Level | Rest], Now, State) ->
    #space{ack = Ack0} = Space = space(Level, State),
    case roadrunner_quic_ack:needs_ack(Ack0) andalso ack_due(Level, Now, Space) of
        true ->
            {AckFrames, Ack} = take_ack(Ack0, Now),
            {Entry, Built} = build_entry(Level, AckFrames, Space#space{ack = Ack}, State),
            {#{Level => Entry}, Built};
        false ->
            build_ack_only(Rest, Now, State)
    end.

%% Build ONE packet for the highest-priority present level that has
%% something to send, returned as a single-level datagram plus the
%% post-send state (CRYPTO popped, ACK marked sent, pending cleared,
%% next-PN advanced). Sending one level per datagram instead of coalescing
%% keeps every datagram within 1200 bytes: `roadrunner_quic_send` pads an
%% Initial up to 1200 but never caps, so a coalesced Initial+Handshake
%% flight would overflow. It also makes the forbidden Initial+1-RTT
%% coalescing structurally impossible. Coalescing Initial+Handshake is a
%% deferred optimization. Returns `none` when nothing is pending anywhere.
-spec build_first([level()], integer(), t()) -> none | {#{level() => map()}, t()}.
build_first([], _Now, _State) ->
    none;
build_first([Level | Rest], Now, State) ->
    case build_level(Level, Now, State) of
        none -> build_first(Rest, Now, State);
        {Entry, Built} -> {#{Level => Entry}, Built}
    end.

-spec build_level(level(), integer(), t()) -> none | {map(), t()}.
build_level(Level, Now, State) ->
    Space = space(Level, State),
    {AckFrames, Ack} = take_ack(Space#space.ack, Now),
    case Space#space.pending of
        [_ | _] = Pending ->
            %% Retransmits travel in their own packet (no fresh CRYPTO or
            %% STREAM slice). The frames of several lost packets, or one frame
            %% under a fresh ACK and a longer packet number, can outgrow a
            %% datagram, so the packet takes what fits and leaves the rest
            %% pending for the next one.
            #state{peer_scid = DCID, scid = SCID} = State,
            Room =
                roadrunner_quic_send:max_payload(Level, DCID, SCID, Space#space.next_pn) -
                    frames_size(AckFrames),
            {Frames, Rest} = fit_frames(Pending, Room),
            build_entry(
                Level, prepend_ack(AckFrames, Frames), Space#space{ack = Ack, pending = Rest}, State
            );
        [] ->
            build_data(Level, AckFrames, ack_due(Level, Now, Space), Space#space{ack = Ack}, State)
    end.

%% Take frames in order while they fit `Room` bytes. A STREAM or CRYPTO frame
%% that does not fit is split at a byte offset so the packet fills up, the
%% rest staying pending; any other frame waits whole for the next packet.
-spec fit_frames([roadrunner_quic_frame:frame()], integer()) ->
    {[roadrunner_quic_frame:frame()], [roadrunner_quic_frame:frame()]}.
fit_frames([Frame | Rest] = Frames, Room) ->
    case frames_size([Frame]) of
        Size when Size =< Room ->
            {Taken, Left} = fit_frames(Rest, Room - Size),
            {[Frame | Taken], Left};
        _ ->
            case split_frame(Frame, Room) of
                {Head, Tail} -> {[Head], [Tail | Rest]};
                none -> {[], Frames}
            end
    end;
fit_frames([], _Room) ->
    {[], []}.

%% Split a STREAM or CRYPTO frame so its head fills `Room` bytes, or `none`
%% when no data byte fits or the frame cannot be split. The head's Length is
%% sized as a 2-byte varint; a shorter one only leaves the head a byte under.
-spec split_frame(roadrunner_quic_frame:frame(), integer()) ->
    {roadrunner_quic_frame:frame(), roadrunner_quic_frame:frame()} | none.
split_frame({stream, Sid, Offset, Data, Fin}, Room) ->
    HeadLen = Room - frames_size([{stream, Sid, Offset, <<>>, false}]) - 1,
    case Data of
        <<Head:HeadLen/binary, Tail/binary>> when HeadLen > 0 ->
            {{stream, Sid, Offset, Head, false}, {stream, Sid, Offset + HeadLen, Tail, Fin}};
        _ ->
            none
    end;
split_frame({crypto, Offset, Data}, Room) ->
    HeadLen = Room - frames_size([{crypto, Offset, <<>>}]) - 1,
    case Data of
        <<Head:HeadLen/binary, Tail/binary>> when HeadLen > 0 ->
            {{crypto, Offset, Head}, {crypto, Offset + HeadLen, Tail}};
        _ ->
            none
    end;
split_frame(_Frame, _Room) ->
    none.

-spec frames_size([roadrunner_quic_frame:frame()]) -> non_neg_integer().
frames_size(Frames) ->
    iolist_size([roadrunner_quic_frame:encode(Frame) || Frame <- Frames]).

%% Whether a packet may go out carrying nothing but the ACK. Initial and
%% Handshake packets are acknowledged at once (RFC 9000 §13.2.1); a 1-RTT ACK
%% waits for data to ride with until `roadrunner_quic_ack:ack_due/3` says it
%% may not.
-spec ack_due(level(), integer(), #space{}) -> boolean().
ack_due(application, Now, #space{ack = Ack}) ->
    roadrunner_quic_ack:ack_due(Ack, Now, ?ACK_DELAY);
ack_due(_Level, _Now, _Space) ->
    true.

%% With nothing pending to retransmit, fill the packet after any ACK with
%% fresh data: CRYPTO at the handshake levels, application STREAM frames at
%% the application level (which never carries CRYPTO).
-spec build_data(level(), [roadrunner_quic_frame:frame()], boolean(), #space{}, t()) ->
    none | {map(), t()}.
build_data(application, AckFrames, AckDue, #space{next_pn = PN} = Space, State) ->
    {StreamFrames, State1} = take_stream(AckFrames, PN, State),
    case {StreamFrames, AckDue} of
        {[], false} ->
            %% No data, and no ACK, or one that may still wait: send nothing.
            none;
        _ ->
            %% Data, or an ACK that is due (so `AckFrames` holds it).
            build_entry(application, prepend_ack(AckFrames, StreamFrames), Space, State1)
    end;
build_data(Level, AckFrames, _AckDue, Space, State) ->
    {CryptoFrames, Crypto} = take_crypto(Space#space.crypto),
    case prepend_ack(AckFrames, CryptoFrames) of
        [] -> none;
        Frames -> build_entry(Level, Frames, Space#space{crypto = Crypto}, State)
    end.

%% Put the ACK frame (if any) ahead of the data frames. `take_ack` yields an
%% empty list or a single `[AckFrame]`, so this prepends without the traversal a
%% list append would cost on the hot send path.
-spec prepend_ack([roadrunner_quic_frame:frame()], [roadrunner_quic_frame:frame()]) ->
    [roadrunner_quic_frame:frame()].
prepend_ack([], Frames) -> Frames;
prepend_ack([Ack], Frames) -> [Ack | Frames].

%% Pull ONE outbound STREAM frame from the lowest-id stream that has data or a
%% FIN to send and the credit to send it, skipping streams blocked by send
%% flow control (a buffered-but-unsendable stream yields `nothing`; a pending
%% FIN-only frame costs no credit and is always emitted). The slice is bounded
%% by the connection and per-stream send windows and by the room left in the
%% datagram after the header, the same-packet ACK, the STREAM frame header, and
%% the AEAD tag (so the datagram fills the 1200-byte path limit without
%% exceeding it); the bytes are accounted against both windows. The same-packet
%% ACK frames and the packet number size the per-datagram room.
-spec take_stream([roadrunner_quic_frame:frame()], non_neg_integer(), t()) ->
    {[roadrunner_quic_frame:frame()], t()}.
take_stream(AckFrames, PN, #state{sendable = Sendable} = State) ->
    %% Only streams with pending send data are candidates, already ascending;
    %% finished/drained streams never enter the walk (see `put_stream/4`).
    take_stream(Sendable, AckFrames, PN, State).

-spec take_stream([non_neg_integer()], [roadrunner_quic_frame:frame()], non_neg_integer(), t()) ->
    {[roadrunner_quic_frame:frame()], t()}.
take_stream([], _AckFrames, _PN, State) ->
    {[], State};
take_stream(
    [Sid | Rest],
    AckFrames,
    PN,
    #state{streams = Streams, conn_flow = ConnFlow, peer_scid = DCID} = State
) ->
    #{Sid := {Stream0, StreamFlow0}} = Streams,
    Offset0 = roadrunner_quic_stream:send_offset(Stream0),
    Budget = lists:min([
        roadrunner_quic_send:stream_data_budget(DCID, PN, AckFrames, Sid, Offset0),
        roadrunner_quic_flow:send_window(ConnFlow),
        roadrunner_quic_flow:send_window(StreamFlow0)
    ]),
    case roadrunner_quic_stream:next_frame(Budget, Stream0) of
        nothing ->
            take_stream(Rest, AckFrames, PN, State);
        {Offset, Data, Fin, Stream1} ->
            Size = byte_size(Data),
            {ConnResult, ConnFlow1} = roadrunner_quic_flow:on_data_sent(Size, ConnFlow),
            {StreamResult, StreamFlow1} = roadrunner_quic_flow:on_data_sent(Size, StreamFlow0),
            State1 = put_stream(Sid, Stream1, StreamFlow1, State#state{conn_flow = ConnFlow1}),
            Frames = [
                {stream, Sid, Offset, Data, Fin}
                | blocked_frames(Sid, ConnResult, ConnFlow1, StreamResult, StreamFlow1)
            ],
            {Frames, State1}
    end.

%% RFC 9000 §4.1 / §19.12-13: when a send exhausts the connection- or
%% stream-level limit, ride a DATA_BLOCKED / STREAM_DATA_BLOCKED along in the
%% same packet (the stream frame was capped by the window, so the datagram has
%% room) so the peer learns to grant more credit; the Limit is the value we
%% hit. The flow reports the blocked transition once per limit (it clears on
%% the matching MAX_DATA / MAX_STREAM_DATA), so this never repeats for a limit.
-spec blocked_frames(
    non_neg_integer(),
    ok | blocked,
    roadrunner_quic_flow:t(),
    ok | blocked,
    roadrunner_quic_flow:t()
) -> [roadrunner_quic_frame:frame()].
blocked_frames(Sid, ConnResult, ConnFlow, StreamResult, StreamFlow) ->
    conn_blocked_frame(ConnResult, ConnFlow, stream_blocked_frame(Sid, StreamResult, StreamFlow)).

-spec conn_blocked_frame(ok | blocked, roadrunner_quic_flow:t(), [roadrunner_quic_frame:frame()]) ->
    [roadrunner_quic_frame:frame()].
conn_blocked_frame(blocked, ConnFlow, Tail) ->
    [{data_blocked, roadrunner_quic_flow:bytes_sent(ConnFlow)} | Tail];
conn_blocked_frame(ok, _ConnFlow, Tail) ->
    Tail.

-spec stream_blocked_frame(non_neg_integer(), ok | blocked, roadrunner_quic_flow:t()) ->
    [roadrunner_quic_frame:frame()].
stream_blocked_frame(Sid, blocked, StreamFlow) ->
    [{stream_data_blocked, Sid, roadrunner_quic_flow:bytes_sent(StreamFlow)}];
stream_blocked_frame(_Sid, ok, _StreamFlow) ->
    [].

%% A 1-RTT packet counts toward its send keys' confidentiality limit (RFC
%% 9001 §6.6); a datagram that does not go out returns the state from before
%% it, so only packets sent are counted.
-spec build_entry(level(), [roadrunner_quic_frame:frame()], #space{}, t()) -> {map(), t()}.
build_entry(application, Frames, #space{next_pn = PN} = Space, #state{sealed = Sealed} = State) ->
    Entry = entry(application, Frames, PN, State),
    State1 = ack_in_phase(application, Frames, State#state{sealed = Sealed + 1}),
    {Entry, put_space(application, Space#space{next_pn = PN + 1}, State1)};
build_entry(Level, Frames, #space{next_pn = PN} = Space, State) ->
    Entry = entry(Level, Frames, PN, State),
    {Entry, put_space(Level, Space#space{next_pn = PN + 1}, ack_in_phase(Level, Frames, State))}.

%% One packet's send entry. A 1-RTT packet carries the current Key Phase bit
%% (RFC 9001 §6.1) and is protected with the current send keys; after a key
%% update both are the new generation's (§6.4: never the old keys).
-spec entry(level(), [roadrunner_quic_frame:frame()], non_neg_integer(), t()) ->
    roadrunner_quic_send:entry().
entry(application, Frames, PN, #state{send_keys = #{application := Keys}, key_phase = Phase}) ->
    #{frames => Frames, keys => Keys, pn => PN, key_phase => Phase};
entry(Level, Frames, PN, #state{send_keys = SendKeys}) ->
    #{Level := Keys} = SendKeys,
    #{frames => Frames, keys => Keys, pn => PN}.

%% A 1-RTT packet carrying an ACK, the first since a key update, completes
%% the update (RFC 9001 §6.2): it acknowledges a packet of the new phase, so
%% the peer may update again once it arrives. The ACK, when present, leads
%% the frames (`prepend_ack/2`).
-spec ack_in_phase(level(), [roadrunner_quic_frame:frame()], t()) -> t().
ack_in_phase(application, [{ack, _, _, _, _, _} | _], #state{update_acked = false} = State) ->
    State#state{update_acked = true};
ack_in_phase(_Level, _Frames, State) ->
    State.

%% The ACK frame for a space with an ack-eliciting packet awaiting one, with
%% the ACK Delay the largest packet has waited (RFC 9000 §13.2.5, §19.3).
-spec take_ack(roadrunner_quic_ack:t(), integer()) ->
    {[roadrunner_quic_frame:frame()], roadrunner_quic_ack:t()}.
take_ack(Ack, Now) ->
    case roadrunner_quic_ack:needs_ack(Ack) of
        false ->
            {[], Ack};
        true ->
            {Largest, FirstRange, Ranges} = roadrunner_quic_ack:to_ack(Ack),
            Delay = (roadrunner_quic_ack:ack_delay(Ack, Now) * 1000) bsr ?ACK_DELAY_EXPONENT,
            {
                [{ack, Largest, Delay, FirstRange, Ranges, undefined}],
                roadrunner_quic_ack:mark_ack_sent(Ack)
            }
    end.

-spec take_crypto(roadrunner_quic_stream:t()) ->
    {[roadrunner_quic_frame:frame()], roadrunner_quic_stream:t()}.
take_crypto(Crypto) ->
    case roadrunner_quic_stream:next_frame(?CRYPTO_BUDGET, Crypto) of
        nothing -> {[], Crypto};
        {Offset, Data, _Fin, Crypto1} -> {[{crypto, Offset, Data}], Crypto1}
    end.

-spec record_sent(integer(), [roadrunner_quic_send:sent()], t()) -> t().
record_sent(Now, Sent, State) ->
    lists:foldl(fun(S, Acc) -> record_one_sent(Now, S, Acc) end, State, Sent).

-spec record_one_sent(integer(), roadrunner_quic_send:sent(), t()) -> t().
record_one_sent(
    Now,
    #{level := Level, pn := PN, length := Len, ack_eliciting := AckEliciting, frames := Frames},
    State
) ->
    Space = space(Level, State),
    Loss = roadrunner_quic_loss:on_packet_sent(
        PN, Len, AckEliciting, Frames, Now, Space#space.loss
    ),
    put_space(Level, Space#space{loss = Loss}, State).

%% =============================================================================
%% Timers
%% =============================================================================

-doc """
Handle a fired timer. A probe timeout (`pto`) re-runs loss detection on every
space (queueing any lost frames to retransmit), backs off the probe timeout
(so a probe that detects no loss re-arms strictly later, guaranteeing forward
progress), queues a probe in every space with packets in flight, then runs a
send pass that lets the probes past the congestion window. An idle timeout
(`idle`) silently closes the connection (RFC 9000 §10.1, no CONNECTION_CLOSE)
and surfaces the terminal `{closed, _}` event to the owner. A path timeout
(`path`) sends the validation of the current path another PATH_CHALLENGE,
or gives the validation up (RFC 9000 §8.2.4), returning to the last
validated path (§9.3.2, led by `{migrate, Peer}`) or, with none, closing
silently.
""".
-spec handle_timeout(integer(), atom(), t()) -> {t(), [effect()]}.
handle_timeout(Now, pto, State) ->
    State1 = lists:foldl(fun(Level, S) -> on_pto(Now, Level, S) end, State, present_levels(State)),
    {State2, Effects} = send_pass(Now, rechallenge_stranded(State1)),
    {State2#state{probes = 0}, Effects};
handle_timeout(_Now, idle, State) ->
    close_silently(idle_timeout, State);
handle_timeout(_Now, Kind, #state{phase = Phase} = State) when
    Kind =:= ack orelse Kind =:= path, Phase =:= closed orelse Phase =:= draining
->
    %% A closing connection sends nothing more, a delayed ACK or a path
    %% challenge included.
    {State, []};
handle_timeout(Now, path, #state{peer = Peer} = State) ->
    {State1, Effects} = path_timeout(Now, State),
    {State1, peer_effects(Peer, State1, Effects)};
handle_timeout(Now, ack, State) ->
    %% A delayed ACK's wait ran out with no packet to carry it: send it now.
    send_pass(Now, State);
handle_timeout(_Now, drain, State) ->
    %% The drain window elapsed (RFC 9000 §10.2): become closed so the shell
    %% tears the connection down. The owner already learned of the close on entry.
    {State#state{phase = closed}, []}.

%% A probe timeout on the current path, while the address a failed
%% validation left is still the one the client probes from, challenges that
%% address as well. A client that really moved there, whose challenges or
%% responses were lost, may only be receiving (a download) and so send
%% nothing more from it: unanswered here, it would wait there until its idle
%% timeout. The challenge is ack-eliciting, so such a client answers with a
%% non-probing packet, which moves the connection back (RFC 9000 §9.3). The
%% address's anti-amplification account bounds it (§8.1), which the failed
%% validation left room in (`reserve/1`), and the probe timeout's backoff
%% paces it.
-spec rechallenge_stranded(t()) -> t().
rechallenge_stranded(
    #state{phase = connected, stranded = Addr, probe_path = {Addr, _Seq, _Amp}} = State
) ->
    queue_path(probe, [{path_challenge, crypto:strong_rand_bytes(8)}], State);
rechallenge_stranded(State) ->
    State.

%% Close without a CONNECTION_CLOSE and surface the terminal `{closed, _}`
%% event to the owner. Any parked send reply is released before the shell
%% tears down, so a parked worker unblocks and runs its disconnect path
%% cleanly rather than only crashing on the conn-process exit its monitor
%% sees.
-spec close_silently(atom(), t()) -> {t(), [effect()]}.
close_silently(Reason, State) ->
    {State1, Releases} = release_all({error, closed}, State),
    {State2, EmitEffects} = drain_emits(
        emit({closed, {local, Reason}}, State1#state{phase = closed})
    ),
    {State2, Releases ++ EmitEffects}.

%% The current path's validation timer (RFC 9000 §8.2.4). Past the abandon
%% time the validation fails: back to the last validated path (§9.3.2 MUST),
%% or, with no such path left, a silent close (§9.3.2 MUST). Before it,
%% another PATH_CHALLENGE goes out. A timer that outlived the validation
%% only re-arms.
-spec path_timeout(integer(), t()) -> {t(), [effect()]}.
path_timeout(Now, #state{validation = #validation{abandon_at = At}, prev_path = Prev} = State) when
    Now >= At
->
    case Prev of
        {_Addr, _Seq, _PathDcid} -> send_pass(Now, return_to_prev(keep_as_probe(State)));
        undefined -> close_silently(no_viable_path, State)
    end;
path_timeout(
    Now,
    #state{validation = #validation{next_at = Next, abandon_at = At, interval = Interval} = V} =
        State
) when Now >= Next ->
    send_pass(
        Now,
        queue_challenge(State#state{validation = V#validation{next_at = min(Now + Interval, At)}})
    );
path_timeout(Now, State) ->
    send_pass(Now, State).

%% On a probe timeout: queue any time-threshold losses to retransmit, feed
%% them to congestion control as a congestion event the same as ACK-detected
%% losses (RFC 9002 Appendix B.8; the recovery period still dedups them,
%% §7.3.2), and increment the space's probe-timeout backoff (RFC 9002
%% §6.2.1), so the next deadline is strictly later. A space with packets in flight then MUST
%% send an ack-eliciting probe (RFC 9002 §6.2.4): loss detection only counts
%% a packet older than one the peer acknowledged, so the last packets of a
%% flight, if lost, are found only through the ACK a probe draws. The probe
%% is what was just found lost, else the oldest data still unacknowledged,
%% else a PING.
-spec on_pto(integer(), level(), t()) -> t().
on_pto(Now, Level, #state{probes = Probes, cc = Cc} = State) ->
    #space{loss = Loss0, pending = Pending} = Space = space(Level, State),
    {Loss1, Lost} = roadrunner_quic_loss:detect_lost(Now, Loss0),
    Loss2 = roadrunner_quic_loss:on_pto_expired(Loss1),
    Space1 = Space#space{
        loss = Loss2, pending = lists:reverse(retransmittable(Lost, State), Pending)
    },
    State1 = State#state{cc = apply_cc_signal(roadrunner_quic_loss:cc_signal(Loss1), Now, Cc)},
    case roadrunner_quic_loss:bytes_in_flight(Loss0) of
        0 -> put_space(Level, Space1, State1);
        _ -> put_space(Level, probe(Level, Space1, State1), State1#state{probes = Probes + 1})
    end.

%% With nothing found lost, probe with unacknowledged data rather than a
%% PING (RFC 9002 §6.2.4): if that data was lost, the probe already carries
%% what the peer is missing, instead of only drawing the ACK that shows it
%% lost and costing a round trip more. A handshake space sends all of it: its
%% flight is a few KB of CRYPTO data, the client can finish the handshake
%% only with every byte, and the ACKs that would show which packets were
%% lost are themselves lost under the same loss, so resending only the
%% oldest packet leaves the rest of the flight one backed-off probe timeout
%% each, which can outlast the idle timeout. The application space sends
%% the oldest packet's, its later losses left to the ACKs of the data it
%% keeps sending. A PING only when no such data is in flight.
-spec probe(level(), #space{}, t()) -> #space{}.
probe(Level, #space{pending = [], loss = Loss} = Space, State) ->
    case retransmittable(probe_data(Level, Loss), State) of
        [] -> Space#space{pending = [ping]};
        Resend -> Space#space{pending = Resend}
    end;
probe(_Level, Space, _State) ->
    Space.

-spec probe_data(level(), roadrunner_quic_loss:t()) -> [term()].
probe_data(application, Loss) -> roadrunner_quic_loss:oldest_ack_eliciting(Loss);
probe_data(_Handshake, Loss) -> roadrunner_quic_loss:unacked_ack_eliciting(Loss).

%% Arm ONE timer at the nearest deadline: the earliest per-space probe timeout
%% (across spaces with ack-eliciting bytes in flight) or the always-present
%% idle deadline, whichever is sooner. A single nearest-deadline timer keeps
%% the per-datagram re-arm to one timer operation; the loser is re-derived
%% after the winner fires (RFC 9000 §10.1, RFC 9002 §6.2).
-spec timer_effects(t()) -> [effect()].
timer_effects(State) ->
    {Kind, AtMs} = earliest_deadline(State),
    [{arm_timer, Kind, AtMs}].

%% While the anti-amplification limit holds a datagram back, neither a
%% probe timeout nor a delayed ACK is armed: nothing more can be sent until
%% the client sends again (RFC 9002 §6.2.2.1 MUST NOT arm the PTO), and that
%% datagram runs a send pass of its own. A deadline already past would
%% otherwise fire at once, again and again.
-spec earliest_deadline(t()) -> {pto | idle | ack | path, integer()}.
earliest_deadline(#state{amp = Amp} = State) ->
    earliest_deadline(roadrunner_quic_amp:blocked(Amp), State).

-spec earliest_deadline(boolean(), t()) -> {pto | idle | ack | path, integer()}.
earliest_deadline(true, #state{idle_deadline = Idle, validation = Validation}) ->
    path_or(Validation, {idle, Idle});
earliest_deadline(false, #state{idle_deadline = Idle, validation = Validation} = State) ->
    Timed =
        case earliest_pto(State) of
            undefined -> {idle, Idle};
            PtoAt when PtoAt =< Idle -> {pto, PtoAt};
            _PtoAt -> {idle, Idle}
        end,
    Nearest = path_or(Validation, Timed),
    case {ack_deadline(State), Nearest} of
        {AckAt, {_Kind, At}} when is_integer(AckAt), AckAt < At -> {ack, AckAt};
        _ -> Nearest
    end.

%% A path validation in progress challenges again on its own timer, which
%% wins a tie: the probe timeout due with it re-arms at once after it.
-spec path_or(undefined | #validation{}, {pto | idle, integer()}) ->
    {pto | idle | path, integer()}.
path_or(#validation{next_at = PathAt}, {_TimedKind, TimedAt}) when PathAt =< TimedAt ->
    {path, PathAt};
path_or(_Validation, Timed) ->
    Timed.

%% When a delayed 1-RTT ACK must go out, or `undefined` with none waiting.
-spec ack_deadline(t()) -> integer() | undefined.
ack_deadline(#state{spaces = #{application := #space{ack = Ack}}}) ->
    roadrunner_quic_ack:ack_deadline(Ack, ?ACK_DELAY);
ack_deadline(#state{}) ->
    undefined.

%% The congestion-controlled bytes in flight across every space, the value the
%% congestion window bounds (RFC 9002 §B.2 keeps one count per connection). A
%% discarded space leaves the map, so its in-flight cannot count stale.
-spec total_bytes_in_flight(t()) -> non_neg_integer().
total_bytes_in_flight(#state{spaces = Spaces}) ->
    maps:fold(
        fun(_Level, #space{loss = Loss}, Total) ->
            Total + roadrunner_quic_loss:bytes_in_flight(Loss)
        end,
        0,
        Spaces
    ).

-spec earliest_pto(t()) -> integer() | undefined.
earliest_pto(#state{spaces = Spaces}) ->
    %% The earliest PTO across all spaces, each counted from its last
    %% ack-eliciting send (RFC 9002 §6.2.1), not from now: a peer that keeps
    %% sending must not keep pushing the probe back. The map is folded
    %% directly (order is irrelevant to a min).
    maps:fold(
        fun(_Level, #space{loss = Loss}, Earliest) ->
            min_defined(Earliest, roadrunner_quic_loss:pto_deadline(Loss))
        end,
        undefined,
        Spaces
    ).

%% =============================================================================
%% Internal
%% =============================================================================

-spec largest_map(t()) -> #{level() => non_neg_integer()}.
largest_map(#state{spaces = Spaces}) ->
    maps:fold(
        fun(Level, #space{ack = Ack}, Acc) ->
            case roadrunner_quic_ack:largest(Ack) of
                undefined -> Acc;
                Largest -> Acc#{Level => Largest}
            end
        end,
        #{},
        Spaces
    ).

-spec present_levels(t()) -> [level()].
present_levels(#state{spaces = Spaces}) ->
    [Level || Level <- [initial, handshake, application], is_map_key(Level, Spaces)].

-spec space(level(), t()) -> #space{}.
space(Level, #state{spaces = Spaces}) ->
    #{Level := Space} = Spaces,
    Space.

-spec put_space(level(), #space{}, t()) -> t().
put_space(Level, Space, #state{spaces = Spaces} = State) ->
    State#state{spaces = Spaces#{Level => Space}}.

-spec min_defined(integer() | undefined, integer() | undefined) -> integer() | undefined.
min_defined(undefined, B) -> B;
min_defined(A, undefined) -> A;
min_defined(A, B) -> min(A, B).

%% Flatten the per-packet frame lists a loss returns and keep only the
%% frames worth resending: ACK / PADDING / CONNECTION_CLOSE are regenerated
%% fresh or terminal, never replayed (RFC 9002 §13.3), a PATH_RESPONSE
%% answers one PATH_CHALLENGE once, on the path it arrived on (RFC 9000
%% §13.3), a PATH_CHALLENGE goes out again from the validation timer with
%% new data (§13.3), and a NEW_CONNECTION_ID is resent with the same
%% sequence number only while the client has not retired that id (§13.3).
%% `roadrunner_quic_send:ack_eliciting/1` is the single source of truth for
%% which frames are ack-eliciting. Callers fold the result onto the existing
%% pending list with `lists:reverse/2` (order within the flushed packet is
%% irrelevant), so no list append is needed.
-spec retransmittable([[roadrunner_quic_frame:frame()]], t()) -> [roadrunner_quic_frame:frame()].
retransmittable(Lost, State) ->
    [Frame || Frame <- lists:append(Lost), is_retransmittable(Frame, State)].

-spec is_retransmittable(roadrunner_quic_frame:frame(), t()) -> boolean().
is_retransmittable({path_response, _Data}, _State) ->
    false;
is_retransmittable({path_challenge, _Data}, _State) ->
    false;
is_retransmittable({new_connection_id, Seq, _Prior, _CID, _Token}, #state{cids = Cids}) ->
    is_map_key(Seq, Cids);
is_retransmittable(Frame, _State) ->
    roadrunner_quic_send:is_ack_eliciting(Frame).
