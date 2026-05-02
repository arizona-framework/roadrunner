-module(roadrunner_test_certs).
-moduledoc """
Test fixture — generates a self-signed test PKI via
`public_key:pkix_test_data/1` once per Erlang VM session and caches
the result in `persistent_term`. RSA keygen is slow, so callers
share certs across tests.
""".

-export([server_opts/0, client_opts/0]).

-spec server_opts() -> [ssl:tls_server_option()].
server_opts() ->
    maps:get(server_config, certs()).

-spec client_opts() -> [ssl:tls_client_option()].
client_opts() ->
    maps:get(client_config, certs()).

certs() ->
    case persistent_term:get({?MODULE, certs}, undefined) of
        undefined ->
            Certs = generate(),
            persistent_term:put({?MODULE, certs}, Certs),
            Certs;
        Cached ->
            Cached
    end.

generate() ->
    Key = fun() -> public_key:generate_key({rsa, 2048, 65537}) end,
    public_key:pkix_test_data(#{
        server_chain => #{
            root => [{key, Key()}, {digest, sha256}],
            peer => [{key, Key()}, {digest, sha256}]
        },
        client_chain => #{
            root => [{key, Key()}, {digest, sha256}],
            peer => [{key, Key()}, {digest, sha256}]
        }
    }).
