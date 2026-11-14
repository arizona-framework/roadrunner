-module(roadrunner_grpc_protobuf_interop).
-moduledoc false.

%% gRPC's interop `grpc.testing.TestService`, the server side of
%% doc/interop-test-descriptions.md: EmptyCall, UnaryCall, the streaming
%% calls, CompressedResponse and CompressedRequest, Echo Status, Echo
%% Metadata and ResponseParameters.interval_us. CacheableUnaryCall answers
%% with a cache-control header and a fresh payload; there is no caching
%% proxy in front to test it with.

-export([routes/0, routes/1]).
-export([
    empty_call/2,
    unary_call/2,
    cacheable_unary_call/2,
    streaming_output_call/2,
    streaming_input_call/1,
    full_duplex_call/1,
    half_duplex_call/1,
    unimplemented_call/2
]).

-define(PB, test_pb).

%% The interop server's routes: TestService only, so a call to
%% UnimplementedService is the router's 404, which a client reads as
%% UNIMPLEMENTED.
routes() ->
    routes(#{}).

routes(Opts) ->
    roadrunner_grpc:routes(Opts#{
        services => [roadrunner_grpc_protobuf:service(?PB, 'grpc.testing.TestService', ?MODULE)],
        codecs => [roadrunner_grpc_protobuf]
    }).

empty_call(#{}, Stream) ->
    {reply, #{}, echo_metadata(Stream)}.

unary_call(Request, Stream0) ->
    Stream = echo_metadata(Stream0),
    maybe
        ok ?= expect_compressed(Request, Stream),
        ok ?= echo_status(Request, Stream),
        {ok, Payload} ?= payload(Request, Stream),
        {reply, #{payload => Payload}, response_compression(Request, Stream)}
    end.

cacheable_unary_call(_Request, Stream) ->
    Body = integer_to_binary(erlang:system_time(nanosecond)),
    {reply, #{payload => #{type => 'COMPRESSABLE', body => Body}},
        roadrunner_grpc:set_headers([{~"cache-control", ~"max-age=60"}], echo_metadata(Stream))}.

streaming_output_call(Request, Stream) ->
    respond(Request, streaming(Stream)).

streaming_input_call(Stream) ->
    streaming_input(echo_metadata(Stream), 0).

streaming_input(Stream0, Size) ->
    case roadrunner_grpc:recv(Stream0) of
        {ok, Request, Stream} ->
            case expect_compressed(Request, Stream) of
                ok -> streaming_input(Stream, Size + payload_size(Request));
                Error -> Error
            end;
        {eof, Stream} ->
            {reply, #{aggregated_payload_size => Size}, Stream}
    end.

full_duplex_call(Stream) ->
    full_duplex(streaming(Stream)).

full_duplex(Stream0) ->
    case roadrunner_grpc:recv(Stream0) of
        {ok, Request, Stream} ->
            case respond(Request, Stream) of
                {ok, Stream1} -> full_duplex(Stream1);
                Error -> Error
            end;
        {eof, Stream} ->
            {ok, Stream}
    end.

%% Every request first, then the responses, as the client half-closes.
half_duplex_call(Stream0) ->
    {Requests, Stream} = requests(streaming(Stream0)),
    respond_all(Requests, Stream).

requests(Stream0) ->
    case roadrunner_grpc:recv(Stream0) of
        {ok, Request, Stream1} ->
            {Requests, Stream} = requests(Stream1),
            {[Request | Requests], Stream};
        {eof, Stream} ->
            {[], Stream}
    end.

respond_all([Request | Requests], Stream0) ->
    case respond(Request, Stream0) of
        {ok, Stream} -> respond_all(Requests, Stream);
        Error -> Error
    end;
respond_all([], Stream) ->
    {ok, Stream}.

unimplemented_call(#{}, Stream) ->
    {error, unimplemented, ~"UnimplementedCall is not implemented", Stream}.

%% A streaming call's responses are compressed one by one, as each one's
%% ResponseParameters.compressed asks: the call's encoding is gzip, when the
%% client reads it, and the others go out with `compress => false`.
streaming(Stream) ->
    roadrunner_grpc:set_send_compression(gzip, echo_metadata(Stream)).

%% A StreamingOutputCallRequest's responses, after its echoed status if any.
respond(Request, Stream) ->
    maybe
        ok ?= echo_status(Request, Stream),
        {ok, send_responses(maps:get(response_parameters, Request, []), Stream)}
    end.

send_responses([#{size := Size} = Parameters | Rest], Stream) ->
    ok = interval(Parameters),
    Response = #{payload => #{type => 'COMPRESSABLE', body => zeros(Size)}},
    Compress = compressed(maps:get(compressed, Parameters, #{})),
    send_responses(Rest, roadrunner_grpc:send(Response, Stream, #{compress => Compress}));
send_responses([], Stream) ->
    Stream.

%% ResponseParameters.interval_us: a wait before the response, in whole
%% milliseconds rounded up, never shorter than asked.
interval(#{interval_us := Micros}) when Micros > 0 ->
    timer:sleep((Micros + 999) div 1000);
interval(#{}) ->
    ok.

compressed(#{value := true}) -> true;
compressed(#{}) -> false.

%% CompressedResponse: a unary response compressed only when asked to.
response_compression(#{response_compressed := #{value := true}}, Stream) ->
    roadrunner_grpc:set_send_compression(gzip, Stream);
response_compression(#{}, Stream) ->
    Stream.

%% CompressedRequest: a request that expects to have come compressed and
%% did not fails the call with INVALID_ARGUMENT.
expect_compressed(#{expect_compressed := #{value := true}}, Stream) ->
    case roadrunner_grpc:recv_compressed(Stream) of
        true -> ok;
        false -> {error, invalid_argument, ~"expected a compressed request", Stream}
    end;
expect_compressed(#{}, _Stream) ->
    ok.

%% Echo Status: a request's response_status ends the call with it.
echo_status(#{response_status := #{code := Code, message := Message}}, Stream) when
    Code > 0, Code =< 16
->
    {error, roadrunner_grpc_status:name(Code), Message, Stream};
echo_status(#{}, _Stream) ->
    ok.

%% UnaryCall's payload: response_size zeros of a type the server supports.
payload(#{response_type := 'COMPRESSABLE', response_size := Size}, _Stream) ->
    {ok, #{type => 'COMPRESSABLE', body => zeros(Size)}};
payload(#{response_type := Type}, Stream) ->
    {error, invalid_argument,
        iolist_to_binary(io_lib:format("unsupported response_type ~p", [Type])), Stream}.

payload_size(#{payload := #{body := Body}}) -> byte_size(Body);
payload_size(#{}) -> 0.

zeros(Size) ->
    <<0:(Size * 8)>>.

%% Echo Metadata: x-grpc-test-echo-initial back in the response headers,
%% x-grpc-test-echo-trailing-bin in the trailers.
echo_metadata(Stream) ->
    Metadata = roadrunner_grpc:metadata(Stream),
    Initial = [Entry || {~"x-grpc-test-echo-initial", _} = Entry <- Metadata],
    Trailing = [Entry || {~"x-grpc-test-echo-trailing-bin", _} = Entry <- Metadata],
    roadrunner_grpc:set_trailers(Trailing, roadrunner_grpc:set_headers(Initial, Stream)).
