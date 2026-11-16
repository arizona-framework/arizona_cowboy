-module(arizona_cowboy_body_controller).
-moduledoc """
**TEST FIXTURE.** Reads the request body and answers with its size, after its
route's `prefix` state.
""".

-export([handle/2]).

-spec handle(Req, Ctx) -> {Reply, Req} when
    Req :: arizona_req:request(),
    Ctx :: arizona_controller:context(),
    Reply :: arizona_controller:reply().
handle(Req, #{state := #{prefix := Prefix}}) ->
    {ok, Body, Req1} = arizona_req:body(Req),
    {{200, [], <<Prefix/binary, (integer_to_binary(byte_size(Body)))/binary>>}, Req1}.
