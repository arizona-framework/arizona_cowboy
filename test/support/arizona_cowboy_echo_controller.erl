-module(arizona_cowboy_echo_controller).
-moduledoc """
**TEST FIXTURE.** Answers with the request's path bindings and query params, and
the bindings its middlewares produced, in the external term format: a binding
or param may hold octets that are not UTF-8.
""".

-export([handle/2]).

-spec handle(Req, Ctx) -> {Reply, Req} when
    Req :: arizona_req:request(),
    Ctx :: arizona_controller:context(),
    Reply :: arizona_controller:reply().
handle(Req, #{bindings := Context}) ->
    {Bindings, Req1} = arizona_req:bindings(Req),
    {Params, Req2} = arizona_req:params(Req1),
    Body = term_to_binary(#{bindings => Bindings, params => Params, context => Context}),
    {{200, [{~"content-type", ~"application/octet-stream"}], Body}, Req2}.
