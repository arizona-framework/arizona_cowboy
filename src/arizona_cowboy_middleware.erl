-module(arizona_cowboy_middleware).
-moduledoc """
A Cowboy middleware serving the Arizona routes of the listener it runs in:
the ones `arizona_cowboy_server:mount/2` put on a listener another framework
owns, and those of a listener `arizona_cowboy_server:start/2` started, whose
chain it heads too.

Place it before the owner's router in the listener's `middlewares`. A request
whose path an Arizona route matches is answered by `arizona_cowboy_handler`,
exactly as on a listener this adapter started, and the rest of the chain does
not run; any other request continues down the chain untouched (on a listener
`arizona_cowboy_server:start/2` started with the adapter's default chain, the
handler answers it `404` instead, as its router holds nothing else). A path
Arizona serves owns its methods too: a method no Arizona route allows there is
answered `405` here rather than passed on.

Arizona's matcher sees the path before any Cowboy router, so a path Cowboy's
router would refuse (a malformed escape such as `/items/%G1`, which
`cowboy_router` answers `400`) is still matched, its segment kept as written. A
path that does not start with `/` (`OPTIONS *`) is no Arizona path and passes on.

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
execute(#{ref := Ref, path := <<$/, _/binary>>} = Req, Env) ->
    case arizona_cowboy_server:find_table(Ref) of
        {ok, Table, AnswersMisses} ->
            case arizona_route_table:match(cowboy_req:method(Req), cowboy_req:path(Req), Table) of
                not_found when AnswersMisses -> serve(Req, Env, Ref);
                not_found -> {ok, Req, Env};
                _ArizonaPath -> serve(Req, Env, Ref)
            end;
        error ->
            {ok, Req, Env}
    end;
execute(Req, Env) ->
    {ok, Req, Env}.

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
