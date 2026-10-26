-module(roadrunner_conn_info_handler).
-moduledoc false.

%% Test handler for `roadrunner_conn_info_SUITE`: answers with what
%% `roadrunner_req:sockname/1`, `peercert/1` and `tls_info/1` return, as an
%% external term (the TLS info cut to its protocol and cipher suite).

-behaviour(roadrunner_handler).

-export([handle/1]).

handle(Req) ->
    Info = #{
        sockname => roadrunner_req:sockname(Req),
        peercert => roadrunner_req:peercert(Req),
        tls_info => tls_info(roadrunner_req:tls_info(Req))
    },
    {{200, [], term_to_binary(Info)}, Req}.

tls_info({ok, Info}) ->
    {ok, maps:with([protocol, selected_cipher_suite], maps:from_list(Info))};
tls_info({error, _} = Error) ->
    Error.
