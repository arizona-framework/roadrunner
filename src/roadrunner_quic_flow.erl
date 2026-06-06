-module(roadrunner_quic_flow).
-moduledoc false.

%% QUIC flow control for one window (RFC 9000 §4), connection-level or
%% per-stream. The two are structurally identical (MAX_DATA vs
%% MAX_STREAM_DATA), so a connection keeps one of these for the connection
%% and one per stream.
%%
%% Send side: bytes sent are tracked against the peer's advertised limit;
%% sending past it is refused and surfaced as blocked (the connection then
%% sends DATA_BLOCKED), and a received MAX_DATA frame raises the limit.
%% Receive side: bytes received are tracked against our advertised limit,
%% an overrun is rejected as a flow-control error (§4.1), and once enough
%% of the window has been consumed a fresh limit is granted so the peer is
%% not stalled. Pure: the connection sends the frames and feeds the byte
%% counts back in.

-export([
    new/1,
    can_send/2,
    on_data_sent/2,
    on_max_data_received/2,
    send_blocked/1,
    on_data_received/2,
    should_send_max_data/1,
    grant_max_data/1,
    send_window/1,
    recv_window/1,
    bytes_sent/1,
    bytes_received/1
]).

-export_type([t/0, opts/0]).

%% A reasonable default window when an option is omitted (RFC 9000 §4 sets
%% no value; this matches the transport-parameter default used elsewhere).
-define(DEFAULT_INITIAL_MAX_DATA, 786432).
%% Grant a new limit once more than a quarter of the window has been
%% consumed since the last grant (RFC 9000 §4.1 leaves the fraction to the
%% implementation), keeping the peer in credit under sustained transfer.
-define(REFILL_NUM, 3).
-define(REFILL_DEN, 4).

-record(flow, {
    %% Send side: limited by the peer's MAX_DATA.
    bytes_sent = 0 :: non_neg_integer(),
    send_max :: non_neg_integer(),
    send_blocked = false :: boolean(),
    %% Receive side: our advertised limit on the peer.
    bytes_received = 0 :: non_neg_integer(),
    recv_max :: non_neg_integer(),
    %% The window size granted each refill.
    initial_max :: non_neg_integer()
}).

-opaque t() :: #flow{}.

-type opts() :: #{
    initial_max_data => non_neg_integer(),
    peer_initial_max_data => non_neg_integer()
}.

%% =============================================================================
%% State
%% =============================================================================

-doc """
A fresh flow-control window. `initial_max_data` is the limit we advertise
to the peer (our receive window); `peer_initial_max_data` is the peer's
advertised limit on us (our send window).
""".
-spec new(opts()) -> t().
new(Opts) ->
    Initial = maps:get(initial_max_data, Opts, ?DEFAULT_INITIAL_MAX_DATA),
    Peer = maps:get(peer_initial_max_data, Opts, ?DEFAULT_INITIAL_MAX_DATA),
    #flow{send_max = Peer, recv_max = Initial, initial_max = Initial}.

%% =============================================================================
%% Send side
%% =============================================================================

-doc "Whether `Size` more bytes fit within the peer's current send limit.".
-spec can_send(non_neg_integer(), t()) -> boolean().
can_send(Size, #flow{bytes_sent = Sent, send_max = Max}) ->
    Sent + Size =< Max.

-doc """
Record `Size` bytes sent. Returns `blocked` once the send limit is
reached (the connection then sends DATA_BLOCKED), otherwise `ok`.
""".
-spec on_data_sent(non_neg_integer(), t()) -> {ok | blocked, t()}.
on_data_sent(Size, #flow{bytes_sent = Sent, send_max = Max} = Flow) ->
    NewSent = Sent + Size,
    case NewSent >= Max of
        true -> {blocked, Flow#flow{bytes_sent = NewSent, send_blocked = true}};
        false -> {ok, Flow#flow{bytes_sent = NewSent, send_blocked = false}}
    end.

-doc "Raise the send limit from a received MAX_DATA frame (limits only increase).".
-spec on_max_data_received(non_neg_integer(), t()) -> t().
on_max_data_received(NewMax, #flow{send_max = OldMax} = Flow) ->
    Flow#flow{send_max = max(OldMax, NewMax), send_blocked = false}.

-doc "Whether sending is currently blocked by the peer's limit.".
-spec send_blocked(t()) -> boolean().
send_blocked(#flow{send_blocked = Blocked}) ->
    Blocked.

%% =============================================================================
%% Receive side
%% =============================================================================

-doc """
Record `Size` bytes received, or reject them as `flow_control_error`
(RFC 9000 §4.1) if they exceed the limit we advertised.
""".
-spec on_data_received(non_neg_integer(), t()) -> {ok, t()} | {error, flow_control_error}.
on_data_received(Size, #flow{bytes_received = Received, recv_max = Max} = Flow) ->
    NewReceived = Received + Size,
    case NewReceived > Max of
        true -> {error, flow_control_error};
        false -> {ok, Flow#flow{bytes_received = NewReceived}}
    end.

-doc "Whether enough of the window has been consumed to grant a new limit (RFC 9000 §4.1).".
-spec should_send_max_data(t()) -> boolean().
should_send_max_data(#flow{bytes_received = Received, recv_max = Max, initial_max = Initial}) ->
    Received > Max - Initial * ?REFILL_NUM div ?REFILL_DEN.

-doc """
Grant a fresh receive limit: the bytes consumed so far plus a full window.
Returns the new limit (to send in a MAX_DATA frame) and the updated state.
""".
-spec grant_max_data(t()) -> {non_neg_integer(), t()}.
grant_max_data(#flow{bytes_received = Received, initial_max = Initial} = Flow) ->
    NewMax = Received + Initial,
    {NewMax, Flow#flow{recv_max = NewMax}}.

%% =============================================================================
%% Queries
%% =============================================================================

-doc "Bytes that may still be sent before hitting the peer's limit.".
-spec send_window(t()) -> non_neg_integer().
send_window(#flow{bytes_sent = Sent, send_max = Max}) ->
    max(0, Max - Sent).

-doc "Bytes the peer may still send before hitting our advertised limit.".
-spec recv_window(t()) -> non_neg_integer().
recv_window(#flow{bytes_received = Received, recv_max = Max}) ->
    max(0, Max - Received).

-doc "Total bytes sent on this window.".
-spec bytes_sent(t()) -> non_neg_integer().
bytes_sent(#flow{bytes_sent = Sent}) ->
    Sent.

-doc "Total bytes received on this window.".
-spec bytes_received(t()) -> non_neg_integer().
bytes_received(#flow{bytes_received = Received}) ->
    Received.
