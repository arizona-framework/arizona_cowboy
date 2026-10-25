-module(arizona_cowboy_middleware).
-moduledoc """
A Cowboy middleware serving the Arizona routes `arizona_cowboy_server:mount/2`
put on the listener it runs in, for a listener another framework owns.

Place it before the owner's router in the listener's `middlewares`. A request
whose path an Arizona route matches is answered by `arizona_cowboy_handler`,
exactly as on a listener this adapter started, and the rest of the chain does
not run; any other request continues down the chain untouched. A path Arizona
serves owns its methods too: a method no Arizona route allows there is answered
`405` here rather than passed on.

```erlang
cowboy:start_clear(my_listener, [{port, 8080}], #{
    middlewares => [arizona_cowboy_middleware, cowboy_router, cowboy_handler],
    env => #{dispatch => MyDispatch}
}),
ok = arizona_cowboy_server:mount(my_listener, #{routes => ArizonaRoutes}).
```
""".

-behaviour(cowboy_middleware).

%% --------------------------------------------------------------------
%% API function exports
%% --------------------------------------------------------------------

-export([execute/2]).

%% --------------------------------------------------------------------
%% API Functions
%% --------------------------------------------------------------------

-doc "Cowboy `execute/2`: serves an Arizona route, or passes the request on.".
-spec execute(Req, Env) -> {ok, Req, Env} | {stop, Req} when
    Req :: cowboy_req:req(),
    Env :: cowboy_middleware:env().
execute(#{ref := Ref} = Req, Env) ->
    case arizona_cowboy_server:find_table(Ref) of
        {ok, Table} ->
            case arizona_route_table:match(cowboy_req:method(Req), cowboy_req:path(Req), Table) of
                not_found -> {ok, Req, Env};
                _ArizonaPath -> serve(Req, Env, Ref)
            end;
        error ->
            {ok, Req, Env}
    end.

%% --------------------------------------------------------------------
%% Internal functions
%% --------------------------------------------------------------------

%% `cowboy_handler` runs the handler and the loop or WebSocket it upgrades to;
%% the request is answered then, so the owner's chain must not run after it.
%% (No Arizona loop hibernates, so `cowboy_handler` never suspends here.)
serve(Req, Env, Ref) ->
    {ok, Req1, _Env1} = cowboy_handler:execute(Req, Env#{
        handler => arizona_cowboy_handler, handler_opts => Ref
    }),
    {stop, Req1}.
