-module(roadrunner_grpc_compress_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, roadrunner_grpc_compress).

round_trip_test() ->
    Bytes = binary:copy(~"abc", 1000),
    ?assertEqual({ok, Bytes}, ?M:decompress(gzip, ?M:compress(gzip, Bytes), 3000)),
    ?assertEqual({ok, Bytes}, ?M:decompress(deflate, ?M:compress(deflate, Bytes), 3000)).

%% Inflating stops at the limit: a byte over is refused.
bounded_test() ->
    Bytes = binary:copy(<<0>>, 100_000),
    ?assertEqual({error, too_large}, ?M:decompress(gzip, ?M:compress(gzip, Bytes), 99_999)),
    ?assertEqual({ok, Bytes}, ?M:decompress(gzip, ?M:compress(gzip, Bytes), 100_000)).

%% Junk, raw deflate for `deflate`, and a stream cut short are malformed.
malformed_test() ->
    Gzip = ?M:compress(gzip, binary:copy(~"abc", 1000)),
    ?assertEqual({error, malformed}, ?M:decompress(gzip, ~"junk", 100)),
    ?assertEqual({error, malformed}, ?M:decompress(deflate, zlib:zip(~"raw"), 100)),
    ?assertEqual({error, malformed}, ?M:decompress(gzip, binary:part(Gzip, 0, 10), 3000)),
    ?assertEqual(
        {error, malformed}, ?M:decompress(gzip, binary:part(Gzip, 0, byte_size(Gzip) - 4), 3000)
    ).

%% Every member of a gzip stream is read, as `zlib:gunzip/1` reads them;
%% bytes after the end that are no member are refused.
members_and_trailing_bytes_test() ->
    Two = <<(zlib:gzip(~"ab"))/binary, (zlib:gzip(~"cd"))/binary>>,
    ?assertEqual({ok, ~"abcd"}, ?M:decompress(gzip, Two, 100)),
    ?assertEqual(
        {error, malformed}, ?M:decompress(gzip, <<(zlib:gzip(~"ab"))/binary, "junk">>, 100)
    ),
    ?assertEqual(
        {error, malformed}, ?M:decompress(deflate, <<(zlib:compress(~"ab"))/binary, "junk">>, 100)
    ),
    %% gRPC's deflate is one zlib stream: a second one after it is refused.
    ?assertEqual(
        {error, malformed},
        ?M:decompress(
            deflate, <<(zlib:compress(~"ab"))/binary, (zlib:compress(~"cd"))/binary>>, 100
        )
    ).

%% A gzip header with a long name (FNAME, RFC 1952 §2.3) yields no output
%% for a while: still a message.
long_gzip_header_test() ->
    Data = ~"payload",
    Name = binary:copy(~"n", 20_000),
    Gzip =
        <<16#1f, 16#8b, 8, 8, 0:32, 0, 255, Name/binary, 0, (zlib:zip(Data))/binary,
            (erlang:crc32(Data)):32/little, (byte_size(Data)):32/little>>,
    ?assertEqual({ok, Data}, ?M:decompress(gzip, Gzip, 100)).

encodings_test() ->
    ?assertEqual(~"identity,gzip,deflate", ?M:encodings()).
