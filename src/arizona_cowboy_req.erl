-module(arizona_cowboy_req).
-moduledoc """
Cowboy adapter for the `arizona_req` behaviour.

The raw value is Cowboy's request map. Path bindings are the ones
`arizona_route_table` matched, stored on the request under Cowboy's own
`bindings` key (binary names, percent-decoded values), since no Cowboy router
matches an Arizona route.

The query string is parsed by `parse_qs/1` rather than Cowboy's
`cowboy_req:parse_qs/1`, which refuses a malformed escape with `400`. Its keys
are counted once, before anything reads it (`within_key_limit/3`): a request
to a live or controller route, or a WebSocket upgrade, whose query holds more
than the listener's `max_query_keys` is answered `400` whether or not the route
reads it (on the upgrade, the keys Arizona's client adds are not counted), and
`resolve_route/3` leaves a navigate or patch to one unresolved, so the client
loads it over HTTP and gets that `400` too. `parse_params/1` itself sets no
limit.
""".

-behaviour(arizona_req).

-on_load(init_patterns/0).

%% 64 empty pairs, skipped in one comparison.
-define(AMP64, <<"&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&">>).

%% --------------------------------------------------------------------
%% API function exports
%% --------------------------------------------------------------------

-export([new/1]).
-export([parse_qs/1]).
-export([within_key_limit/3]).

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
browsers send such a URL as typed. It sets no limit on the number of keys:
check that first, with `within_key_limit/3`.
""".
-spec parse_qs(Qs) -> [{binary(), binary() | true}] when
    Qs :: binary().
parse_qs(<<>>) ->
    [];
parse_qs(Qs) ->
    {Amp, Eq, Plus, Pct, AmpRun} = persistent_term:get(?MODULE),
    Pairs = pairs(Qs, Amp, AmpRun),
    %% One scan of the whole string first: with no `+` or `%` in it, the usual
    %% `?id=123&limit=50`, no key or value needs decoding.
    case is_plain(Qs, Plus, Pct) of
        true -> [split_pair(Pair, Eq) || Pair <- Pairs];
        false -> [decode_pair(Pair, Eq, Plus, Pct) || Pair <- Pairs]
    end.

-doc """
Whether the raw query string `Qs` holds at most `MaxKeys` keys: its non-empty
pairs, an empty one (`&&`, a leading or trailing `&`) counting for none. Each
key in `Uncounted` (as written, before `=`) is not counted the first time it
occurs; a repeat is. `infinity` counts nothing. Counting stops at the first
key past the limit, and a run of empty pairs is skipped without looking for
each `&`, so the cost is bounded by the limit and the string's length, not by
its number of `&`.
""".
-spec within_key_limit(Qs, MaxKeys, Uncounted) -> boolean() when
    Qs :: binary(),
    MaxKeys :: non_neg_integer() | infinity,
    Uncounted :: [binary()].
within_key_limit(_Qs, infinity, _Uncounted) ->
    true;
within_key_limit(Qs, MaxKeys, Uncounted) ->
    {Amp, Eq, _Plus, _Pct, _AmpRun} = persistent_term:get(?MODULE),
    count_keys(skip_empty(Qs), MaxKeys, Uncounted, Amp, Eq).

%% --------------------------------------------------------------------
%% arizona_req behaviour callbacks
%% --------------------------------------------------------------------

-spec parse_bindings(cowboy_req:req()) -> arizona_req:bindings().
parse_bindings(CowboyReq) ->
    maps:get(bindings, CowboyReq, #{}).

%% The listener counted the keys before the request reached its route.
-spec parse_params(cowboy_req:req()) -> arizona_req:params().
parse_params(CowboyReq) ->
    parse_qs(cowboy_req:qs(CowboyReq)).

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
`error` for anything but a live route, and for a query string holding more
keys than the listener's `max_query_keys` (counted by `within_key_limit/3`,
with nothing uncounted), which an HTTP request to that URL is answered `400`
for: the client then loads it over HTTP. Never crashes, never replies.
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
        within_key_limit(Qs, arizona_cowboy_server:max_query_keys(Listener), []) andalso
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

%% The patterns `parse_qs/1` and `within_key_limit/3` split and scan with,
%% compiled once at load rather than on every call.
init_patterns() ->
    persistent_term:put(?MODULE, {
        binary:compile_pattern(~"&"),
        binary:compile_pattern(~"="),
        binary:compile_pattern(~"+"),
        binary:compile_pattern(~"%"),
        binary:compile_pattern(?AMP64)
    }).

count_keys(<<>>, _Left, _Uncounted, _Amp, _Eq) ->
    true;
count_keys(Qs, Left, Uncounted, Amp, Eq) ->
    {Pair, Rest} = next_pair(Qs, Amp),
    [Key | _Value] = binary:split(Pair, Eq),
    case lists:member(Key, Uncounted) of
        true -> count_keys(skip_empty(Rest), Left, lists:delete(Key, Uncounted), Amp, Eq);
        false when Left =:= 0 -> false;
        false -> count_keys(skip_empty(Rest), Left - 1, Uncounted, Amp, Eq)
    end.

%% The non-empty pairs of `Qs`: one split of the whole string, its empty pieces
%% dropped as it splits (`trim_all`), unless it holds a run of 64 empty pairs
%% or more, which is then skipped rather than searched `&` by `&`. Looking for
%% such a run costs little: a long pattern is searched in long strides.
pairs(Qs, Amp, AmpRun) ->
    case binary:match(Qs, AmpRun) of
        nomatch -> binary:split(Qs, Amp, [global, trim_all]);
        _Run -> split_pairs(skip_empty(Qs), Amp)
    end.

%% The non-empty pairs of `Qs`, which starts with one (or is empty).
split_pairs(<<>>, _Amp) ->
    [];
split_pairs(Qs, Amp) ->
    {Pair, Rest} = next_pair(Qs, Amp),
    [Pair | split_pairs(skip_empty(Rest), Amp)].

%% The pair `Qs` starts with, and what follows its `&`.
next_pair(Qs, Amp) ->
    case binary:match(Qs, Amp) of
        nomatch -> {Qs, <<>>};
        {At, 1} -> {binary:part(Qs, 0, At), binary:part(Qs, At + 1, byte_size(Qs) - At - 1)}
    end.

%% A run of empty pairs skipped, 64 per comparison: never a pair built and
%% dropped, nor a search per `&`.
skip_empty(<<Run:64/binary, Rest/binary>>) when Run =:= ?AMP64 ->
    skip_empty(Rest);
skip_empty(<<$&, Rest/binary>>) ->
    skip_empty(Rest);
skip_empty(Rest) ->
    Rest.

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
