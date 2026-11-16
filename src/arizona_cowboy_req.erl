-module(arizona_cowboy_req).
-moduledoc """
Cowboy adapter for the `arizona_req` behaviour.

The raw value is Cowboy's request map. Path bindings are the ones
`arizona_route_table` matched, stored on the request under Cowboy's own
`bindings` key (binary names, percent-decoded values), since no Cowboy router
matches an Arizona route.

The query string is parsed by `parse_qs/1` rather than Cowboy's
`cowboy_req:parse_qs/1`, which refuses a malformed escape with `400`.
""".

-behaviour(arizona_req).

%% --------------------------------------------------------------------
%% API function exports
%% --------------------------------------------------------------------

-export([new/1]).
-export([parse_qs/1]).

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
%% Macros
%% --------------------------------------------------------------------

-define(IS_HEX(C),
    ((C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) orelse (C >= $A andalso C =< $F))
).

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
browsers send such a URL as typed. Never fails.
""".
-spec parse_qs(Qs) -> [{binary(), binary() | true}] when
    Qs :: binary().
parse_qs(<<>>) ->
    [];
parse_qs(Qs) ->
    scan(Qs, Qs, 0, plain, <<>>, none, []).

%% --------------------------------------------------------------------
%% arizona_req behaviour callbacks
%% --------------------------------------------------------------------

-spec parse_bindings(cowboy_req:req()) -> arizona_req:bindings().
parse_bindings(CowboyReq) ->
    maps:get(bindings, CowboyReq, #{}).

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
`error` for anything but a live route; never crashes, never replies.
""".
-spec resolve_route(Path, Qs, CowboyReq) -> {ok, Handler, RouteOpts, ArzReq} | error when
    Path :: arizona_req:path(),
    Qs :: arizona_req:qs(),
    CowboyReq :: cowboy_req:req(),
    Handler :: module(),
    RouteOpts :: arizona_live:route_opts(),
    ArzReq :: arizona_req:request().
resolve_route(Path, Qs, #{ref := Listener} = CowboyReq) when is_binary(Path) ->
    case arizona_route_table:match(~"GET", Path, arizona_cowboy_server:table(Listener)) of
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

%% One pass over the query string. Each key or value is the `Len` bytes from
%% `Start`, read in one of three modes: `plain` while it holds no `+` or `%`
%% (returned as that slice, no copy), `dec` once one decoded (built in `Acc`),
%% and `raw` after an escape that does not decode (the slice again, its `+`
%% turned to spaces). `Key` is `none` while reading a key.
scan(<<$&, Rest/binary>>, Start, Len, Mode, Acc, Key, Pairs) ->
    scan(Rest, Rest, 0, plain, <<>>, none, emit(Start, Len, Mode, Acc, Key, Pairs));
scan(<<$=, Rest/binary>>, Start, Len, Mode, Acc, none, Pairs) ->
    scan(Rest, Rest, 0, plain, <<>>, {key, component(Start, Len, Mode, Acc)}, Pairs);
scan(<<_Byte, Rest/binary>>, Start, Len, raw, Acc, Key, Pairs) ->
    scan(Rest, Start, Len + 1, raw, Acc, Key, Pairs);
scan(<<$+, Rest/binary>>, Start, Len, Mode, Acc, Key, Pairs) ->
    scan(Rest, Start, Len + 1, dec, <<(decoded(Start, Len, Mode, Acc))/binary, $\s>>, Key, Pairs);
scan(<<$%, High, Low, Rest/binary>>, Start, Len, Mode, Acc, Key, Pairs) when
    ?IS_HEX(High), ?IS_HEX(Low)
->
    Octet = unhex(High) * 16 + unhex(Low),
    scan(Rest, Start, Len + 3, dec, <<(decoded(Start, Len, Mode, Acc))/binary, Octet>>, Key, Pairs);
scan(<<$%, Rest/binary>>, Start, Len, _Mode, Acc, Key, Pairs) ->
    scan(Rest, Start, Len + 1, raw, Acc, Key, Pairs);
scan(<<_Byte, Rest/binary>>, Start, Len, plain, Acc, Key, Pairs) ->
    scan(Rest, Start, Len + 1, plain, Acc, Key, Pairs);
scan(<<Byte, Rest/binary>>, Start, Len, dec, Acc, Key, Pairs) ->
    scan(Rest, Start, Len + 1, dec, <<Acc/binary, Byte>>, Key, Pairs);
scan(<<>>, Start, Len, Mode, Acc, Key, Pairs) ->
    lists:reverse(emit(Start, Len, Mode, Acc, Key, Pairs)).

%% An empty pair (`&&`, a leading or trailing `&`) is skipped.
emit(_Start, 0, _Mode, _Acc, none, Pairs) ->
    Pairs;
emit(Start, Len, Mode, Acc, none, Pairs) ->
    [{component(Start, Len, Mode, Acc), true} | Pairs];
emit(Start, Len, Mode, Acc, {key, Key}, Pairs) ->
    [{Key, component(Start, Len, Mode, Acc)} | Pairs].

component(Start, Len, plain, _Acc) ->
    binary:part(Start, 0, Len);
component(_Start, _Len, dec, Acc) ->
    Acc;
component(Start, Len, raw, _Acc) ->
    binary:replace(binary:part(Start, 0, Len), ~"+", ~" ", [global]).

%% What is decoded so far, the slice read until now when nothing was.
decoded(Start, Len, plain, _Acc) -> binary:part(Start, 0, Len);
decoded(_Start, _Len, dec, Acc) -> Acc.

unhex(C) when C =< $9 -> C - $0;
unhex(C) when C =< $F -> C - $A + 10;
unhex(C) -> C - $a + 10.

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
