-module(arizona_cowboy_escapes_SUITE).
-moduledoc """
How a listener `arizona_cowboy_server` started reads the escapes of a request's
path and query string: a malformed escape is kept as written rather than
refused, and an escape decodes to its octet whether or not it is UTF-8, so an
asset name that is not UTF-8 is looked up as such. Arizona's conformance suite
pins the same rules across adapters; these cases keep this package covered on
its own.
""".
-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).

-export([path_with_a_malformed_escape_keeps_its_segment_raw/1]).
-export([query_with_a_malformed_escape_keeps_it_raw/1]).
-export([parse_qs_reads_form_encoding_leniently/1]).
-export([paths_no_route_matches_keep_the_routers_answers/1]).
-export([options_star_is_no_arizona_path/1]).
-export([asset_missing_non_utf8_file_is_404/1]).
-export([asset_non_utf8_file_is_served/1]).
-export([asset_link_to_a_non_utf8_name_is_followed_inside_only/1]).
-export([asset_dir_whose_name_is_not_utf8_serves/1]).
-export([asset_extension_that_is_not_utf8_is_octet_stream/1]).
-export([asset_link_into_a_sibling_sharing_the_dir_prefix_is_404/1]).
-export([asset_traversal_is_refused_in_every_encoding/1]).
-export([ws_upgrade_with_a_malformed_query_escape_opens/1]).
-export([navigate_target_with_a_malformed_query_escape_resolves/1]).

-define(LISTENER, escapes).
-define(PARAMS, [{~"locale", ~"%G1"}, {~"x", ~"%4"}]).

all() ->
    [
        path_with_a_malformed_escape_keeps_its_segment_raw,
        query_with_a_malformed_escape_keeps_it_raw,
        parse_qs_reads_form_encoding_leniently,
        paths_no_route_matches_keep_the_routers_answers,
        options_star_is_no_arizona_path,
        asset_missing_non_utf8_file_is_404,
        asset_non_utf8_file_is_served,
        asset_link_to_a_non_utf8_name_is_followed_inside_only,
        asset_dir_whose_name_is_not_utf8_serves,
        asset_extension_that_is_not_utf8_is_octet_stream,
        asset_link_into_a_sibling_sharing_the_dir_prefix_is_404,
        asset_traversal_is_refused_in_every_encoding,
        ws_upgrade_with_a_malformed_query_escape_opens,
        navigate_target_with_a_malformed_query_escape_resolves
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(arizona),
    Priv = ?config(priv_dir, Config),
    Dir = filename:join(Priv, "assets"),
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(filename:join(Dir, "app.txt"), ~"asset-bytes"),
    ok = file:write_file(filename:join(Dir, <<"f", 255, ".txt">>), ~"octet-bytes"),
    ok = file:write_file(filename:join(Dir, <<"a.", 255, 254>>), ~"ext-bytes"),
    ok = file:write_file(filename:join(Dir, "upper.TXT"), ~"upper-bytes"),
    %% Beside (not under) the asset dir: what a traversal would reach.
    ok = file:write_file(filename:join(Priv, "secret.txt"), ~"top-secret-bytes"),
    ok = file:write_file(filename:join(Priv, <<"s", 255>>), ~"top-secret-bytes"),
    %% Links whose targets are not UTF-8: one inside the dir, one beyond it.
    ok = file:make_symlink(<<"f", 255, ".txt">>, filename:join(Dir, "inner.txt")),
    ok = file:make_symlink(<<"../s", 255>>, filename:join(Dir, "outer.txt")),
    %% A sibling whose name starts with the asset dir's: `assets2` is not inside
    %% `assets`, though its path has that prefix.
    ok = filelib:ensure_path(filename:join(Priv, "assets2")),
    ok = file:write_file(filename:join([Priv, "assets2", "secret.txt"]), ~"top-secret-bytes"),
    ok = file:make_symlink("../assets2/secret.txt", filename:join(Dir, "sib.txt")),
    Port = pick_port(),
    {ok, _} = arizona_cowboy_server:start(?LISTENER, #{
        transport_opts => [{port, Port}],
        routes => [
            {get, ~"/items/:id", arizona_cowboy_echo_controller, #{}},
            {get, ~"/q", arizona_cowboy_echo_controller, #{}},
            {asset, ~"/files", {dir, Dir}, #{}},
            %% Mounts only when the query reaches it as ?PARAMS.
            {live, ~"/live", arizona_cowboy_echo_page, #{
                middlewares => [
                    fun(Req, B) ->
                        case arizona_req:params(Req) of
                            {?PARAMS, Req1} -> {cont, Req1, B};
                            {_Other, Req1} -> {halt, arizona_req:put_resp_status(Req1, 422)}
                        end
                    end
                ]
            }},
            {ws, ~"/ws", #{}}
        ]
    }),
    [{port, Port} | Config].

end_per_suite(Config) when is_list(Config) ->
    ok = arizona_cowboy_server:stop(?LISTENER),
    ok = application:stop(arizona).

%% --------------------------------------------------------------------
%% Cases
%% --------------------------------------------------------------------

%% Cowboy's router answers such a path `400`; Arizona's matcher sees it first,
%% keeps the segment whole as written, and still decodes a well-formed one to
%% its octets (`+` is no space in a path).
path_with_a_malformed_escape_keeps_its_segment_raw(Config) ->
    [
        ?assertMatch(
            {200, #{bindings := #{~"id" := Expected}}},
            echo(Config, <<"/items/", Segment/binary>>)
        )
     || {Segment, Expected} <- [
            {~"%G1", ~"%G1"},
            {~"a%41%G1", ~"a%41%G1"},
            {~"%4", ~"%4"},
            {~"a%", ~"a%"},
            {~"%FF", <<255>>},
            {~"a+b%41", ~"a+bA"}
        ]
    ].

%% `cowboy_req:parse_qs/1` refuses these with `400`.
query_with_a_malformed_escape_keeps_it_raw(Config) ->
    ?assertMatch(
        {200, #{
            params := [
                {~"locale", ~"%G1"},
                {~"x", ~"%4"},
                {~"y", ~"a %G1"},
                {~"f", <<255>>},
                {~"flag", true},
                {~"z", ~"%"}
            ]
        }},
        echo(Config, ~"/q?locale=%G1&x=%4&y=a+%G1&f=%FF&flag&&z=%")
    ).

parse_qs_reads_form_encoding_leniently(Config) when is_list(Config) ->
    ?assertEqual([], arizona_cowboy_req:parse_qs(<<>>)),
    ?assertEqual([], arizona_cowboy_req:parse_qs(~"&&")),
    ?assertEqual(
        [
            {~"a", ~"1"},
            {~"a", ~"2"},
            {~"b c", ~"d e+"},
            {~"k%G1", ~"vA"},
            {<<>>, ~"e"},
            {~"empty", <<>>},
            {~"flag", true},
            {~"x", <<255>>},
            {~"u", ~"é"},
            {~"=", ~"a=b"}
        ],
        arizona_cowboy_req:parse_qs(
            ~"a=1&a=2&b+c=d+e%2B&k%G1=v%41&=e&empty=&flag&x=%ff&u=%C3%A9&%3D=a=b"
        )
    ).

%% A path no Arizona route matches still reaches Cowboy's router, which answers
%% it as before: `404`, or `400` for a path it cannot parse.
paths_no_route_matches_keep_the_routers_answers(Config) ->
    ?assertMatch({404, _}, request(Config, ~"GET", ~"/nope")),
    ?assertMatch({400, _}, request(Config, ~"GET", ~"/nope/%G1")),
    ?assertMatch({405, _}, request(Config, ~"POST", ~"/items/%G1")).

%% `OPTIONS *` addresses the server, not a resource: a route whose pattern would
%% match a `*` segment does not answer it.
options_star_is_no_arizona_path(Config) when is_list(Config) ->
    Port = pick_port(),
    {ok, _} = arizona_cowboy_server:start(escapes_star, #{
        transport_opts => [{port, Port}],
        routes => [{match, '*', ~"/:any", arizona_cowboy_echo_controller, #{}}]
    }),
    try
        ?assertMatch({200, _}, request([{port, Port}], ~"OPTIONS", ~"/x")),
        ?assertMatch({404, _}, request([{port, Port}], ~"OPTIONS", ~"*"))
    after
        ok = arizona_cowboy_server:stop(escapes_star)
    end.

asset_missing_non_utf8_file_is_404(Config) ->
    [
        ?assertMatch({404, _}, request(Config, ~"GET", Path))
     || Path <- [~"/files/%FF", ~"/files/a%FFb.txt", ~"/files/caf%C3%A9", ~"/files/%G1"]
    ].

%% `%FF` is the octet 255, so it names the file whose name holds that byte.
asset_non_utf8_file_is_served(Config) ->
    ?assertEqual({200, ~"octet-bytes"}, request(Config, ~"GET", ~"/files/f%FF.txt")).

asset_link_to_a_non_utf8_name_is_followed_inside_only(Config) ->
    ?assertEqual({200, ~"octet-bytes"}, request(Config, ~"GET", ~"/files/inner.txt")),
    ?assertMatch({404, _}, request(Config, ~"GET", ~"/files/outer.txt")).

asset_dir_whose_name_is_not_utf8_serves(Config) ->
    Dir = filename:join(?config(priv_dir, Config), <<"d", 255>>),
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(filename:join(Dir, "app.txt"), ~"raw-dir-bytes"),
    Port = pick_port(),
    {ok, _} = arizona_cowboy_server:start(escapes_raw_dir, #{
        transport_opts => [{port, Port}],
        routes => [{asset, ~"/files", {dir, Dir}, #{}}]
    }),
    try
        ?assertEqual({200, ~"raw-dir-bytes"}, request([{port, Port}], ~"GET", ~"/files/app.txt"))
    after
        ok = arizona_cowboy_server:stop(escapes_raw_dir)
    end.

%% The type comes from the extension, ASCII case folded; one that is not
%% UTF-8 names no type.
asset_extension_that_is_not_utf8_is_octet_stream(Config) ->
    {200, Head, Body} = request_head(Config, ~"GET", ~"/files/a.%FF%FE"),
    ?assertEqual(~"ext-bytes", Body),
    ?assertNotEqual(nomatch, binary:match(Head, ~"content-type: application/octet-stream")),
    {200, Upper, ~"upper-bytes"} = request_head(Config, ~"GET", ~"/files/upper.TXT"),
    ?assertNotEqual(nomatch, binary:match(Upper, ~"content-type: text/plain")).

asset_link_into_a_sibling_sharing_the_dir_prefix_is_404(Config) ->
    ?assertMatch({404, _}, request(Config, ~"GET", ~"/files/sib.txt")).

%% `..`, `/`, `\` and NUL in a segment are refused however they are spelled,
%% a byte that is not UTF-8 or a malformed escape beside them included.
asset_traversal_is_refused_in_every_encoding(Config) ->
    [
        ?assertMatch(
            {Status, Body} when
                Status >= 400 andalso Status < 500 andalso Body =/= ~"top-secret-bytes",
            request(Config, ~"GET", Path)
        )
     || Path <- [
            ~"/files/../secret.txt",
            ~"/files/%2e%2e/secret.txt",
            ~"/files/%2E%2E%2Fsecret.txt",
            ~"/files/..%2fsecret.txt",
            ~"/files/..%5Csecret.txt",
            ~"/files/%2e%2e%5csecret.txt",
            ~"/files/%2Fsecret.txt",
            ~"/files/secret.txt%00",
            ~"/files/%00/../secret.txt",
            ~"/files/%2e%2e%2fs%FF",
            ~"/files/%2e%2e%2fsecret.txt%G1",
            ~"/files/..%2fsecret.txt%4"
        ]
    ].

%% The upgrade parses the page's query to find `_az_path`; Cowboy's parser would
%% refuse it `400`. The route opens only when the params reach it as sent.
ws_upgrade_with_a_malformed_query_escape_opens(Config) ->
    Head = upgrade(Config, ~"/ws?_az_path=/live&locale=%G1&x=%4"),
    ?assertMatch(<<"HTTP/1.1 101 ", _/binary>>, Head).

%% A navigate resolves its target with the query string the client sent, which
%% `arizona_req:params/1` then parses: a malformed escape must not crash the
%% live session.
navigate_target_with_a_malformed_query_escape_resolves(Config) when is_list(Config) ->
    %% The upgrade's request, as Cowboy hands it over.
    Raw = #{
        ref => ?LISTENER,
        pid => self(),
        streamid => 1,
        peer => {{127, 0, 0, 1}, 50000},
        sock => {{127, 0, 0, 1}, 4040},
        cert => undefined,
        method => ~"CONNECT",
        version => 'HTTP/2',
        scheme => ~"http",
        host => ~"localhost",
        port => 4040,
        path => ~"/ws",
        qs => <<>>,
        headers => #{},
        has_body => false,
        body_length => 0,
        bindings => #{}
    },
    {ok, arizona_cowboy_echo_page, _RouteOpts, Req} =
        arizona_cowboy_req:resolve_route(~"/live", ~"locale=%G1&x=%4", Raw),
    ?assertMatch({?PARAMS, _}, arizona_req:params(Req)).

%% --------------------------------------------------------------------
%% Helpers
%% --------------------------------------------------------------------

pick_port() ->
    {ok, Listen} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    ok = gen_tcp:close(Listen),
    Port.

%% The echo controller's answer, decoded.
echo(Config, Path) ->
    {Status, Body} = request(Config, ~"GET", Path),
    {Status, binary_to_term(Body)}.

%% One HTTP/1.1 request on its own connection; the status and the body.
request(Config, Method, Path) ->
    {Status, _Head, Body} = request_head(Config, Method, Path),
    {Status, Body}.

%% As `request/3`, with the head too, lowercased (bytes past ASCII kept).
request_head(Config, Method, Path) ->
    Response = exchange(Config, [
        Method,
        ~" ",
        Path,
        ~" HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\ncontent-length: 0\r\n\r\n"
    ]),
    [Head, Body] = binary:split(Response, ~"\r\n\r\n"),
    <<"HTTP/1.1 ", Code:3/binary, _/binary>> = Head,
    {binary_to_integer(Code), <<<<(ascii_lower(C))>> || <<C>> <= Head>>, Body}.

ascii_lower(C) when C >= $A, C =< $Z -> C + 32;
ascii_lower(C) -> C.

%% The head of a WebSocket upgrade's answer.
upgrade(Config, Target) ->
    {ok, Sock} = connect(Config),
    ok = gen_tcp:send(Sock, [
        ~"GET ",
        Target,
        ~" HTTP/1.1\r\nhost: localhost\r\nconnection: upgrade\r\nupgrade: websocket\r\n",
        ~"sec-websocket-version: 13\r\nsec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
    ]),
    Head = recv_head(Sock, <<>>),
    ok = gen_tcp:close(Sock),
    Head.

exchange(Config, Request) ->
    {ok, Sock} = connect(Config),
    ok = gen_tcp:send(Sock, Request),
    Response = recv_all(Sock, <<>>),
    ok = gen_tcp:close(Sock),
    Response.

connect(Config) ->
    gen_tcp:connect("localhost", proplists:get_value(port, Config), [binary, {active, false}]).

recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_all(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

recv_head(Sock, Acc) ->
    case binary:split(Acc, ~"\r\n\r\n") of
        [Head, _Rest] ->
            Head;
        [_Partial] ->
            {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
            recv_head(Sock, <<Acc/binary, Data/binary>>)
    end.
