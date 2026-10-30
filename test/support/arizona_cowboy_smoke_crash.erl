-module(arizona_cowboy_smoke_crash).
-include_lib("arizona/include/arizona_stateful.hrl").
-export([mount/1]).
-export([render/1]).

%% A page whose mount raises, so its GET answers with the listener's 500.

-spec mount(az:bindings()) -> az:mount_ret().
mount(Bindings) ->
    error({crash_on_mount, Bindings}).

-spec render(az:bindings()) -> az:template().
render(Bindings) ->
    ?html({'div', [{id, ?get(id)}], []}).
