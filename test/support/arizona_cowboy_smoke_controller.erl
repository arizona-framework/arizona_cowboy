-module(arizona_cowboy_smoke_controller).
-moduledoc "**TEST FIXTURE.** A controller answering with its route's `body` state.".

-export([handle/2]).

-spec handle(Req, Ctx) -> {Reply, Req} when
    Req :: arizona_req:request(),
    Ctx :: arizona_controller:context(),
    Reply :: arizona_controller:reply().
handle(Req, #{state := #{body := Body}}) ->
    {{200, [{~"content-type", ~"text/plain"}], Body}, Req}.
