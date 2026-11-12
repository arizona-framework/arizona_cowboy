-module(arizona_cowboy_smoke_SUITE).
-moduledoc """
Boots a listener through `arizona_cowboy_server` and serves a controller route. The
adapter's full contract is verified by arizona's conformance suite, which runs
against this package from arizona's test profile.
""".
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).

-export([serves_a_controller_route/1]).
-export([answers_unknown_paths_and_methods/1]).
-export([stops_once/1]).
-export([error_page_is_threaded_only_when_set/1]).
-export([dev_crash_renders_the_configured_page/1]).
-export([dev_crash_without_a_page_is_plain_text/1]).
-export([prod_crash_is_plain_text/1]).

all() ->
    [
        serves_a_controller_route,
        answers_unknown_paths_and_methods,
        stops_once,
        error_page_is_threaded_only_when_set,
        dev_crash_renders_the_configured_page,
        dev_crash_without_a_page_is_plain_text,
        prod_crash_is_plain_text
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(arizona),
    Port = pick_port(),
    {ok, _} = arizona_cowboy_server:start(smoke, #{
        transport_opts => [{port, Port}],
        routes => [{get, ~"/hello", arizona_cowboy_smoke_controller, #{state => #{body => ~"hi"}}}]
    }),
    [{port, Port} | Config].

end_per_suite(Config) when is_list(Config) ->
    _ = arizona_cowboy_server:stop(smoke),
    ok = application:stop(arizona).

serves_a_controller_route(Config) ->
    ?assertMatch({200, <<"hi">>}, request(Config, ~"GET", ~"/hello")).

answers_unknown_paths_and_methods(Config) ->
    ?assertMatch({404, _}, request(Config, ~"GET", ~"/nope")),
    ?assertMatch({405, _}, request(Config, ~"POST", ~"/hello")).

stops_once(Config) when is_list(Config) ->
    {ok, _} = arizona_cowboy_server:start(smoke_stop, #{
        transport_opts => [{port, pick_port()}],
        routes => []
    }),
    ?assertEqual(ok, arizona_cowboy_server:stop(smoke_stop)),
    ?assertEqual({error, not_found}, arizona_cowboy_server:stop(smoke_stop)).

%% Core has no default error page, so the listener passes `error_page` on to
%% its live routes only when its config sets one.
error_page_is_threaded_only_when_set(Config) when is_list(Config) ->
    {ok, _} = arizona_cowboy_server:start(smoke_no_page, #{
        transport_opts => [{port, pick_port()}],
        routes => []
    }),
    {ok, _} = arizona_cowboy_server:start(smoke_page, #{
        transport_opts => [{port, pick_port()}],
        routes => [],
        error_page => {my_error_page, render}
    }),
    try
        ?assertEqual(#{compress => true}, build_opts(smoke_no_page)),
        ?assertEqual(
            #{compress => true, error_page => {my_error_page, render}}, build_opts(smoke_page)
        )
    after
        ok = arizona_cowboy_server:stop(smoke_no_page),
        ok = arizona_cowboy_server:stop(smoke_page)
    end.

%% In dev (the reload URL set), a page crash renders the listener's error page.
dev_crash_renders_the_configured_page(Config) when is_list(Config) ->
    Port = pick_port(),
    {ok, _} = arizona_cowboy_server:start(smoke_dev, #{
        transport_opts => [{port, Port}],
        routes => [{live, ~"/crash", arizona_cowboy_smoke_crash, #{}}],
        error_page => {arizona_error_page, render}
    }),
    ok = persistent_term:put(arizona_reload_url, ~"/arizona/reload"),
    try
        {Status, Body} = request([{port, Port}], ~"GET", ~"/crash"),
        ?assertEqual(500, Status),
        ?assertNotEqual(nomatch, binary:match(Body, ~"<title>500 -- Server Error</title>")),
        ?assertNotEqual(nomatch, binary:match(Body, ~"crash_on_mount"))
    after
        true = persistent_term:erase(arizona_reload_url),
        ok = arizona_cowboy_server:stop(smoke_dev)
    end.

%% In dev with no error page named, the crash is formatted as plain text.
dev_crash_without_a_page_is_plain_text(Config) when is_list(Config) ->
    Port = pick_port(),
    {ok, _} = arizona_cowboy_server:start(smoke_dev_text, #{
        transport_opts => [{port, Port}],
        routes => [{live, ~"/crash", arizona_cowboy_smoke_crash, #{}}]
    }),
    ok = persistent_term:put(arizona_reload_url, ~"/arizona/reload"),
    try
        {Status, Head, Body} = request_head([{port, Port}], ~"GET", ~"/crash"),
        ?assertEqual(500, Status),
        ?assertNotEqual(nomatch, binary:match(Head, ~"content-type: text/plain")),
        ?assertNotEqual(nomatch, binary:match(Body, ~"crash_on_mount")),
        ?assertEqual(nomatch, binary:match(Body, ~"<"))
    after
        true = persistent_term:erase(arizona_reload_url),
        ok = arizona_cowboy_server:stop(smoke_dev_text)
    end.

%% Outside dev a crash never shows its details, even with an error page named.
prod_crash_is_plain_text(Config) when is_list(Config) ->
    Port = pick_port(),
    {ok, _} = arizona_cowboy_server:start(smoke_prod, #{
        transport_opts => [{port, Port}],
        routes => [{live, ~"/crash", arizona_cowboy_smoke_crash, #{}}],
        error_page => {arizona_error_page, render}
    }),
    try
        {Status, Head, Body} = request_head([{port, Port}], ~"GET", ~"/crash"),
        ?assertEqual(500, Status),
        ?assertNotEqual(nomatch, binary:match(Head, ~"content-type: text/plain")),
        ?assertEqual(~"Internal Server Error", Body)
    after
        ok = arizona_cowboy_server:stop(smoke_prod)
    end.

%% The build options a listener's routes were compiled with.
build_opts(Name) ->
    #{build_opts := BuildOpts} = persistent_term:get({arizona_cowboy_server, Name}),
    BuildOpts.

%% A port the OS just handed out, so parallel runs do not collide.
pick_port() ->
    {ok, Listen} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    ok = gen_tcp:close(Listen),
    Port.

%% One HTTP/1.1 request on its own connection; the status and the body after
%% the head (the server closes, so read to the end).
request(Config, Method, Path) ->
    {Status, _Head, Body} = request_head(Config, Method, Path),
    {Status, Body}.

%% As `request/3`, with the head too, lowercased.
request_head(Config, Method, Path) ->
    {ok, Sock} = gen_tcp:connect("localhost", proplists:get_value(port, Config), [
        binary, {active, false}
    ]),
    ok = gen_tcp:send(Sock, [
        Method,
        ~" ",
        Path,
        ~" HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n",
        ~"content-length: 0\r\n\r\n"
    ]),
    Response = recv_all(Sock, <<>>),
    ok = gen_tcp:close(Sock),
    [Head, Body] = binary:split(Response, ~"\r\n\r\n"),
    <<"HTTP/1.1 ", Code:3/binary, _/binary>> = Head,
    {binary_to_integer(Code), string:lowercase(Head), Body}.

recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_all(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.
