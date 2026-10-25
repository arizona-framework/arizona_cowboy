-module(arizona_cowboy_mount_SUITE).
-moduledoc """
Arizona routes mounted on a Cowboy listener this adapter did not start, served
by `arizona_cowboy_middleware` in front of the owner's own router.
""".
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([serves_arizona_routes_and_passes_the_rest_on/1]).
-export([an_arizona_path_owns_its_methods/1]).
-export([an_unmounted_listener_passes_everything_on/1]).
-export([mounts_once/1]).
-export([drain_and_stop_leave_the_owners_listener_up/1]).

-define(OWNER, mount_owner).

all() ->
    [
        serves_arizona_routes_and_passes_the_rest_on,
        an_arizona_path_owns_its_methods,
        an_unmounted_listener_passes_everything_on,
        mounts_once,
        drain_and_stop_leave_the_owners_listener_up
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(arizona),
    {ok, _} = application:ensure_all_started(cowboy),
    Port = pick_port(),
    Dispatch = cowboy_router:compile([{'_', [{"/owned", arizona_cowboy_owner_handler, []}]}]),
    {ok, _} = cowboy:start_clear(?OWNER, [{port, Port}], #{
        middlewares => [arizona_cowboy_middleware, cowboy_router, cowboy_handler],
        env => #{dispatch => Dispatch}
    }),
    [{port, Port} | Config].

end_per_suite(Config) when is_list(Config) ->
    ok = cowboy:stop_listener(?OWNER),
    ok = application:stop(arizona).

init_per_testcase(an_unmounted_listener_passes_everything_on, Config) ->
    Config;
init_per_testcase(_Case, Config) ->
    ok = arizona_cowboy_server:mount(?OWNER, #{routes => routes()}),
    Config.

end_per_testcase(Case, Config) when is_atom(Case) ->
    case arizona_cowboy_server:unmount(?OWNER) of
        ok -> ok;
        {error, not_found} -> ok
    end,
    Config.

%% --------------------------------------------------------------------
%% Cases
%% --------------------------------------------------------------------

serves_arizona_routes_and_passes_the_rest_on(Config) ->
    ?assertMatch({200, <<"hi">>}, request(Config, ~"GET", ~"/hello")),
    ?assertMatch({200, <<"owner">>}, request(Config, ~"GET", ~"/owned")),
    %% Neither router has it: the owner's answers.
    ?assertMatch({404, _}, request(Config, ~"GET", ~"/nope")).

an_arizona_path_owns_its_methods(Config) ->
    ?assertMatch({405, _}, request(Config, ~"POST", ~"/hello")).

an_unmounted_listener_passes_everything_on(Config) ->
    ?assertMatch({404, _}, request(Config, ~"GET", ~"/hello")),
    ?assertMatch({200, <<"owner">>}, request(Config, ~"GET", ~"/owned")).

mounts_once(Config) when is_list(Config) ->
    ?assertEqual(
        {error, {already_started, ?OWNER}},
        arizona_cowboy_server:mount(?OWNER, #{routes => routes()})
    ).

%% The owner's listener is the owner's to close: winding Arizona down forgets
%% its routes and nothing else.
drain_and_stop_leave_the_owners_listener_up(Config) ->
    ?assertEqual(ok, arizona_cowboy_server:drain(?OWNER, 1000)),
    ?assertMatch({404, _}, request(Config, ~"GET", ~"/hello")),
    ?assertMatch({200, <<"owner">>}, request(Config, ~"GET", ~"/owned")),
    ok = arizona_cowboy_server:mount(?OWNER, #{routes => routes()}),
    ?assertEqual(ok, arizona_cowboy_server:stop(?OWNER)),
    ?assertMatch({200, <<"owner">>}, request(Config, ~"GET", ~"/owned")),
    ?assertEqual({error, not_found}, arizona_cowboy_server:unmount(?OWNER)).

%% --------------------------------------------------------------------
%% Helpers
%% --------------------------------------------------------------------

routes() ->
    [{get, ~"/hello", arizona_cowboy_smoke_controller, #{state => #{body => ~"hi"}}}].

pick_port() ->
    {ok, Listen} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    ok = gen_tcp:close(Listen),
    Port.

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
