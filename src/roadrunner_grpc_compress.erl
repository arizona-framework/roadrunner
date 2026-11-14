-module(roadrunner_grpc_compress).
-moduledoc false.

%% Per-message compression for gRPC (gRPC's compression.md): `gzip`, and
%% `deflate` as the zlib structure (RFC 1950), never raw deflate. Each
%% message is compressed on its own: gRPC keeps no compression context
%% across messages (PROTOCOL-HTTP2, Compressed-Flag).

-export([encodings/0, compress/2, decompress/3]).

-doc "The `grpc-accept-encoding` value: every encoding roadrunner reads.".
-spec encodings() -> binary().
encodings() ->
    ~"identity,gzip,deflate".

-doc "A message's bytes compressed with `Encoding`.".
-spec compress(gzip | deflate, iodata()) -> binary().
compress(gzip, Bytes) -> zlib:gzip(Bytes);
compress(deflate, Bytes) -> zlib:compress(Bytes).

-doc """
A compressed message's bytes, at most `Max` of them: inflating stops the
moment the output would pass it, so a small message cannot expand into
unbounded memory. `{error, malformed}` for bytes that do not inflate.
""".
-spec decompress(gzip | deflate, binary(), non_neg_integer()) ->
    {ok, binary()} | {error, too_large | malformed}.
decompress(Encoding, Compressed, Max) ->
    Z = zlib:open(),
    try
        %% Window bits 31 read a gzip stream, 15 a zlib one (RFC 1950).
        %% Bytes after the end are refused: a gzip stream may hold several
        %% members, each read (`reset`, as `zlib:gunzip/1` reads them), a
        %% zlib one is a single stream (`error`).
        ok = zlib:inflateInit(Z, window_bits(Encoding), end_of_stream(Encoding)),
        case inflate(zlib:safeInflate(Z, Compressed), Z, Max, 0, []) of
            {ok, _} = Ok ->
                %% Raises when the stream never reached its end: bytes cut
                %% short are no message, however much they inflated.
                ok = zlib:inflateEnd(Z),
                Ok;
            Error ->
                Error
        end
    catch
        error:_ -> {error, malformed}
    after
        zlib:close(Z)
    end.

-spec end_of_stream(gzip | deflate) -> reset | error.
end_of_stream(gzip) -> reset;
end_of_stream(deflate) -> error.

-spec window_bits(gzip | deflate) -> 15 | 31.
window_bits(gzip) -> 31;
window_bits(deflate) -> 15.

-spec inflate(
    {continue | finished, iolist()}, zlib:zstream(), non_neg_integer(), non_neg_integer(), iolist()
) -> {ok, binary()} | {error, too_large}.
inflate({Status, Output}, Z, Max, Total, Acc) ->
    case Total + iolist_size(Output) of
        NewTotal when NewTotal > Max ->
            {error, too_large};
        NewTotal when Status =:= continue ->
            %% Each call reads input or yields output, so this ends: a
            %% stream cut short comes back `finished`, and `inflateEnd`
            %% then raises.
            inflate(zlib:safeInflate(Z, []), Z, Max, NewTotal, [Acc, Output]);
        _Final ->
            {ok, iolist_to_binary([Acc, Output])}
    end.
