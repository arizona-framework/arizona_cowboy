-module(arizona_cowboy_server).
-moduledoc """
The Cowboy `arizona_server` adapter: boots a Cowboy listener serving Arizona
routes.

Cowboy's router sees one catch-all route to `arizona_cowboy_handler`; the
Arizona routes are compiled by `arizona_route_table` into a table kept per
listener in a `persistent_term`, which the handler and
`arizona_cowboy_req:resolve_route/3` read.

## Mounting on a listener another framework owns

`mount/2` serves Arizona routes on a Cowboy listener that something else
started (a Nova or plain Cowboy application): it compiles the routes under that
listener's ref without starting anything, and `arizona_cowboy_middleware`, placed
in the listener's middleware chain, serves the requests they match and passes the
rest on. It takes `routes`, `compress`, `error_page`, `ws_opts` and
`max_content_length` as below; the owner configures the listener itself, TLS
and `enable_connect_protocol` included. `unmount/1` forgets the routes,
`notify_drain/2` tells the live sessions to wind down, and `drain/2` also waits
for the requests in flight, then unmounts, leaving the owner's listener running.

## Options

- `routes` -- the Arizona route list (required).
- `transport_opts` -- `[{port, Port}]` (default `4040`); other entries go to
  Ranch's socket options.
- `scheme` -- `http` (default) or `https`.
- `tls` -- `[ssl:tls_server_option()]`, merged into the socket options of a
  TLS listener, which negotiates HTTP/2 or HTTP/1.1 by ALPN. Supplying it
  makes the listener HTTPS, so `scheme => https` is optional beside it;
  `scheme => https` without it raises `https_requires_tls`, and with
  `scheme => http` it raises `tls_with_http_scheme`, rather than serving the
  certs' traffic in cleartext.
- `max_content_length` -- the largest request body a controller can read, in
  bytes (default `10485760`); a larger one reads as `{error, too_large}`.
- `compress` -- `true` (default) compresses pages and assets
  (`arizona_route:transforms/2`).
- `error_page` -- `{Module, Function}` template rendered on a page crash in
  dev. Unset by default: a dev crash is then served as plain text; set
  `{arizona_error_page, render}` for Arizona's HTML dev page.
- `proto_opts` -- merged into Cowboy's protocol options. `enable_connect_protocol`
  is `true` by default, so a client may open a WebSocket over HTTP/2 (RFC 8441).
- `ws_opts` -- merged into the `cowboy_websocket` options of every live session
  (default `#{idle_timeout => infinity, max_frame_size => 10485760}`: the frame
  cap bounds what one client can make a session buffer).
""".

-behaviour(arizona_server).

%% --------------------------------------------------------------------
%% API function exports
%% --------------------------------------------------------------------

-export([start/2]).
-export([stop/1]).
-export([mount/2]).
-export([unmount/1]).
-export([find_table/1]).
-export([drain/2]).
-export([notify_drain/2]).
-export([recompile_routes/0]).
-export([capabilities/0]).
-export([table/1]).
-export([ws_opts/1]).
-export([max_content_length/1]).
-export([format_error/2]).

%% --------------------------------------------------------------------
%% Ignore xref warnings
%% --------------------------------------------------------------------

%% Called by `erl_error` via the `error_info` annotation, not directly.
-ignore_xref([format_error/2]).
-export([sessions/1]).
-export([requests/1]).

%% --------------------------------------------------------------------
%% Macros
%% --------------------------------------------------------------------

-define(KEY(Name), {?MODULE, Name}).
-define(WS_OPTS, #{idle_timeout => infinity, max_frame_size => 10485760}).
-define(MAX_CONTENT_LENGTH, 10485760).

%% --------------------------------------------------------------------
%% API Functions
%% --------------------------------------------------------------------

-doc """
Serves the Arizona `routes` in `Opts` on the Cowboy listener `Ref` someone else
started, through `arizona_cowboy_middleware` in its middleware chain. Refused
when `Ref` already serves Arizona routes.
""".
-spec mount(Ref, Opts) -> ok | {error, {already_started, Ref}} when
    Ref :: atom(),
    Opts :: map().
mount(Ref, Opts0) ->
    case persistent_term:get(?KEY(Ref), undefined) of
        undefined ->
            #{routes := Routes} = Opts = arizona_config:resolve(Opts0),
            persistent_term:put(?KEY(Ref), (stash(Routes, Opts))#{owner => other}),
            arizona_server_registry:listener_up(?MODULE, Ref, Routes);
        _Serving ->
            {error, {already_started, Ref}}
    end.

-doc "Stops serving Arizona routes on the listener `Ref`, which stays up.".
-spec unmount(Ref) -> ok | {error, not_found} when
    Ref :: atom().
unmount(Ref) ->
    case persistent_term:get(?KEY(Ref), undefined) of
        #{owner := other} ->
            true = persistent_term:erase(?KEY(Ref)),
            arizona_server_registry:listener_down(Ref);
        _NotMounted ->
            {error, not_found}
    end.

-doc "Starts the Cowboy listener `Name` serving the Arizona `routes` in `Opts`.".
-spec start(Name, Opts) -> {ok, pid()} | {error, term()} when
    Name :: atom(),
    Opts :: map().
start(Name, Opts0) ->
    case persistent_term:get(?KEY(Name), undefined) of
        undefined ->
            start_new(Name, arizona_config:resolve(Opts0));
        _Running ->
            %% Refused before anything is written: the running listener's
            %% requests read the table under this name.
            {error, {already_started, Name}}
    end.

-doc "Stops the listener `Name` and forgets its routes.".
-spec stop(Name) -> ok | {error, not_found} when
    Name :: atom().
stop(Name) ->
    case persistent_term:get(?KEY(Name), undefined) of
        #{owner := other} -> unmount(Name);
        _Owned -> stop_listener(Name)
    end.

-doc """
Drains the listener `Name`: stops accepting connections, tells every live
session `{arizona_drain, Deadline}` (through `arizona_socket:drain/2`), and waits
up to `Timeout` milliseconds for every request in flight -- a page, a controller
reply, a loop, a WebSocket session -- to finish, then stops it, closing the idle
keep-alive connections and killing what is left.
""".
-spec drain(Name, Timeout) -> ok | {error, not_found} when
    Name :: atom(),
    Timeout :: non_neg_integer().
drain(Name, Timeout) ->
    case persistent_term:get(?KEY(Name), undefined) of
        undefined ->
            {error, not_found};
        Stash ->
            %% A mounted listener is its owner's to close; only the Arizona
            %% sessions and requests on it are wound down.
            ok = suspend_owned(Stash, Name),
            Deadline = erlang:monotonic_time(millisecond) + Timeout,
            ok = notify_sessions(Name, Deadline),
            ok = await_requests(Name, Deadline),
            stop(Name)
    end.

-doc """
Tells every live session of the listener `Name` `{arizona_drain, Deadline}`, as
`drain/2` does, while the listener keeps accepting.
""".
-spec notify_drain(Name, Timeout) -> ok | {error, not_found} when
    Name :: atom(),
    Timeout :: non_neg_integer().
notify_drain(Name, Timeout) ->
    case persistent_term:get(?KEY(Name), undefined) of
        undefined -> {error, not_found};
        _Stash -> notify_sessions(Name, erlang:monotonic_time(millisecond) + Timeout)
    end.

-doc "Recompiles every running listener's routes from the list it started with.".
-spec recompile_routes() -> ok.
recompile_routes() ->
    lists:foreach(
        fun
            ({?KEY(Name), #{routes := Routes, build_opts := BuildOpts} = Stash}) ->
                Table = arizona_route_table:compile(Routes, BuildOpts, ?MODULE),
                persistent_term:put(?KEY(Name), Stash#{table => Table});
            (_Other) ->
                ok
        end,
        persistent_term:get()
    ).

-doc "Every controller reply kind, the MCP route and the dev reload route.".
-spec capabilities() -> #{routes := [mcp | reload], replies := [stream | sendfile | loop]}.
capabilities() ->
    #{routes => [mcp, reload], replies => [stream, sendfile, loop]}.

-doc "The compiled route table of the listener `Name`.".
-spec table(Name) -> arizona_route_table:table() when
    Name :: atom().
table(Name) ->
    #{table := Table} = persistent_term:get(?KEY(Name)),
    Table.

-doc "The `cowboy_websocket` options of the listener `Name`'s live sessions.".
-spec ws_opts(Name) -> map() when
    Name :: atom().
ws_opts(Name) ->
    #{ws_opts := WsOpts} = persistent_term:get(?KEY(Name)),
    WsOpts.

-doc "The compiled route table of the listener `Ref`, if it serves Arizona routes.".
-spec find_table(Ref) -> {ok, arizona_route_table:table()} | error when
    Ref :: atom().
find_table(Ref) ->
    case persistent_term:get(?KEY(Ref), undefined) of
        #{table := Table} -> {ok, Table};
        undefined -> error
    end.

-doc "The largest request body the listener `Name` lets a controller read.".
-spec max_content_length(Name) -> non_neg_integer() when
    Name :: atom().
max_content_length(Name) ->
    #{max_content_length := Max} = persistent_term:get(?KEY(Name)),
    Max.

-doc "Renders this module's configuration errors.".
-spec format_error(Reason, Stacktrace) -> ErrorInfo when
    Reason :: term(),
    Stacktrace :: [tuple()],
    ErrorInfo :: #{general := iolist()}.
format_error(https_requires_tls, _ST) ->
    #{general => "scheme => https requires tls => [...]"};
format_error(tls_with_http_scheme, _ST) ->
    #{
        general =>
            "tls => [...] implies https; drop scheme => http (or drop tls) "
            "instead of serving the configured certs' traffic in cleartext"
    };
format_error({bad_scheme, Scheme}, _ST) ->
    #{general => io_lib:format("scheme must be http or https, not ~0tp", [Scheme])}.

-doc """
The pubsub group of the listener's requests in flight, every process answering
one; a process leaves it when it exits.
""".
-spec requests(Name) -> {?MODULE, requests, atom()} when
    Name :: atom().
requests(Name) ->
    {?MODULE, requests, Name}.

-doc "The pubsub group of the listener's live WebSocket sessions.".
-spec sessions(Name) -> {?MODULE, sessions, atom()} when
    Name :: atom().
sessions(Name) ->
    {?MODULE, sessions, Name}.

%% --------------------------------------------------------------------
%% Internal functions
%% --------------------------------------------------------------------

start_new(Name, #{routes := Routes} = Opts) ->
    Tls = tls(Opts),
    Stash = stash(Routes, Opts),
    {ok, _} = application:ensure_all_started(cowboy),
    persistent_term:put(?KEY(Name), Stash#{owner => self}),
    Dispatch = cowboy_router:compile([{'_', [{"/[...]", arizona_cowboy_handler, Name}]}]),
    ProtoOpts = maps:merge(
        #{env => #{dispatch => Dispatch}, enable_connect_protocol => true},
        maps:get(proto_opts, Opts, #{})
    ),
    case start_listener(Name, Tls, transport_opts(Opts), ProtoOpts) of
        {ok, _Pid} = Ok ->
            ok = arizona_server_registry:listener_up(?MODULE, Name, Routes),
            Ok;
        {error, _Reason} = Error ->
            persistent_term:erase(?KEY(Name)),
            Error
    end.

stop_listener(Name) ->
    %% The listener goes first: a request still in flight reads the table.
    Result = cowboy:stop_listener(Name),
    persistent_term:erase(?KEY(Name)),
    ok = arizona_server_registry:listener_down(Name),
    Result.

%% What a request on the listener reads: the compiled routes and the per-session
%% limits, the same whether this adapter started the listener or mounted on it.
stash(Routes, Opts) ->
    %% `error_page` rides along only when the listener sets one.
    BuildOpts = maps:merge(
        #{compress => maps:get(compress, Opts, true)}, maps:with([error_page], Opts)
    ),
    #{
        routes => Routes,
        build_opts => BuildOpts,
        table => arizona_route_table:compile(Routes, BuildOpts, ?MODULE),
        ws_opts => maps:merge(?WS_OPTS, maps:get(ws_opts, Opts, #{})),
        max_content_length => maps:get(max_content_length, Opts, ?MAX_CONTENT_LENGTH)
    }.

suspend_owned(#{owner := self}, Name) ->
    ranch:suspend_listener(Name);
suspend_owned(#{owner := other}, _Name) ->
    ok.

start_listener(Name, none, TransportOpts, ProtoOpts) ->
    cowboy:start_clear(Name, TransportOpts, ProtoOpts);
start_listener(Name, Tls, TransportOpts, ProtoOpts) ->
    cowboy:start_tls(Name, TransportOpts ++ Tls, ProtoOpts).

%% The TLS options the listener serves with, or `none` for plain HTTP. `tls`
%% alone means https; either half of the pair without the other is refused
%% rather than served in cleartext.
tls(#{scheme := http, tls := _} = Opts) ->
    config_error(tls_with_http_scheme, Opts);
tls(#{tls := Tls}) ->
    Tls;
tls(#{scheme := https} = Opts) ->
    config_error(https_requires_tls, Opts);
tls(#{scheme := http}) ->
    none;
tls(#{scheme := Scheme} = Opts) ->
    config_error({bad_scheme, Scheme}, Opts);
tls(#{}) ->
    none.

config_error(Reason, Opts) ->
    erlang:error(Reason, [Opts], [{error_info, #{module => ?MODULE}}]).

transport_opts(Opts) ->
    TransportOpts = maps:get(transport_opts, Opts, []),
    case lists:keymember(port, 1, TransportOpts) of
        true -> TransportOpts;
        false -> [{port, 4040} | TransportOpts]
    end.

notify_sessions(Name, Deadline) ->
    arizona_pubsub:broadcast(sessions(Name), {arizona_cowboy_drain, Deadline}).

%% A process leaves its group when it exits. A WebSocket session counts too: it
%% leaves the request process when it upgrades and joins `sessions/1`.
await_requests(Name, Deadline) ->
    Idle =
        arizona_pubsub:subscribers(requests(Name)) =:= [] andalso
            arizona_pubsub:subscribers(sessions(Name)) =:= [],
    case Idle orelse erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            ok;
        false ->
            receive
            after 20 -> await_requests(Name, Deadline)
            end
    end.
