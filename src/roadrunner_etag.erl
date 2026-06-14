-module(roadrunner_etag).
-moduledoc false.

%% Conditional-request middleware for dynamic responses (RFC 7232, RFC 9110
%% §13.1.2). For a `GET` or `HEAD` answered with a buffered `200`, it derives
%% a weak `ETag` from the response body (or honours one the handler already
%% set) and turns a matching `If-None-Match` into a bodyless `304 Not
%% Modified`, saving the body bytes on a cache revalidation.
%%
%% Add it to a listener's `middlewares` opt (or a map-shape route's
%% `middlewares` key):
%%
%% ```erlang
%% roadrunner_listener:start_link(my_api, #{
%%     port => 8080,
%%     routes => Routes,
%%     middlewares => [roadrunner_etag]
%% }).
%% ```
%%
%% The ETag is WEAK (`W/"..."`). A weak validator is the correct kind here:
%% a downstream transform may re-encode the body (e.g. `roadrunner_compress`
%% gzipping it), so the strong-validator contract — byte-for-byte identity of
%% the transferred representation — would no longer hold. `If-None-Match` is
%% matched with the RFC 7232 §2.3.2 weak comparison: the opaque-tags are
%% compared and the `W/` prefix is ignored on either side, so a client that
%% echoes a strong or weak form of the tag still revalidates. `*` matches any
%% current representation.
%%
%% Scope: only a buffered `200` for a `GET` / `HEAD` is handled; every other
%% status, method, and response shape (`{stream, _}`, `{loop, _}`,
%% `{sendfile, _}`, `{websocket, _}`) passes through untouched. Deriving the
%% digest walks the whole body once per response, so this is opt-in: reach
%% for it on read-heavy endpoints where saving the body on revalidation
%% outweighs the hash.

-behaviour(roadrunner_middleware).

-export([init/1, call/3]).

%% No per-instance config — the validator is derived from the response body
%% and the request's `If-None-Match` per request, so the compiled state is
%% just the empty map.
-type state() :: #{}.

-spec init(roadrunner_middleware:config()) -> state().
init(_Config) ->
    #{}.

-spec call(roadrunner_req:request(), roadrunner_middleware:next(), state()) ->
    roadrunner_handler:result().
call(Req, Next, _State) ->
    {Response, Req2} = Next(Req),
    {transform(Req, Response), Req2}.

%% Only a buffered 200 on a conditional-safe method is eligible; every other
%% status / method and the streaming / loop / sendfile / websocket shapes
%% pass through.
-spec transform(roadrunner_req:request(), roadrunner_handler:response()) ->
    roadrunner_handler:response().
transform(Req, {200, Headers, Body} = Response) ->
    case conditional_method(roadrunner_req:method(Req)) of
        true -> conditional(Req, Headers, Body);
        false -> Response
    end;
transform(_Req, Other) ->
    Other.

-spec conditional_method(binary()) -> boolean().
conditional_method(~"GET") -> true;
conditional_method(~"HEAD") -> true;
conditional_method(_) -> false.

%% Resolve the ETag, then either answer 304 when the client's If-None-Match
%% validates it or attach it to the 200 so the client can revalidate next time.
-spec conditional(roadrunner_req:request(), roadrunner_http:headers(), iodata()) ->
    roadrunner_handler:response().
conditional(Req, Headers, Body) ->
    ETag = etag(Headers, Body),
    case roadrunner_req:header(~"if-none-match", Req) of
        undefined ->
            {200, with_etag(Headers, ETag), Body};
        IfNoneMatch ->
            case if_none_match(IfNoneMatch, ETag) of
                true -> not_modified(Headers, ETag);
                false -> {200, with_etag(Headers, ETag), Body}
            end
    end.

%% A handler-set ETag wins; otherwise a weak digest of the body.
-spec etag(roadrunner_http:headers(), iodata()) -> binary().
etag(Headers, Body) ->
    case lists:keyfind(~"etag", 1, Headers) of
        {_, ETag} -> ETag;
        false -> weak_etag(Body)
    end.

-spec weak_etag(iodata()) -> binary().
weak_etag(Body) ->
    Hex = binary:encode_hex(crypto:hash(md5, Body), lowercase),
    <<"W/", $", Hex/binary, $">>.

-spec with_etag(roadrunner_http:headers(), binary()) -> roadrunner_http:headers().
with_etag(Headers, ETag) ->
    case lists:keymember(~"etag", 1, Headers) of
        true -> Headers;
        false -> [{~"etag", ETag} | Headers]
    end.

%% RFC 7232 §4.1: a 304 carries no body and echoes the cache-relevant header
%% fields a 200 would have (Cache-Control, Vary, Expires, ...). Keep the
%% handler's headers, drop the body's Content-Type, force Content-Length to 0,
%% and ensure the validator is present.
-spec not_modified(roadrunner_http:headers(), binary()) -> roadrunner_handler:response().
not_modified(Headers, ETag) ->
    Kept = lists:keydelete(~"content-type", 1, with_etag(Headers, ETag)),
    {304, lists:keystore(~"content-length", 1, Kept, {~"content-length", ~"0"}), ~""}.

%% RFC 7232 §3.2: If-None-Match is `*` (matches any current representation) or
%% a comma-separated entity-tag list, matched with the weak comparison
%% (§2.3.2) — opaque-tags compared, the `W/` prefix ignored on either side.
-spec if_none_match(binary(), binary()) -> boolean().
if_none_match(IfNoneMatch, ETag) ->
    case roadrunner_bin:trim_ows(IfNoneMatch) of
        ~"*" -> true;
        _ -> lists:member(opaque_tag(ETag), entity_tags(IfNoneMatch))
    end.

%% Strip the weak prefix, leaving the quoted opaque-tag for comparison.
-spec opaque_tag(binary()) -> binary().
opaque_tag(<<"W/", Quoted/binary>>) -> Quoted;
opaque_tag(Quoted) -> Quoted.

%% Split an If-None-Match list into its opaque-tags (the quoted runs),
%% quote-aware so a comma inside a tag does not split it. The `W/` prefixes
%% and the inter-entry commas / whitespace fall outside the quotes.
-spec entity_tags(binary()) -> [binary()].
entity_tags(Bin) ->
    case binary:split(Bin, ~"\"", [global]) of
        [_NoQuotes] -> [];
        [_Before | Quoted] -> quoted_runs(Quoted)
    end.

-spec quoted_runs([binary()]) -> [binary()].
quoted_runs([Content, _Between | Rest]) ->
    [<<$", Content/binary, $">> | quoted_runs(Rest)];
quoted_runs(_) ->
    [].
