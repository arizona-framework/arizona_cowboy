-module(arizona_cowboy_owner_handler).
-moduledoc "**TEST FIXTURE.** A plain Cowboy handler: the listener owner's own route.".

-behaviour(cowboy_handler).

-export([init/2]).

-spec init(Req, State) -> {ok, Req, State} when
    Req :: cowboy_req:req(),
    State :: term().
init(Req, State) ->
    {ok, cowboy_req:reply(200, #{~"content-type" => ~"text/plain"}, ~"owner", Req), State}.
