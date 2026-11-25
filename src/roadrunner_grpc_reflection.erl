-module(roadrunner_grpc_reflection).
-moduledoc """
gRPC's server reflection (gRPC's server-reflection.md), which tells tools
such as `grpcurl` and `grpcui` what the server offers: its services, and
the `.proto` files that declare them. Add it with
`roadrunner_grpc:routes(#{services => [...], reflection => true})`; it
answers on `grpc.reflection.v1.ServerReflection` and on the older
`grpc.reflection.v1alpha.ServerReflection`, which some tools still call
first. Like the health service, it speaks its own protobuf messages,
whatever codecs the other services use.

`ServerReflectionInfo`, a bidirectional stream, answers each request in
turn:

- `list_services`: the services of the routes whose files declare them,
  the health service and reflection itself among them (both give theirs)
- `file_by_filename`: the file, then the files it imports, all the way
  down
- `file_containing_symbol`: the same for the file that declares a full
  name: a package's message, enum, enum value, service, method, field,
  oneof or extension, such as `~"helloworld.Greeter.SayHello"`
- `file_containing_extension`: the same for the file that declares an
  extension of a message, by its number
- `all_extension_numbers_of_type`: the numbers of a message's extensions

A file already sent on the stream is not sent again as an import of
another; the file asked for always is. What reflection does not know is
answered with an `error_response`, `NOT_FOUND`, and a request that asks
nothing with `INVALID_ARGUMENT`; a request that is no reflection message
ends the call with `INTERNAL`.

The files are the serialized `google.protobuf.FileDescriptorProto`s each
service gives: the `files/0` callback of a service module, or the `files`
of a descriptor (`roadrunner_grpc_service`); `roadrunner_grpc_protobuf`
can fill it in for its services. A
service whose files do not declare it is left out of `list_services`, so
that every service listed can be described: tools such as `grpcurl` and
`grpcui` describe each one they are told of, and stop at the first they
cannot. Two files of the same name are one: the first given is kept.
""".

-export([services/0, index/1, info/1]).

-export_type([index/0]).

-record(index, {
    %% The full names of the services the files declare, as
    %% `list_services` answers them.
    services :: [binary()],
    %% Each file's bytes and imports, by its name.
    files :: #{binary() => {binary(), [binary()]}},
    %% The file that declares each full name.
    symbols :: #{binary() => binary()},
    %% The file that declares each extension, by the message it extends
    %% and its number.
    extensions :: #{{binary(), non_neg_integer()} => binary()},
    %% The numbers of each message's extensions.
    extension_numbers :: #{binary() => [non_neg_integer()]}
}).

-doc """
What reflection answers from, built when the routes compile: the services'
files and the names they declare. Treat as opaque.
""".
-opaque index() :: #index{}.

%% NOT_FOUND and INVALID_ARGUMENT, as an ErrorResponse's `error_code`.
-define(NOT_FOUND, 5).
-define(INVALID_ARGUMENT, 3).

%% The service in its two versions, `v1` and the older `v1alpha`, which
%% share their messages.
-doc false.
-spec services() -> [roadrunner_grpc_service:descriptor()].
services() ->
    [
        #{
            name => <<"grpc.reflection.", Version/binary, ".ServerReflection">>,
            module => ?MODULE,
            files => [roadrunner_grpc_descriptor:reflection(Version)],
            rpcs => #{
                ~"ServerReflectionInfo" => #{
                    function => info, kind => bidi_stream, input => request, output => response
                }
            }
        }
     || Version <- [~"v1", ~"v1alpha"]
    ].

%% What reflection answers from: each service's full name, the service
%% as it was given (for the error that names it), and its files. Files that
%% are not FileDescriptorProtos raise `{invalid_grpc_opt, service, Service}`,
%% which stops the listener from starting.
-doc false.
-spec index([{binary(), term(), term()}]) -> index().
index(Services) ->
    Files = unique_files(lists:flatmap(fun parsed_files/1, Services), #{}),
    Symbols = first_wins([
        {Symbol, Name}
     || {#{name := Name, symbols := Declared}, _Bytes} <- Files, Symbol <- Declared
    ]),
    #index{
        services = [Name || {Name, _Service, _Files} <- Services, is_map_key(Name, Symbols)],
        files =
            #{
                Name => {Bytes, Dependencies}
             || {#{name := Name, dependencies := Dependencies}, Bytes} <- Files
            },
        symbols = Symbols,
        extensions = first_wins([
            {Extension, Name}
         || {#{name := Name, extensions := Extensions}, _Bytes} <- Files,
            Extension <- Extensions
        ]),
        extension_numbers = extension_numbers(Files)
    }.

-spec parsed_files({binary(), term(), term()}) ->
    [{roadrunner_grpc_reflection_proto:file(), binary()}].
parsed_files({_Name, Service, Files}) ->
    try
        [{roadrunner_grpc_reflection_proto:file(Bytes), Bytes} || Bytes <- Files]
    catch
        error:_ -> error({invalid_grpc_opt, service, Service})
    end.

%% The files, the first of each name only.
-spec unique_files([{roadrunner_grpc_reflection_proto:file(), binary()}], #{binary() => true}) ->
    [{roadrunner_grpc_reflection_proto:file(), binary()}].
unique_files([], _Seen) ->
    [];
unique_files([{#{name := Name}, _Bytes} | Rest], Seen) when is_map_key(Name, Seen) ->
    unique_files(Rest, Seen);
unique_files([{#{name := Name}, _Bytes} = File | Rest], Seen) ->
    [File | unique_files(Rest, Seen#{Name => true})].

%% A map of the pairs, the first of each key kept.
-spec first_wins([{term(), binary()}]) -> #{term() => binary()}.
first_wins(Pairs) ->
    lists:foldl(
        fun({Key, Value}, Map) ->
            case Map of
                #{Key := _} -> Map;
                #{} -> Map#{Key => Value}
            end
        end,
        #{},
        Pairs
    ).

%% Each message's extension numbers, in order; a message no file declares
%% has none to tell.
-spec extension_numbers([{roadrunner_grpc_reflection_proto:file(), binary()}]) ->
    #{binary() => [non_neg_integer()]}.
extension_numbers(Files) ->
    Extensions = [
        Extension
     || {#{extensions := Extensions}, _Bytes} <- Files, Extension <- Extensions
    ],
    #{
        Message => lists:usort([Number || {Type, Number} <- Extensions, Type =:= Message])
     || {#{messages := Messages}, _Bytes} <- Files, Message <- Messages
    }.

%% `ServerReflectionInfo`: each request answered in turn, until the client
%% ends its requests. The files sent on the stream are not sent again as
%% another's imports.
-doc false.
-spec info(roadrunner_grpc:stream()) ->
    {ok, roadrunner_grpc:stream()}
    | {error, internal, binary(), roadrunner_grpc:stream()}.
info(Stream) ->
    serve(roadrunner_grpc:reflection_index(Stream), #{}, Stream).

-spec serve(index(), #{binary() => true}, roadrunner_grpc:stream()) ->
    {ok, roadrunner_grpc:stream()}
    | {error, internal, binary(), roadrunner_grpc:stream()}.
serve(Index, Sent, Stream0) ->
    case roadrunner_grpc:recv(Stream0) of
        {ok, Request, Stream} ->
            case roadrunner_grpc_reflection_proto:request(Request) of
                {ok, Host, Query} ->
                    {Answer, Sent1} = answer(Query, Index, Sent),
                    Response = roadrunner_grpc_reflection_proto:response(Host, Request, Answer),
                    serve(Index, Sent1, roadrunner_grpc:send(Response, Stream));
                malformed ->
                    {error, internal, ~"request message does not decode", Stream}
            end;
        {eof, Stream} ->
            {ok, Stream}
    end.

-spec answer(roadrunner_grpc_reflection_proto:query(), index(), #{binary() => true}) ->
    {roadrunner_grpc_reflection_proto:answer(), #{binary() => true}}.
answer(list_services, #index{services = Services}, Sent) ->
    {{services, Services}, Sent};
answer({file_by_filename, Name}, #index{files = Files} = Index, Sent) ->
    case Files of
        #{Name := _} -> files(Name, Index, Sent);
        #{} -> not_found(<<"unknown file ", Name/binary>>, Sent)
    end;
answer({file_containing_symbol, Symbol}, #index{symbols = Symbols} = Index, Sent) ->
    case Symbols of
        #{Symbol := Name} -> files(Name, Index, Sent);
        #{} -> not_found(<<"unknown symbol ", Symbol/binary>>, Sent)
    end;
answer({file_containing_extension, Type, Number}, #index{extensions = Extensions} = Index, Sent) ->
    case Extensions of
        #{{Type, Number} := Name} ->
            files(Name, Index, Sent);
        #{} ->
            not_found(
                <<"unknown extension ", (integer_to_binary(Number))/binary, " of ", Type/binary>>,
                Sent
            )
    end;
answer({all_extension_numbers_of_type, Type}, #index{extension_numbers = Numbers}, Sent) ->
    case Numbers of
        #{Type := Known} -> {{extension_numbers, Type, Known}, Sent};
        #{} -> not_found(<<"unknown message type ", Type/binary>>, Sent)
    end;
answer(none, _Index, Sent) ->
    {{error, ?INVALID_ARGUMENT, ~"no request in the message"}, Sent}.

-spec not_found(binary(), #{binary() => true}) ->
    {roadrunner_grpc_reflection_proto:answer(), #{binary() => true}}.
not_found(Message, Sent) ->
    {{error, ?NOT_FOUND, Message}, Sent}.

%% The file asked for, sent whether or not it was before, then its imports
%% all the way down that were not; an import no service gave is left out.
-spec files(binary(), index(), #{binary() => true}) ->
    {roadrunner_grpc_reflection_proto:answer(), #{binary() => true}}.
files(Name, #index{files = Files}, Sent) ->
    #{Name := {Bytes, Dependencies}} = Files,
    {Imports, Sent1} = imports(Dependencies, Files, Sent#{Name => true}),
    {{files, lists:flatten([Bytes | Imports])}, Sent1}.

-spec imports([binary()], #{binary() => {binary(), [binary()]}}, #{binary() => true}) ->
    {[term()], #{binary() => true}}.
imports([], _Files, Sent) ->
    {[], Sent};
imports([Name | Rest], Files, Sent) when is_map_key(Name, Sent) ->
    imports(Rest, Files, Sent);
imports([Name | Rest], Files, Sent) ->
    case Files of
        #{Name := {Bytes, Dependencies}} ->
            {Own, Sent1} = imports(Dependencies, Files, Sent#{Name => true}),
            {Others, Sent2} = imports(Rest, Files, Sent1),
            {[Bytes, Own | Others], Sent2};
        #{} ->
            imports(Rest, Files, Sent)
    end.
