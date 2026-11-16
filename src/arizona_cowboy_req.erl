-module(arizona_cowboy_req).
-moduledoc """
Cowboy adapter for the `arizona_req` behaviour.

The raw value is Cowboy's request map. Path bindings are the ones
`arizona_route_table` matched, stored on the request under Cowboy's own
`bindings` key (binary names, percent-decoded values), since no Cowboy router
matches an Arizona route.

The query string is parsed by `parse_qs/2` rather than Cowboy's
`cowboy_req:parse_qs/1`, which refuses a malformed escape with `400`. It keeps
Cowboy's limit on the number of keys, the listener's `max_query_keys`
(default `100`, Cowboy's own): a query with more is answered `400` over HTTP and
on a WebSocket upgrade, as Cowboy answers it, and a navigate to it is left
unresolved, so the client loads it over HTTP and gets that answer.
""".

-behaviour(arizona_req).

-on_load(init_patterns/0).

%% Cowboy's own default.
-define(MAX_KEYS, 100).

%% --------------------------------------------------------------------
%% API function exports
%% --------------------------------------------------------------------

-export([new/1]).
-export([parse_qs/1]).
-export([parse_qs/2]).

%% --------------------------------------------------------------------
%% arizona_req callbacks
%% --------------------------------------------------------------------

-export([parse_bindings/1]).
-export([parse_params/1]).
-export([parse_cookies/1]).
-export([parse_headers/1]).
-export([read_body/1]).
-export([scheme/1]).
-export([peer/1]).
-export([resolve_route/3]).

%% --------------------------------------------------------------------
%% API Functions
%% --------------------------------------------------------------------

-doc "Wraps a Cowboy request in an `arizona_req:request()`.".
-spec new(CowboyReq) -> arizona_req:request() when
    CowboyReq :: cowboy_req:req().
new(CowboyReq) ->
    arizona_req:new(?MODULE, CowboyReq, #{
        method => cowboy_req:method(CowboyReq),
        path => cowboy_req:path(CowboyReq)
    }).

-doc """
Parses a raw query string as form encoding, into its `{Key, Value}` pairs in
order, repeated keys kept: `+` is a space and each `%HH` escape the octet it
encodes, UTF-8 or not, and a bare key (`?debug`) is `true`. Empty pairs are
skipped. A key or value holding an escape that does not decode (`%G1`, a
trailing `%4` or `%`) is kept as written, only its `+` turned to spaces, as
browsers send such a URL as typed. At most 100 keys, as `parse_qs/2`.
""".
-spec parse_qs(Qs) -> [{binary(), binary() | true}] when
    Qs :: binary().
parse_qs(Qs) ->
    parse_qs(Qs, ?MAX_KEYS).

-doc """
As `parse_qs/1`, refusing a query string with more than `MaxKeys` keys (empty
pairs are none) the way Cowboy's own parser does: it exits with
`{request_error, limit_reached, _}`, which Cowboy answers `400`. A cap on what
one request makes the server build, which roadrunner's parser does not have.
""".
-spec parse_qs(Qs, MaxKeys) -> [{binary(), binary() | true}] when
    Qs :: binary(),
    MaxKeys :: non_neg_integer().
parse_qs(<<>>, _MaxKeys) ->
    [];
parse_qs(Qs, MaxKeys) ->
    {Amp, Eq, Plus, Pct} = persistent_term:get(?MODULE),
    Pairs = split_pairs(Qs, Amp, MaxKeys),
    %% One scan of the whole string first: with no `+` or `%` in it, the usual
    %% `?id=123&limit=50`, no key or value needs decoding.
    case is_plain(Qs, Plus, Pct) of
        true -> [split_pair(Pair, Eq) || Pair <- Pairs];
        false -> [decode_pair(Pair, Eq, Plus, Pct) || Pair <- Pairs]
    end.

%% --------------------------------------------------------------------
%% arizona_req behaviour callbacks
%% --------------------------------------------------------------------

-spec parse_bindings(cowboy_req:req()) -> arizona_req:bindings().
parse_bindings(CowboyReq) ->
    maps:get(bindings, CowboyReq, #{}).

-spec parse_params(cowboy_req:req()) -> arizona_req:params().
parse_params(#{ref := Listener} = CowboyReq) ->
    parse_qs(cowboy_req:qs(CowboyReq), arizona_cowboy_server:max_query_keys(Listener)).

-spec parse_cookies(cowboy_req:req()) -> arizona_req:cookies().
parse_cookies(CowboyReq) ->
    cowboy_req:parse_cookies(CowboyReq).

%% Cowboy already lowercases names and combines a repeated field.
-spec parse_headers(cowboy_req:req()) -> arizona_req:headers().
parse_headers(CowboyReq) ->
    cowboy_req:headers(CowboyReq).

-spec read_body(CowboyReq) ->
    {ok, arizona_req:body(), CowboyReq} | {error, arizona_req:body_error()}
when
    CowboyReq :: cowboy_req:req().
read_body(#{ref := Listener} = CowboyReq) ->
    try
        read_body(CowboyReq, [], 0, arizona_cowboy_server:max_content_length(Listener))
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:timeout -> {error, timeout}
    end.

-spec scheme(cowboy_req:req()) -> arizona_req:scheme().
scheme(CowboyReq) ->
    case cowboy_req:scheme(CowboyReq) of
        ~"https" -> https;
        ~"http" -> http
    end.

-spec peer(cowboy_req:req()) -> {inet:ip_address(), inet:port_number()}.
peer(CowboyReq) ->
    cowboy_req:peer(CowboyReq).

-doc """
Resolves a navigate target against the routes of the listener that accepted
`CowboyReq`, matched as a `GET` (an HTTP/2 WebSocket upgrade is a `CONNECT`).
`error` for anything but a live route, and for a query string with more keys
than the listener allows (which an HTTP request to it is answered `400` for);
never crashes, never replies.
""".
-spec resolve_route(Path, Qs, CowboyReq) -> {ok, Handler, RouteOpts, ArzReq} | error when
    Path :: arizona_req:path(),
    Qs :: arizona_req:qs(),
    CowboyReq :: cowboy_req:req(),
    Handler :: module(),
    RouteOpts :: arizona_live:route_opts(),
    ArzReq :: arizona_req:request().
resolve_route(Path, Qs, #{ref := Listener} = CowboyReq) when is_binary(Path) ->
    case
        within_key_limit(Qs, Listener) andalso
            arizona_route_table:match(~"GET", Path, arizona_cowboy_server:table(Listener))
    of
        {ok, #{kind := live, target := #{handler := Handler} = Live}, Bindings} ->
            NavReq = CowboyReq#{path => Path, qs => Qs, bindings => Bindings},
            {ok, Handler, maps:without([handler], Live), new(NavReq)};
        _NotALivePage ->
            error
    end;
resolve_route(_Path, _Qs, _CowboyReq) ->
    error.

%% --------------------------------------------------------------------
%% Internal functions
%% --------------------------------------------------------------------

%% The patterns `parse_qs/1` splits and scans with, compiled once at load
%% rather than on every call. Each is one byte: a search for one byte runs far
%% faster than one for several.
init_patterns() ->
    persistent_term:put(?MODULE, {
        binary:compile_pattern(~"&"),
        binary:compile_pattern(~"="),
        binary:compile_pattern(~"+"),
        binary:compile_pattern(~"%")
    }).

within_key_limit(Qs, Listener) ->
    try parse_qs(Qs, arizona_cowboy_server:max_query_keys(Listener)) of
        _Params -> true
    catch
        exit:{request_error, limit_reached, _Reason} -> false
    end.

%% The non-empty pairs of `Qs`. A string no longer than `2 * MaxKeys` cannot
%% hold more than `MaxKeys` of them and is split whole; a longer one is split
%% pair by pair, so a huge one is refused before it is all built.
split_pairs(Qs, Amp, MaxKeys) when byte_size(Qs) =< 2 * MaxKeys ->
    [Pair || Pair <- binary:split(Qs, Amp, [global]), Pair =/= <<>>];
split_pairs(Qs, Amp, MaxKeys) ->
    split_pairs(Qs, Amp, 0, MaxKeys, []).

split_pairs(Qs, Amp, Pos, Left, Acc) ->
    Size = byte_size(Qs),
    case binary:match(Qs, Amp, [{scope, {Pos, Size - Pos}}]) of
        nomatch ->
            lists:reverse(add_pair(binary:part(Qs, Pos, Size - Pos), Left, Acc));
        {At, 1} when At =:= Pos -> split_pairs(Qs, Amp, At + 1, Left, Acc);
        {At, 1} ->
            split_pairs(
                Qs, Amp, At + 1, Left - 1, add_pair(binary:part(Qs, Pos, At - Pos), Left, Acc)
            )
    end.

add_pair(<<>>, _Left, Acc) -> Acc;
add_pair(_Pair, 0, _Acc) -> limit_reached();
add_pair(Pair, _Left, Acc) -> [Pair | Acc].

%% What Cowboy's own parser exits with, which Cowboy answers `400`.
limit_reached() ->
    exit({request_error, limit_reached, 'Limit reached while parsing query string.'}).

%% Neither a `+` nor a `%` in `Bin`, so nothing to decode.
is_plain(Bin, Plus, Pct) ->
    binary:match(Bin, Plus) =:= nomatch andalso binary:match(Bin, Pct) =:= nomatch.

split_pair(Pair, Eq) ->
    case binary:split(Pair, Eq) of
        [Key] -> {Key, true};
        [Key, Value] -> {Key, Value}
    end.

%% Most pairs of a query holding a `+` or `%` somewhere hold neither.
decode_pair(Pair, Eq, Plus, Pct) ->
    case is_plain(Pair, Plus, Pct) of
        true ->
            split_pair(Pair, Eq);
        false ->
            case binary:split(Pair, Eq) of
                [Key] -> {decode(Key, Plus, Pct), true};
                [Key, Value] -> {decode(Key, Plus, Pct), decode(Value, Plus, Pct)}
            end
    end.

%% A key or value as it is up to its first `+` or `%`, and decoded byte by
%% byte from there. When an escape does not decode, it is kept as written, only
%% its `+` turned to spaces.
decode(Component, Plus, Pct) ->
    At =
        case {binary:match(Component, Plus), binary:match(Component, Pct)} of
            {nomatch, nomatch} -> byte_size(Component);
            {nomatch, {AtPct, 1}} -> AtPct;
            {{AtPlus, 1}, nomatch} -> AtPlus;
            {{AtPlus, 1}, {AtPct, 1}} -> min(AtPlus, AtPct)
        end,
    <<Before:At/binary, Rest/binary>> = Component,
    case unescape(Rest, Before) of
        error -> binary:replace(Component, Plus, ~" ", [global]);
        Decoded -> Decoded
    end.

unescape(<<$%, High, Low, Rest/binary>>, Acc) ->
    case hex(High) of
        error ->
            error;
        H ->
            case hex(Low) of
                error -> error;
                L -> unescape(Rest, <<Acc/binary, (H * 16 + L)>>)
            end
    end;
unescape(<<$%, _Truncated/binary>>, _Acc) ->
    error;
unescape(<<$+, Rest/binary>>, Acc) ->
    unescape(Rest, <<Acc/binary, $\s>>);
unescape(<<Byte, Rest/binary>>, Acc) ->
    unescape(Rest, <<Acc/binary, Byte>>);
unescape(<<>>, Acc) ->
    Acc.

hex(C) when C >= $0, C =< $9 -> C - $0;
hex(C) when C >= $a, C =< $f -> C - $a + 10;
hex(C) when C >= $A, C =< $F -> C - $A + 10;
hex(_C) -> error.

%% A body larger than `Max` is refused (`too_large`) rather than buffered.
read_body(CowboyReq0, Acc, Size, Max) ->
    case cowboy_req:read_body(CowboyReq0) of
        {ok, Data, CowboyReq} when Size + byte_size(Data) =< Max ->
            {ok, iolist_to_binary(lists:reverse([Data | Acc])), CowboyReq};
        {more, Data, CowboyReq} when Size + byte_size(Data) =< Max ->
            read_body(CowboyReq, [Data | Acc], Size + byte_size(Data), Max);
        {_OkOrMore, _Data, _CowboyReq} ->
            {error, too_large}
    end.
