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

all() ->
    [serves_a_controller_route, answers_unknown_paths_and_methods, stops_once].

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

%% A port the OS just handed out, so parallel runs do not collide.
pick_port() ->
    {ok, Listen} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    ok = gen_tcp:close(Listen),
    Port.

%% One HTTP/1.1 request on its own connection; the status and the body after
%% the head (the server closes, so read to the end).
request(Config, Method, Path) ->
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
    {binary_to_integer(Code), Body}.

recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_all(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.
