%% The largest length, size or count a peer may declare: 2^63 - 1, the
%% largest file offset a 64-bit system addresses. A larger value can't
%% describe a message anyone can send, so it is malformed framing (400)
%% rather than a body over the cap (413).
-define(MAX_DECLARED_LENGTH, 16#7FFFFFFFFFFFFFFF).
