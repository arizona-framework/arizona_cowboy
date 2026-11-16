-module(arizona_cowboy_health_middleware).
-moduledoc "**TEST FIXTURE.** A plain Cowboy middleware answering `/health` itself.".

-behaviour(cowboy_middleware).

-export([execute/2]).

-spec execute(Req, Env) -> {ok, Req, Env} | {stop, Req} when
    Req :: cowboy_req:req(),
    Env :: cowboy_middleware:env().
execute(#{path := ~"/health"} = Req, _Env) ->
    {stop, cowboy_req:reply(200, #{~"content-type" => ~"text/plain"}, ~"healthy", Req)};
execute(Req, Env) ->
    {ok, Req, Env}.
