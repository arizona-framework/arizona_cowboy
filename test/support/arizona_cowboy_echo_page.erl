-module(arizona_cowboy_echo_page).
-moduledoc "**TEST FIXTURE.** A live page that mounts and renders a fixed view.".
-include_lib("arizona/include/arizona_stateful.hrl").
-export([mount/1]).
-export([render/1]).

-spec mount(az:bindings()) -> az:mount_ret().
mount(Bindings) ->
    {#{id => maps:get(id, Bindings, ~"echo")}, #{}}.

-spec render(az:bindings()) -> az:template().
render(Bindings) ->
    ?html({'div', [{id, ?get(id)}], [~"echo"]}).
