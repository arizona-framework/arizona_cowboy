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
-export([options_star_passes_on_to_the_owner/1]).
-export([query_key_limit_applies_to_mounted_routes_only/1]).
-export([owner_routes_answer_while_mounting_and_unmounting/1]).
-export([a_request_reads_the_listener_once/1]).
-export([arizona_routes_answer_while_mounting_and_unmounting/1]).
-export([a_navigate_on_an_unmounted_listener_is_unresolved/1]).

-define(OWNER, mount_owner).
%% Concurrent clients, and requests each, of the mount/unmount race cases.
-define(CLIENTS, 16).
-define(ROUNDS, 250).

all() ->
    [
        serves_arizona_routes_and_passes_the_rest_on,
        an_arizona_path_owns_its_methods,
        an_unmounted_listener_passes_everything_on,
        mounts_once,
        drain_and_stop_leave_the_owners_listener_up,
        options_star_passes_on_to_the_owner,
        query_key_limit_applies_to_mounted_routes_only,
        owner_routes_answer_while_mounting_and_unmounting,
        a_request_reads_the_listener_once,
        arizona_routes_answer_while_mounting_and_unmounting,
        a_navigate_on_an_unmounted_listener_is_unresolved
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
init_per_testcase(owner_routes_answer_while_mounting_and_unmounting, Config) ->
    Config;
init_per_testcase(arizona_routes_answer_while_mounting_and_unmounting, Config) ->
    Config;
init_per_testcase(a_request_reads_the_listener_once, Config) ->
    ok = arizona_cowboy_server:mount(?OWNER, #{routes => [body_route() | routes()]}),
    Config;
init_per_testcase(a_navigate_on_an_unmounted_listener_is_unresolved, Config) ->
    ok = arizona_cowboy_server:mount(?OWNER, #{
        routes => [{live, ~"/live", arizona_cowboy_echo_page, #{}}]
    }),
    Config;
init_per_testcase(options_star_passes_on_to_the_owner, Config) ->
    ok = arizona_cowboy_server:mount(?OWNER, #{
        routes => [
            {match, '*', ~"/:any", arizona_cowboy_smoke_controller, #{state => #{body => ~"hi"}}}
        ]
    }),
    Config;
init_per_testcase(query_key_limit_applies_to_mounted_routes_only, Config) ->
    ok = arizona_cowboy_server:mount(?OWNER, #{routes => routes(), max_query_keys => 2}),
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

%% `OPTIONS *` addresses the server, not a resource: no Arizona route answers
%% it, however its pattern would read a `*` segment.
options_star_passes_on_to_the_owner(Config) ->
    ?assertMatch({200, <<"hi">>}, request(Config, ~"OPTIONS", ~"/x")),
    ?assertMatch({404, _}, request(Config, ~"OPTIONS", ~"*")).

%% The mounted routes take the limit `mount/2` was given; the owner's own routes
%% are the owner's business.
query_key_limit_applies_to_mounted_routes_only(Config) ->
    ?assertMatch({200, <<"hi">>}, request(Config, ~"GET", ~"/hello?a&b")),
    ?assertMatch({400, _}, request(Config, ~"GET", ~"/hello?a&b&c")),
    ?assertMatch({200, <<"owner">>}, request(Config, ~"GET", ~"/owned?a&b&c")).

%% The middleware decides a request from one read of the mounted routes: an
%% unmount landing while it handles a request to one of the owner's own routes
%% is no crash, the request is passed on either way. A race, so many tries.
owner_routes_answer_while_mounting_and_unmounting(Config) ->
    Answers = while_flipping(routes(), Config, [{~"GET", ~"/owned"}]),
    ?assertEqual([], [Answer || Answer <- Answers, not is_status(Answer, [200])]).

%% What the race cases catch only when a request is preempted at the wrong
%% moment, pinned on every request: whatever it reaches, a request reads what
%% the listener serves once, so no unmount can fall between two reads.
%% The middleware hands what it read to the handler, which serves an Arizona
%% route, its body read included, from that.
a_request_reads_the_listener_once(Config) ->
    ?assertEqual(
        [{~"/owned", 200, 1}, {~"/hello", 200, 1}, {~"/body", 200, 1}],
        reads(Config, [{~"GET", ~"/owned"}, {~"GET", ~"/hello"}, {~"POST", ~"/body"}])
    ).

%% A request the middleware hands to an Arizona route is served from the routes
%% and limits it read, so an unmount landing mid-request is no crash: the
%% request is served (`200`) or, read before the mount, the owner's (`404`). The
%% body read takes the listener's `max_content_length` too.
arizona_routes_answer_while_mounting_and_unmounting(Config) ->
    Answers = while_flipping([body_route() | routes()], Config, [
        {~"GET", ~"/hello"}, {~"POST", ~"/body"}
    ]),
    ?assertEqual([], [Answer || Answer <- Answers, not is_status(Answer, [200, 404])]).

%% A live session can outlast its routes: a navigate after the unmount is left
%% unresolved, as one to a URL no route serves, rather than crashing.
a_navigate_on_an_unmounted_listener_is_unresolved(Config) when is_list(Config) ->
    Raw = upgrade_req(?OWNER),
    ?assertMatch({ok, _, _, _}, arizona_cowboy_req:resolve_route(~"/live", <<>>, Raw)),
    ok = arizona_cowboy_server:unmount(?OWNER),
    ?assertEqual(error, arizona_cowboy_req:resolve_route(~"/live", <<>>, Raw)).

%% --------------------------------------------------------------------
%% Helpers
%% --------------------------------------------------------------------

%% The answers to `Requests`, sent over and over by many clients at once while
%% `Routes` are mounted and unmounted in a loop that yields between its steps:
%% the more requests in flight, the likelier one is caught between an unmount
%% and a second read, even on a single scheduler.
while_flipping(Routes, Config, Requests) ->
    Flipper = flipper(Routes),
    try
        Self = self(),
        Clients = [
            spawn_link(fun() -> Self ! {answers, self(), client(Config, Requests)} end)
         || _ <- lists:seq(1, ?CLIENTS)
        ],
        lists:append([
            receive
                {answers, Client, Answers} -> Answers
            after 60000 -> error({client_stuck, Client})
            end
         || Client <- Clients
        ])
    after
        ok = stop_flipper(Flipper)
    end.

client(Config, Requests) ->
    [
        try_request(Config, Method, Path)
     || _ <- lists:seq(1, ?ROUNDS), {Method, Path} <- Requests
    ].

is_status({Status, _Body}, Statuses) -> lists:member(Status, Statuses);
is_status(_NoAnswer, _Statuses) -> false.

%% Each request's path, status and reads of the owner listener's routes, by
%% every process it involves: `persistent_term` calls on its key are traced.
reads(Config, Requests) ->
    Key = {arizona_cowboy_server, ?OWNER},
    MatchSpec = [{[Key], [], []}, {[Key, '_'], [], []}],
    Patterned = erlang:trace_pattern({persistent_term, get, '_'}, MatchSpec, [local]),
    true = Patterned > 0,
    0 = erlang:trace(new_processes, true, [call, {tracer, self()}]),
    try
        [
            begin
                {Status, _Body} = request(Config, Method, Path),
                {Path, Status, length(delivered_reads(Key))}
            end
         || {Method, Path} <- Requests
        ]
    after
        erlang:trace(new_processes, false, [call]),
        erlang:trace_pattern({persistent_term, get, '_'}, false, [local]),
        delivered_reads(Key)
    end.

%% The traced reads of `Key` so far, every one of them delivered.
delivered_reads(Key) ->
    Ref = erlang:trace_delivered(all),
    receive
        {trace_delivered, all, Ref} -> ok
    after 5000 -> error(trace_not_delivered)
    end,
    collect_reads(Key).

collect_reads(Key) ->
    receive
        {trace, _Pid, call, {persistent_term, get, [Key | _]}} = Read -> [Read | collect_reads(Key)]
    after 0 -> []
    end.

%% Mounts `Routes` on the owner's listener and unmounts them, over and over,
%% until `stop_flipper/1`.
flipper(Routes) ->
    spawn_link(fun Flip() ->
        ok = arizona_cowboy_server:mount(?OWNER, #{routes => Routes}),
        erlang:yield(),
        ok = arizona_cowboy_server:unmount(?OWNER),
        erlang:yield(),
        receive
            stop -> ok
        after 0 -> Flip()
        end
    end).

%% Stopped after a whole mount and unmount, never in the middle of one, so the
%% case ends with nothing mounted.
stop_flipper(Flipper) ->
    Monitor = monitor(process, Flipper),
    Flipper ! stop,
    receive
        {'DOWN', Monitor, process, Flipper, normal} -> ok
    after 5000 -> error(flipper_did_not_stop)
    end.

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

%% A controller reading its request's body.
body_route() ->
    {post, ~"/body", arizona_cowboy_body_controller, #{state => #{prefix => ~"read "}}}.

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

%% As `request/3`, but a request whose connection fails or goes unanswered is
%% that outcome rather than a crash, so a race test reports every miss at once.
try_request(Config, Method, Path) ->
    try
        request(Config, Method, Path)
    catch
        error:Reason -> {no_answer, Reason}
    end.

recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_all(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.
