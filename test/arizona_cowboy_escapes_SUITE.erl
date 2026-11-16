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
-export([asset_dir_list_follows_a_latin1_file_name_encoding/1]).
-export([asset_traversal_is_refused_in_every_encoding/1]).
-export([ws_upgrade_with_a_malformed_query_escape_opens/1]).
-export([navigate_target_with_a_malformed_query_escape_resolves/1]).
-export([query_with_more_keys_than_the_limit_is_400/1]).
-export([ws_upgrade_with_more_keys_than_the_limit_is_400/1]).
-export([navigate_target_with_more_keys_than_the_limit_is_a_full_load/1]).
-export([within_key_limit_counts_non_empty_pairs/1]).
-export([routes_that_never_read_the_query_still_apply_the_limit/1]).
-export([a_long_run_of_empty_pairs_counts_nothing/1]).
-export([max_query_keys_infinity_counts_nothing/1]).
-export([max_query_keys_must_be_a_count_or_infinity/1]).
-export([a_run_of_empty_pairs_hides_no_key_after_it/1]).
-export([parse_qs_builds_nothing_for_empty_pairs/1]).
-export([a_cors_preflight_counts_its_query_keys/1]).
-export([arizona_keys_count_everywhere_but_the_upgrade/1]).
-export([max_query_keys_sets_the_limit/1]).

-define(LISTENER, escapes).
-define(ORIGIN, ~"https://app.example").
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
        asset_dir_list_follows_a_latin1_file_name_encoding,
        asset_traversal_is_refused_in_every_encoding,
        ws_upgrade_with_a_malformed_query_escape_opens,
        navigate_target_with_a_malformed_query_escape_resolves,
        query_with_more_keys_than_the_limit_is_400,
        ws_upgrade_with_more_keys_than_the_limit_is_400,
        navigate_target_with_more_keys_than_the_limit_is_a_full_load,
        within_key_limit_counts_non_empty_pairs,
        routes_that_never_read_the_query_still_apply_the_limit,
        a_long_run_of_empty_pairs_counts_nothing,
        max_query_keys_infinity_counts_nothing,
        max_query_keys_must_be_a_count_or_infinity,
        a_run_of_empty_pairs_hides_no_key_after_it,
        parse_qs_builds_nothing_for_empty_pairs,
        a_cors_preflight_counts_its_query_keys,
        arizona_keys_count_everywhere_but_the_upgrade,
        max_query_keys_sets_the_limit
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
            %% Neither reads the query.
            {live, ~"/plain", arizona_cowboy_echo_page, #{}},
            {get, ~"/hello", arizona_cowboy_smoke_controller, #{state => #{body => ~"hi"}}},
            {post, ~"/cors", arizona_cowboy_echo_controller, #{
                check_origin => false,
                middlewares => [
                    arizona_middleware:cors(#{origins => [?ORIGIN], methods => [~"POST"]})
                ]
            }},
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
            {~"=", ~"a=b"},
            {~"r", ~"%G1%41 b"},
            {~"s", ~"%4G%41"},
            {~"t", ~"%41%4"},
            {~"u", ~"%41%"}
        ],
        arizona_cowboy_req:parse_qs(
            <<"a=1&a=2&b+c=d+e%2B&k%G1=v%41&=e&empty=&flag&x=%ff&u=%C3%A9&%3D=a=b&",
                "r=%G1%41+b&s=%4G%41&t=%41%4&u=%41%">>
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
%% Its type comes from its extension alone, which is ASCII.
asset_non_utf8_file_is_served(Config) ->
    {200, Head, Body} = request_head(Config, ~"GET", ~"/files/f%FF.txt"),
    ?assertEqual(~"octet-bytes", Body),
    ?assertNotEqual(nomatch, binary:match(Head, ~"content-type: text/plain")).

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
        {200, Head, Body} = request_head([{port, Port}], ~"GET", ~"/files/app.txt"),
        ?assertEqual(~"raw-dir-bytes", Body),
        ?assertNotEqual(nomatch, binary:match(Head, ~"content-type: text/plain"))
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

%% A list names a file as the node's file name encoding reads it: under
%% `+fnl` (latin1) each character is one byte of the name. The listener runs on
%% a node started that way; the directory's name is `d` and the UTF-8 bytes of
%% `é`, which that node's list spells as the two characters 195 and 169.
asset_dir_list_follows_a_latin1_file_name_encoding(Config) ->
    Dir = filename:join(?config(priv_dir, Config), <<"d", 195, 169>>),
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(filename:join(Dir, "app.txt"), ~"latin1-bytes"),
    ListDir = binary_to_list(Dir),
    Paths = lists:append([["-pa", P] || P <- code:get_path()]),
    {ok, Peer, _Node} = peer:start_link(#{connection => standard_io, args => ["+fnl" | Paths]}),
    try
        ?assertEqual(latin1, peer:call(Peer, file, native_name_encoding, [])),
        {ok, _} = peer:call(Peer, application, ensure_all_started, [arizona]),
        Port = pick_port(),
        {ok, _} = peer:call(Peer, arizona_cowboy_server, start, [
            escapes_latin1,
            #{
                transport_opts => [{port, Port}],
                routes => [{asset, ~"/files", {dir, ListDir}, #{}}]
            }
        ]),
        ?assertEqual({200, ~"latin1-bytes"}, request([{port, Port}], ~"GET", ~"/files/app.txt"))
    after
        ok = peer:stop(Peer)
    end.

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
    Raw = upgrade_req(?LISTENER),
    {ok, arizona_cowboy_echo_page, _RouteOpts, Req} =
        arizona_cowboy_req:resolve_route(~"/live", ~"locale=%G1&x=%4", Raw),
    ?assertMatch({?PARAMS, _}, arizona_req:params(Req)).

%% Cowboy's own query parser stops at 100 keys and Cowboy answers `400`; the
%% adapter keeps that limit. Empty pairs are no keys.
query_with_more_keys_than_the_limit_is_400(Config) ->
    {200, #{params := Params}} = echo(Config, <<"/q?", (keys(100))/binary, "&&&">>),
    ?assertEqual(100, length(Params)),
    ?assertMatch({400, _}, request(Config, ~"GET", <<"/q?", (keys(101))/binary>>)).

%% Only the page's own keys count: a page served with 100 keys opens its socket.
ws_upgrade_with_more_keys_than_the_limit_is_400(Config) ->
    ?assertMatch(
        <<"HTTP/1.1 400 ", _/binary>>,
        upgrade(Config, <<"/ws?_az_path=/plain&", (keys(101))/binary>>)
    ),
    ?assertMatch(
        <<"HTTP/1.1 101 ", _/binary>>,
        upgrade(Config, <<"/ws?_az_path=/plain&", (keys(100))/binary>>)
    ).

%% A navigate cannot be answered `400`: the target is left unresolved, so the
%% client loads it over HTTP, where it is.
navigate_target_with_more_keys_than_the_limit_is_a_full_load(Config) when is_list(Config) ->
    ?assertEqual(
        error, arizona_cowboy_req:resolve_route(~"/live", keys(101), upgrade_req(?LISTENER))
    ),
    ?assertMatch(
        {ok, arizona_cowboy_echo_page, _, _},
        arizona_cowboy_req:resolve_route(~"/live", keys(100), upgrade_req(?LISTENER))
    ).

within_key_limit_counts_non_empty_pairs(Config) when is_list(Config) ->
    ?assert(arizona_cowboy_req:within_key_limit(<<>>, 0, [])),
    ?assert(arizona_cowboy_req:within_key_limit(~"&&&", 0, [])),
    ?assert(arizona_cowboy_req:within_key_limit(~"&a&&b=&", 2, [])),
    ?assertNot(arizona_cowboy_req:within_key_limit(~"a&b&c", 2, [])),
    ?assertNot(arizona_cowboy_req:within_key_limit(~"=", 0, [])),
    ?assert(arizona_cowboy_req:within_key_limit(keys(100), 100, [])),
    ?assertNot(arizona_cowboy_req:within_key_limit(keys(101), 100, [])).

%% The limit is the request's, not the parser's: a route that never reads its
%% query refuses one over it as one that does.
routes_that_never_read_the_query_still_apply_the_limit(Config) ->
    [
        ?assertMatch({400, _}, request(Config, ~"GET", <<Path/binary, "?", (keys(101))/binary>>))
     || Path <- [~"/plain", ~"/hello"]
    ],
    ?assertMatch({200, _}, request(Config, ~"GET", <<"/plain?", (keys(100))/binary>>)),
    %% An asset never reads it.
    ?assertMatch({200, _}, request(Config, ~"GET", <<"/files/app.txt?", (keys(101))/binary>>)).

%% Empty pairs are no keys, however many.
a_long_run_of_empty_pairs_counts_nothing(Config) when is_list(Config) ->
    Run = binary:copy(~"&", 10485760),
    ?assert(arizona_cowboy_req:within_key_limit(<<Run/binary, "a=1&", Run/binary>>, 1, [])),
    ?assertNot(arizona_cowboy_req:within_key_limit(<<Run/binary, "a&", Run/binary, "b">>, 1, [])).

max_query_keys_sets_the_limit(Config) when is_list(Config) ->
    Port = pick_port(),
    {ok, _} = arizona_cowboy_server:start(escapes_keys, #{
        transport_opts => [{port, Port}],
        max_query_keys => 2,
        routes => [
            {get, ~"/q", arizona_cowboy_echo_controller, #{}},
            {live, ~"/plain", arizona_cowboy_echo_page, #{}},
            {ws, ~"/ws", #{}}
        ]
    }),
    try
        ?assertMatch({200, _}, request([{port, Port}], ~"GET", ~"/q?a=1&b")),
        ?assertMatch({400, _}, request([{port, Port}], ~"GET", ~"/q?a=1&b&c")),
        ?assertMatch(
            <<"HTTP/1.1 400 ", _/binary>>, upgrade([{port, Port}], ~"/ws?_az_path=/plain&a&b&c")
        ),
        %% Arizona's own keys are not the page's: each counts for none, once.
        ?assertMatch(
            <<"HTTP/1.1 101 ", _/binary>>,
            upgrade([{port, Port}], <<
                "/ws?_az_path=/plain&_az_reconnect=1&_az_fps_follow=1&_az_caps=%7B%7D",
                "&a&b"
            >>)
        ),
        ?assertMatch(
            <<"HTTP/1.1 400 ", _/binary>>,
            upgrade([{port, Port}], ~"/ws?_az_path=/plain&_az_path=/plain&a&b")
        ),
        Raw = upgrade_req(escapes_keys),
        ?assertMatch({ok, _, _, _}, arizona_cowboy_req:resolve_route(~"/plain", ~"a&b", Raw)),
        ?assertEqual(error, arizona_cowboy_req:resolve_route(~"/plain", ~"a&b&c", Raw))
    after
        ok = arizona_cowboy_server:stop(escapes_keys)
    end.

max_query_keys_infinity_counts_nothing(Config) when is_list(Config) ->
    Port = pick_port(),
    {ok, _} = arizona_cowboy_server:start(escapes_no_limit, #{
        transport_opts => [{port, Port}],
        max_query_keys => infinity,
        routes => [{get, ~"/q", arizona_cowboy_echo_controller, #{}}]
    }),
    try
        {200, #{params := Params}} = echo([{port, Port}], <<"/q?", (keys(1000))/binary>>),
        ?assertEqual(1000, length(Params)),
        ?assert(arizona_cowboy_req:within_key_limit(keys(1000), infinity, []))
    after
        ok = arizona_cowboy_server:stop(escapes_no_limit)
    end.

%% A value that is no count would crash every request, or disable the limit
%% unnoticed: refused when the listener starts or mounts.
max_query_keys_must_be_a_count_or_infinity(Config) when is_list(Config) ->
    [
        begin
            Opts = #{transport_opts => [{port, pick_port()}], max_query_keys => Bad, routes => []},
            ?assertError({bad_max_query_keys, Bad}, arizona_cowboy_server:start(escapes_bad, Opts)),
            ?assertError({bad_max_query_keys, Bad}, arizona_cowboy_server:mount(escapes_bad, Opts)),
            #{general := Message} =
                arizona_cowboy_server:format_error({bad_max_query_keys, Bad}, []),
            ?assertEqual(
                <<"max_query_keys must be a non-negative integer or infinity, not ",
                    (iolist_to_binary(io_lib:format("~0tp", [Bad])))/binary>>,
                iolist_to_binary(Message)
            )
        end
     || Bad <- [-1, 100.0, ~"100", unlimited]
    ],
    ?assertEqual({error, not_found}, arizona_cowboy_server:stop(escapes_bad)).

%% Empty pairs are skipped 64 at a time, then one by one: a key right after a run
%% of any length is still found.
a_run_of_empty_pairs_hides_no_key_after_it(Config) when is_list(Config) ->
    [
        begin
            Run = binary:copy(~"&", N),
            Qs = <<Run/binary, "a">>,
            ?assertNot(arizona_cowboy_req:within_key_limit(Qs, 0, [])),
            ?assert(arizona_cowboy_req:within_key_limit(Qs, 1, [])),
            ?assertEqual(
                [{~"a", true}, {~"b", true}],
                arizona_cowboy_req:parse_qs(<<Qs/binary, Run/binary, "b", Run/binary>>)
            )
        end
     || N <- [1, 63, 64, 65, 127, 128, 129]
    ].

%% An empty pair is skipped, not built and then dropped: 20 MB of them around
%% one key parse within a heap of a million words, about 8 MB on a 64-bit node.
parse_qs_builds_nothing_for_empty_pairs(Config) when is_list(Config) ->
    Run = binary:copy(~"&", 10485760),
    Qs = <<Run/binary, "a=1", Run/binary>>,
    Self = self(),
    {Pid, Monitor} = spawn_opt(
        fun() -> Self ! {parsed, arizona_cowboy_req:parse_qs(Qs)} end,
        [monitor, {max_heap_size, #{size => 1000000, kill => true, error_logger => false}}]
    ),
    receive
        {'DOWN', Monitor, process, Pid, Reason} -> ?assertEqual(normal, Reason)
    after 10000 -> error(parse_timeout)
    end,
    receive
        {parsed, Params} -> ?assertEqual([{~"a", ~"1"}], Params)
    after 0 -> error(no_result)
    end.

%% A preflight is a request to the route like any other.
a_cors_preflight_counts_its_query_keys(Config) ->
    Preflight = [{~"origin", ?ORIGIN}, {~"access-control-request-method", ~"POST"}],
    ?assertMatch(
        {204, _, _}, request_head(Config, ~"OPTIONS", <<"/cors?", (keys(100))/binary>>, Preflight)
    ),
    ?assertMatch(
        {400, _, _}, request_head(Config, ~"OPTIONS", <<"/cors?", (keys(101))/binary>>, Preflight)
    ).

%% Only the upgrade strips Arizona's own keys; anywhere else they are the
%% page's.
arizona_keys_count_everywhere_but_the_upgrade(Config) ->
    Arizona = ~"_az_path=/plain&_az_reconnect=1&_az_fps_follow=1&_az_caps=%7B%7D",
    [
        ?assertMatch(
            {400, _},
            request(Config, ~"GET", <<Path/binary, "?", Arizona/binary, "&", (keys(97))/binary>>)
        )
     || Path <- [~"/plain", ~"/hello"]
    ],
    ?assertEqual(
        error,
        arizona_cowboy_req:resolve_route(
            ~"/plain", <<Arizona/binary, "&", (keys(97))/binary>>, upgrade_req(?LISTENER)
        )
    ),
    ?assertMatch(
        <<"HTTP/1.1 101 ", _/binary>>,
        upgrade(Config, <<"/ws?", Arizona/binary, "&", (keys(100))/binary>>)
    ).

%% --------------------------------------------------------------------
%% Helpers
%% --------------------------------------------------------------------

%% A WebSocket upgrade's request to `Listener`, as Cowboy hands it over.
upgrade_req(Listener) ->
    #{
        ref => Listener,
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
    }.

%% `N` distinct `kI=v` pairs.
keys(N) ->
    iolist_to_binary(
        lists:join(~"&", [[~"k", integer_to_binary(I), ~"=v"] || I <- lists:seq(1, N)])
    ).

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
    request_head(Config, Method, Path, []).

%% As `request_head/3`, with these extra header lines.
request_head(Config, Method, Path, Headers) ->
    Response = exchange(Config, [
        Method,
        ~" ",
        Path,
        ~" HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\ncontent-length: 0\r\n",
        [[Name, ~": ", Value, ~"\r\n"] || {Name, Value} <- Headers],
        ~"\r\n"
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
