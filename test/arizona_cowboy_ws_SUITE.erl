-module(arizona_cowboy_ws_SUITE).
-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("arizona/include/arizona_ops.hrl").
-include_lib("arizona/include/arizona_js.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, groups/0]).
-export([
    ping_pong/1,
    event_dispatch/1,
    event_with_effects/1,
    event_no_change/1,
    unknown_json/1,
    unknown_frame/1,
    reconnect_init/1,
    connect_with_params/1,
    http_query_params/1,
    http_path_bindings/1,
    ws_path_bindings/1,
    middleware_cont_enriches_bindings/1,
    middleware_cont_ws_connects/1,
    middleware_halt_redirects/1,
    middleware_halt_rejects_ws/1,
    middleware_pipeline_runs_in_order/1,
    middleware_halt_redirects_on_navigate/1,
    middleware_cont_on_navigate/1,
    http_halt_redirect_via_req/1,
    http_render_crash_emits_error_page/1,
    http_reads_cookies_headers_body/1,
    static_asset_served/1,
    static_asset_body_matches_file/1,
    static_asset_missing_returns_404/1,
    reload_endpoint_streams_event/1,
    recompile_routes_runs/1,
    http_preserves_duplicate_qs_keys/1,
    ws_navigate_preserves_duplicate_qs_keys/1,
    ws_upgrade_preserves_duplicate_qs_keys/1,
    crash_event_closes/1,
    crash_info_closes/1,
    crash_init_closes/1,
    normal_exit_closes/1
]).

all() ->
    [{group, basic}, {group, crash_recovery}].

groups() ->
    Basic = [
        ping_pong,
        event_dispatch,
        event_with_effects,
        event_no_change,
        unknown_json,
        unknown_frame,
        reconnect_init,
        connect_with_params,
        http_query_params,
        http_path_bindings,
        ws_path_bindings,
        middleware_cont_enriches_bindings,
        middleware_cont_ws_connects,
        middleware_halt_redirects,
        middleware_halt_rejects_ws,
        middleware_pipeline_runs_in_order,
        middleware_halt_redirects_on_navigate,
        middleware_cont_on_navigate,
        http_halt_redirect_via_req,
        http_render_crash_emits_error_page,
        http_reads_cookies_headers_body,
        static_asset_served,
        static_asset_body_matches_file,
        static_asset_missing_returns_404,
        reload_endpoint_streams_event,
        recompile_routes_runs,
        http_preserves_duplicate_qs_keys,
        ws_navigate_preserves_duplicate_qs_keys,
        ws_upgrade_preserves_duplicate_qs_keys
    ],
    Crash = [
        crash_event_closes,
        crash_info_closes,
        crash_init_closes,
        normal_exit_closes
    ],
    [
        {basic, [sequence], Basic},
        {crash_recovery, [sequence], Crash}
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(arizona),
    {ok, _} = application:ensure_all_started(cowboy),
    Port = pick_port(),
    UrlToBindings =
        fun(Req, B) ->
            {PathBs, Req1} = arizona_req:bindings(Req),
            {Params, Req2} = arizona_req:params(Req1),
            ParamsMap = maps:from_list(Params),
            {cont, Req2, maps:merge(maps:merge(B, PathBs), ParamsMap)}
        end,
    DupePreserving =
        fun(Req, B) ->
            {Params, Req1} = arizona_req:params(Req),
            Values = [V || {K, V} <:- Params, K =:= ~"foo"],
            Joined = iolist_to_binary(lists:join(~",", Values)),
            {cont, Req1, B#{status => <<"foo=[", Joined/binary, "]">>}}
        end,
    Routes = [
        {live, <<"/">>, arizona_crashable, #{middlewares => [UrlToBindings]}},
        {live, <<"/crash_on_mount">>, arizona_crashable, #{
            bindings => #{crash_on_mount => true}
        }},
        {live, <<"/with_middleware">>, arizona_crashable, #{
            middlewares => [fun(Req, B) -> {cont, Req, B#{session => <<"abc">>}} end]
        }},
        {live, <<"/halt_middleware">>, arizona_crashable, #{
            middlewares => [
                fun(Req, _B) ->
                    {halt, arizona_req:redirect(Req, <<"/login">>)}
                end
            ]
        }},
        {live, <<"/pipeline">>, arizona_crashable, #{
            middlewares => [
                fun(Req, B) -> {cont, Req, B#{step => 1}} end,
                fun(Req, #{step := N} = B) -> {cont, Req, B#{step => N + 1}} end
            ]
        }},
        {live, <<"/navigate_halt_redirect">>, arizona_crashable, #{
            middlewares => [
                fun(Req, _B) -> {halt, arizona_req:redirect(Req, <<"/login">>)} end
            ]
        }},
        {live, <<"/navigate_enriched">>, arizona_crashable, #{
            middlewares => [
                fun(Req, B) -> {cont, Req, B#{session => <<"from_navigate">>}} end
            ]
        }},
        {live, <<"/items/:item_id">>, arizona_crashable, #{middlewares => [UrlToBindings]}},
        {live, <<"/preserves_dupes">>, arizona_crashable, #{middlewares => [DupePreserving]}},
        {live, <<"/halt_redirect_req">>, arizona_crashable, #{
            middlewares => [
                fun(Req, _B) -> {halt, arizona_req:redirect(Req, <<"/login">>)} end
            ]
        }},
        {live, <<"/crash_on_render_http">>, arizona_crashable, #{
            bindings => #{crash_on_mount => true}
        }},
        {live, <<"/reads_cookies_headers_body">>, arizona_crashable, #{
            middlewares => [
                fun(Req, B) ->
                    {Cookies, Req1} = arizona_req:cookies(Req),
                    {Headers, Req2} = arizona_req:headers(Req1),
                    {Body, Req3} = arizona_req:body(Req2),
                    CookieCount = integer_to_binary(length(Cookies)),
                    HeaderCount = integer_to_binary(map_size(Headers)),
                    BodyLen = integer_to_binary(byte_size(Body)),
                    {cont, Req3, B#{
                        status => <<
                            "c=",
                            CookieCount/binary,
                            " h=",
                            HeaderCount/binary,
                            " b=",
                            BodyLen/binary
                        >>
                    }}
                end
            ]
        }},
        {ws, <<"/ws">>, #{}},
        {asset, <<"/assets">>, {priv_dir, arizona, "static/assets/js"}},
        {reload, <<"/reload">>, #{}}
    ],
    {ok, _} = arizona_cowboy_server:start(ws_test, #{
        transport_opts => [{port, Port}],
        routes => Routes
    }),
    [{port, Port} | Config].

end_per_suite(Config) ->
    _ = arizona_cowboy_server:stop(ws_test),
    _ = application:stop(arizona),
    Config.

pick_port() ->
    14040 + erlang:unique_integer([positive, monotonic]) rem 1000.

%% --------------------------------------------------------------------
%% Basic tests
%% --------------------------------------------------------------------

ping_pong(Config) ->
    {ok, Sock} = ws_connect(Config, <<"/">>),
    ok = ws_send(Sock, <<"0">>),
    {text, <<"1">>} = ws_recv(Sock),
    ws_close(Sock).

event_dispatch(Config) ->
    {ok, Sock} = ws_connect(Config, <<"/">>),
    ok = ws_send_json(Sock, [~"crashable", ~"set_status", #{~"value" => ~"updated"}]),
    {text, Resp} = ws_recv(Sock),
    Decoded = json:decode(Resp),
    ?assertMatch(#{~"o" := _}, Decoded),
    ws_close(Sock).

event_with_effects(Config) ->
    {ok, Sock} = ws_connect(Config, <<"/">>),
    ok = ws_send_json(Sock, [~"crashable", ~"with_effect", #{}]),
    {text, Resp} = ws_recv(Sock),
    Decoded = json:decode(Resp),
    ?assertMatch(#{~"e" := _}, Decoded),
    ws_close(Sock).

event_no_change(Config) ->
    {ok, Sock} = ws_connect(Config, <<"/">>),
    ok = ws_send_json(Sock, [~"crashable", ~"set_status", #{~"value" => ~"ok"}]),
    ok = ws_send(Sock, <<"0">>),
    {text, <<"1">>} = ws_recv(Sock),
    ws_close(Sock).

unknown_json(Config) ->
    {ok, Sock} = ws_connect(Config, <<"/">>),
    ok = ws_send_json(Sock, #{~"unknown" => ~"message"}),
    ok = ws_send(Sock, <<"0">>),
    {text, <<"1">>} = ws_recv(Sock),
    ws_close(Sock).

unknown_frame(Config) ->
    {ok, Sock} = ws_connect(Config, <<"/">>),
    ok = ws_send_binary_frame(Sock, <<"binary data">>),
    ok = ws_send(Sock, <<"0">>),
    {text, <<"1">>} = ws_recv(Sock),
    ws_close(Sock).

connect_with_params(Config) ->
    {ok, Sock} = ws_connect(Config, <<"/">>, [{params, #{~"locale" => ~"pt"}}]),
    ok = ws_send(Sock, <<"0">>),
    {text, <<"1">>} = ws_recv(Sock),
    ws_close(Sock).

http_query_params(Config) ->
    Port = proplists:get_value(port, Config),
    {ok, Sock} = gen_tcp:connect("localhost", Port, [binary, {active, false}]),
    Req = [
        "GET /?locale=pt HTTP/1.1\r\n",
        "Host: localhost:",
        integer_to_list(Port),
        "\r\n",
        "\r\n"
    ],
    ok = gen_tcp:send(Sock, Req),
    {ok, Resp} = gen_tcp:recv(Sock, 0, 5000),
    gen_tcp:close(Sock),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"pt<!--/az-->">>)).

http_path_bindings(Config) ->
    Port = proplists:get_value(port, Config),
    {ok, Sock} = gen_tcp:connect("localhost", Port, [binary, {active, false}]),
    Req = [
        "GET /items/my-item HTTP/1.1\r\n",
        "Host: localhost:",
        integer_to_list(Port),
        "\r\n",
        "\r\n"
    ],
    ok = gen_tcp:send(Sock, Req),
    {ok, Resp} = gen_tcp:recv(Sock, 0, 5000),
    gen_tcp:close(Sock),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"my-item">>)).

ws_path_bindings(Config) ->
    {ok, Sock} = ws_connect(Config, <<"/items/my-item">>),
    ok = ws_send(Sock, <<"0">>),
    {text, <<"1">>} = ws_recv(Sock),
    ws_close(Sock).

middleware_cont_enriches_bindings(Config) ->
    Port = proplists:get_value(port, Config),
    {ok, Sock} = gen_tcp:connect("localhost", Port, [binary, {active, false}]),
    Req = [
        "GET /with_middleware HTTP/1.1\r\n",
        "Host: localhost:",
        integer_to_list(Port),
        "\r\n",
        "\r\n"
    ],
    ok = gen_tcp:send(Sock, Req),
    {ok, Resp} = gen_tcp:recv(Sock, 0, 5000),
    gen_tcp:close(Sock),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"200 OK">>)).

middleware_cont_ws_connects(Config) ->
    {ok, Sock} = ws_connect(Config, <<"/with_middleware">>),
    ok = ws_send(Sock, <<"0">>),
    {text, <<"1">>} = ws_recv(Sock),
    ws_close(Sock).

middleware_halt_redirects(Config) ->
    Port = proplists:get_value(port, Config),
    {ok, Sock} = gen_tcp:connect("localhost", Port, [binary, {active, false}]),
    Req = [
        "GET /halt_middleware HTTP/1.1\r\n",
        "Host: localhost:",
        integer_to_list(Port),
        "\r\n",
        "\r\n"
    ],
    ok = gen_tcp:send(Sock, Req),
    {ok, Resp} = gen_tcp:recv(Sock, 0, 5000),
    gen_tcp:close(Sock),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"302">>)),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"/login">>)).

middleware_halt_rejects_ws(Config) ->
    Port = proplists:get_value(port, Config),
    {ok, Sock} = gen_tcp:connect("localhost", Port, [binary, {active, false}]),
    Key = base64:encode(crypto:strong_rand_bytes(16)),
    Req = [
        "GET /ws?_az_path=/halt_middleware HTTP/1.1\r\n",
        "Host: localhost:",
        integer_to_list(Port),
        "\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Key: ",
        Key,
        "\r\n",
        "Sec-WebSocket-Version: 13\r\n",
        "\r\n"
    ],
    ok = gen_tcp:send(Sock, Req),
    {ok, Resp} = gen_tcp:recv(Sock, 0, 5000),
    gen_tcp:close(Sock),
    ?assertEqual(nomatch, binary:match(Resp, <<"101">>)),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"302">>)).

middleware_pipeline_runs_in_order(Config) ->
    Port = proplists:get_value(port, Config),
    {ok, Sock} = gen_tcp:connect("localhost", Port, [binary, {active, false}]),
    Req = [
        "GET /pipeline HTTP/1.1\r\n",
        "Host: localhost:",
        integer_to_list(Port),
        "\r\n",
        "\r\n"
    ],
    ok = gen_tcp:send(Sock, Req),
    {ok, Resp} = gen_tcp:recv(Sock, 0, 5000),
    gen_tcp:close(Sock),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"200 OK">>)).

middleware_halt_redirects_on_navigate(Config) ->
    {ok, Sock} = ws_connect(Config, <<"/">>),
    ok = ws_send_json(Sock, [~"navigate", #{~"path" => ~"/navigate_halt_redirect", ~"qs" => ~""}]),
    {text, Resp} = ws_recv(Sock),
    Decoded = json:decode(Resp),
    ?assertMatch(#{~"e" := [_ | _]}, Decoded),
    ?assertNot(maps:is_key(~"o", Decoded)),
    [[OpCode | Rest] | _] = maps:get(~"e", Decoded),
    ?assertEqual(?JS_NAVIGATE, OpCode),
    ?assertEqual(~"/login", hd(Rest)),
    ws_close(Sock).

middleware_cont_on_navigate(Config) ->
    {ok, Sock} = ws_connect(Config, <<"/">>),
    ok = ws_send_json(Sock, [~"navigate", #{~"path" => ~"/navigate_enriched", ~"qs" => ~""}]),
    {text, Resp} = ws_recv(Sock),
    Decoded = json:decode(Resp),
    ?assertMatch(#{~"o" := [[?OP_REPLACE, _, _]]}, Decoded),
    ws_close(Sock).

http_halt_redirect_via_req(Config) ->
    Port = proplists:get_value(port, Config),
    {ok, Sock} = gen_tcp:connect("localhost", Port, [binary, {active, false}]),
    Req = [
        "GET /halt_redirect_req HTTP/1.1\r\n",
        "Host: localhost:",
        integer_to_list(Port),
        "\r\n\r\n"
    ],
    ok = gen_tcp:send(Sock, Req),
    {ok, Resp} = gen_tcp:recv(Sock, 0, 5000),
    gen_tcp:close(Sock),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"302">>)),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"location: /login">>)).

http_render_crash_emits_error_page(Config) ->
    Port = proplists:get_value(port, Config),
    {ok, Sock} = gen_tcp:connect("localhost", Port, [binary, {active, false}]),
    Req = [
        "GET /crash_on_render_http HTTP/1.1\r\n",
        "Host: localhost:",
        integer_to_list(Port),
        "\r\n\r\n"
    ],
    ok = gen_tcp:send(Sock, Req),
    {ok, Resp} = gen_tcp:recv(Sock, 0, 5000),
    gen_tcp:close(Sock),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"500">>)),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"crash_on_mount">>)).

static_asset_served(Config) ->
    Port = proplists:get_value(port, Config),
    {ok, Sock} = gen_tcp:connect("localhost", Port, [binary, {active, false}]),
    Req = [
        "GET /assets/arizona.min.js HTTP/1.1\r\n",
        "Host: localhost:",
        integer_to_list(Port),
        "\r\n\r\n"
    ],
    ok = gen_tcp:send(Sock, Req),
    {ok, Resp} = gen_tcp:recv(Sock, 0, 5000),
    gen_tcp:close(Sock),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"200 OK">>)),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"content-type: application/javascript">>)).

static_asset_body_matches_file(Config) ->
    Port = proplists:get_value(port, Config),
    FilePath = filename:join([
        code:priv_dir(arizona), "static", "assets", "js", "arizona.min.js"
    ]),
    {ok, Expected} = file:read_file(FilePath),
    Body = http_get_body(Port, <<"/assets/arizona.min.js">>),
    ?assertEqual(Expected, Body).

static_asset_missing_returns_404(Config) ->
    Port = proplists:get_value(port, Config),
    {ok, Sock} = gen_tcp:connect("localhost", Port, [binary, {active, false}]),
    Req = [
        "GET /assets/does-not-exist.js HTTP/1.1\r\n",
        "Host: localhost:",
        integer_to_list(Port),
        "\r\n\r\n"
    ],
    ok = gen_tcp:send(Sock, Req),
    {ok, Resp} = gen_tcp:recv(Sock, 0, 5000),
    gen_tcp:close(Sock),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"404">>)).

http_preserves_duplicate_qs_keys(Config) ->
    Port = proplists:get_value(port, Config),
    {ok, Sock} = gen_tcp:connect("localhost", Port, [binary, {active, false}]),
    Req = [
        "GET /preserves_dupes?foo=bar&foo=baz&foo=qux HTTP/1.1\r\n",
        "Host: localhost:",
        integer_to_list(Port),
        "\r\n\r\n"
    ],
    ok = gen_tcp:send(Sock, Req),
    {ok, Resp} = gen_tcp:recv(Sock, 0, 5000),
    gen_tcp:close(Sock),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"200 OK">>)),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"foo=[bar,baz,qux]">>)).

ws_navigate_preserves_duplicate_qs_keys(Config) ->
    {ok, Sock} = ws_connect(Config, <<"/">>),
    ok = ws_send_json(Sock, [
        ~"navigate",
        #{~"path" => ~"/preserves_dupes", ~"qs" => ~"foo=bar&foo=baz&foo=qux"}
    ]),
    {text, Resp} = ws_recv(Sock),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"foo=[bar,baz,qux]">>)),
    ws_close(Sock).

ws_upgrade_preserves_duplicate_qs_keys(Config) ->
    {ok, Sock} = ws_connect(Config, <<"/preserves_dupes">>, [
        {reconnect, true},
        {raw_qs, <<"foo=bar&foo=baz">>}
    ]),
    {text, Resp} = ws_recv(Sock),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"foo=[bar,baz]">>)),
    ws_close(Sock).

recompile_routes_runs(Config) when is_list(Config) ->
    ?assertEqual(ok, arizona_cowboy_server:recompile_routes()).

reload_endpoint_streams_event(Config) ->
    %% Exercises `arizona_cowboy_reload:init/2` and `info/3`.
    Port = proplists:get_value(port, Config),
    {ok, Sock} = gen_tcp:connect("localhost", Port, [binary, {active, false}]),
    Req = [
        "GET /reload HTTP/1.1\r\n",
        "Host: localhost:",
        integer_to_list(Port),
        "\r\n",
        "Accept: text/event-stream\r\n",
        "\r\n"
    ],
    ok = gen_tcp:send(Sock, Req),
    wait_for_subscriber(1000),
    ok = arizona_reloader:broadcast(),
    Data1 = recv_until(Sock, <<"event: reload\n">>, 5000),
    ?assertNotEqual(nomatch, binary:match(Data1, <<"200 OK">>)),
    ?assertNotEqual(nomatch, binary:match(Data1, <<"text/event-stream">>)),
    ?assertNotEqual(nomatch, binary:match(Data1, <<"event: reload\n">>)),
    ok = arizona_reloader:reload_css(),
    Data2 = recv_until(Sock, <<"event: reload_css">>, 5000),
    ?assertNotEqual(nomatch, binary:match(Data2, <<"event: reload_css">>)),
    gen_tcp:close(Sock).

wait_for_subscriber(0) ->
    ok;
wait_for_subscriber(N) ->
    case arizona_pubsub:subscribers(arizona_reloader) of
        [] ->
            timer:sleep(20),
            wait_for_subscriber(N - 20);
        [_ | _] ->
            ok
    end.

recv_until(Sock, Needle, Timeout) ->
    recv_until(Sock, Needle, Timeout, <<>>).
recv_until(_Sock, _Needle, Timeout, Acc) when Timeout =< 0 ->
    Acc;
recv_until(Sock, Needle, Timeout, Acc) ->
    T0 = erlang:monotonic_time(millisecond),
    case gen_tcp:recv(Sock, 0, min(Timeout, 500)) of
        {ok, Chunk} ->
            Acc1 = <<Acc/binary, Chunk/binary>>,
            case binary:match(Acc1, Needle) of
                nomatch ->
                    Elapsed = erlang:monotonic_time(millisecond) - T0,
                    recv_until(Sock, Needle, Timeout - Elapsed, Acc1);
                _ ->
                    Acc1
            end;
        {error, timeout} ->
            Acc
    end.

http_reads_cookies_headers_body(Config) ->
    Port = proplists:get_value(port, Config),
    {ok, Sock} = gen_tcp:connect("localhost", Port, [binary, {active, false}]),
    Req = [
        "GET /reads_cookies_headers_body HTTP/1.1\r\n",
        "Host: localhost:",
        integer_to_list(Port),
        "\r\n",
        "Cookie: a=1; b=2\r\n",
        "\r\n"
    ],
    ok = gen_tcp:send(Sock, Req),
    {ok, Resp} = gen_tcp:recv(Sock, 0, 5000),
    gen_tcp:close(Sock),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"200 OK">>)),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"c=2">>)),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"b=0">>)).

reconnect_init(Config) ->
    {ok, Sock} = ws_connect(Config, <<"/">>, [{reconnect, true}]),
    {text, Resp} = ws_recv(Sock),
    Decoded = json:decode(Resp),
    ?assertMatch(#{~"o" := _}, Decoded),
    ws_close(Sock).

%% --------------------------------------------------------------------
%% Crash recovery tests
%% --------------------------------------------------------------------

crash_event_closes(Config) ->
    {ok, Sock} = ws_connect(Config, <<"/">>),
    ok = ws_send_json(Sock, [~"crashable", ~"crash", #{}]),
    {close, 4500, _} = ws_recv(Sock),
    gen_tcp:close(Sock).

crash_info_closes(Config) ->
    {ok, Sock} = ws_connect(Config, <<"/">>),
    ok = ws_send_json(Sock, [~"crashable", ~"crash_async", #{}]),
    {close, 4500, _} = ws_recv(Sock),
    gen_tcp:close(Sock).

crash_init_closes(Config) ->
    {ok, Sock} = ws_connect(Config, <<"/crash_on_mount">>),
    {close, 4500, _} = ws_recv(Sock),
    gen_tcp:close(Sock).

normal_exit_closes(Config) ->
    {ok, Sock} = ws_connect(Config, <<"/">>),
    ok = ws_send_json(Sock, [~"crashable", ~"set_status", #{~"value" => ~"alive"}]),
    _ = ws_recv(Sock, 1000),
    ws_close(Sock).

%% --------------------------------------------------------------------
%% Helpers reused from earlier tests
%% --------------------------------------------------------------------

%% Drains a full HTTP/1.1 response and returns just the body.
http_get_body(Port, Path) ->
    {ok, Sock} = gen_tcp:connect("localhost", Port, [binary, {active, false}]),
    Req = [
        "GET ",
        Path,
        " HTTP/1.1\r\n",
        "Host: localhost:",
        integer_to_list(Port),
        "\r\n",
        "Connection: close\r\n",
        "\r\n"
    ],
    ok = gen_tcp:send(Sock, Req),
    Full = read_until_close(Sock, <<>>),
    gen_tcp:close(Sock),
    case binary:split(Full, <<"\r\n\r\n">>) of
        [_Headers, Body] -> Body;
        _ -> <<>>
    end.

read_until_close(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Chunk} -> read_until_close(Sock, <<Acc/binary, Chunk/binary>>);
        {error, closed} -> Acc
    end.

%% --------------------------------------------------------------------
%% Minimal WebSocket client over gen_tcp
%% --------------------------------------------------------------------

ws_connect(Config, Path) ->
    ws_connect(Config, Path, []).

ws_connect(Config, Path, Opts) ->
    Port = proplists:get_value(port, Config),
    {ok, Sock} = gen_tcp:connect("localhost", Port, [
        binary, {active, false}, {packet, http_bin}
    ]),
    ok = ws_handshake(Sock, Port, Path, Opts),
    ok = inet:setopts(Sock, [{packet, raw}]),
    {ok, Sock}.

ws_handshake(Sock, Port, Path, Opts) ->
    Key = base64:encode(crypto:strong_rand_bytes(16)),
    Reconnect = proplists:get_value(reconnect, Opts, false),
    Params = proplists:get_value(params, Opts, #{}),
    RawQs = proplists:get_value(raw_qs, Opts, <<>>),
    ParamsQS =
        case map_size(Params) of
            0 -> "";
            _ -> [[$&, uri_string:quote(K), $=, uri_string:quote(V)] || K := V <- Params]
        end,
    RawSuffix =
        case RawQs of
            <<>> -> "";
            _ -> [$&, RawQs]
        end,
    QS =
        case Reconnect of
            true -> ["_az_path=", Path, "&_az_reconnect=1", ParamsQS, RawSuffix];
            false -> ["_az_path=", Path, ParamsQS, RawSuffix]
        end,
    Req = [
        "GET /ws?",
        QS,
        " HTTP/1.1\r\n",
        "Host: localhost:",
        integer_to_list(Port),
        "\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Key: ",
        Key,
        "\r\n",
        "Sec-WebSocket-Version: 13\r\n",
        "\r\n"
    ],
    ok = gen_tcp:send(Sock, Req),
    {ok, {http_response, _Version, 101, _Reason}} = gen_tcp:recv(Sock, 0, 5000),
    drain_http_headers(Sock).

drain_http_headers(Sock) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, http_eoh} -> ok;
        {ok, {http_header, _, _, _, _}} -> drain_http_headers(Sock)
    end.

ws_send_json(Sock, Term) ->
    ws_send(Sock, iolist_to_binary(json:encode(Term))).

ws_send(Sock, Payload) ->
    Frame = ws_encode_text(iolist_to_binary(Payload)),
    gen_tcp:send(Sock, Frame).

ws_send_binary_frame(Sock, Payload) ->
    Frame = ws_encode_binary(Payload),
    gen_tcp:send(Sock, Frame).

ws_recv(Sock) ->
    ws_recv(Sock, 5000).

ws_recv(Sock, Timeout) ->
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, Data} ->
            ws_decode(Data);
        {error, timeout} ->
            timeout;
        {error, closed} ->
            {error, closed};
        {error, Reason} ->
            {error, Reason}
    end.

ws_close(Sock) ->
    Mask = crypto:strong_rand_bytes(4),
    Frame = <<1:1, 0:3, 8:4, 1:1, 0:7, Mask/binary>>,
    ok = gen_tcp:send(Sock, Frame),
    ok = gen_tcp:close(Sock).

ws_encode_text(Payload) ->
    ws_encode_frame(1, Payload).

ws_encode_binary(Payload) ->
    ws_encode_frame(2, Payload).

ws_encode_frame(Opcode, Payload) ->
    Len = byte_size(Payload),
    Mask = crypto:strong_rand_bytes(4),
    Masked = ws_mask(Payload, Mask),
    case Len of
        L when L < 126 ->
            <<1:1, 0:3, Opcode:4, 1:1, L:7, Mask/binary, Masked/binary>>;
        L when L < 65536 ->
            <<1:1, 0:3, Opcode:4, 1:1, 126:7, L:16, Mask/binary, Masked/binary>>;
        L ->
            <<1:1, 0:3, Opcode:4, 1:1, 127:7, L:64, Mask/binary, Masked/binary>>
    end.

ws_mask(Payload, <<M0, M1, M2, M3>>) ->
    ws_mask(Payload, M0, M1, M2, M3, <<>>).

ws_mask(<<>>, _, _, _, _, Acc) ->
    Acc;
ws_mask(<<B, Rest/binary>>, M0, M1, M2, M3, Acc) ->
    ws_mask(Rest, M1, M2, M3, M0, <<Acc/binary, (B bxor M0)>>).

ws_decode(<<_Fin:1, _Rsv:3, 8:4, _M:1, Len:7, Rest/binary>>) when Len < 126 ->
    <<Code:16, Reason/binary>> =
        case Len of
            0 -> <<0:16>>;
            _ -> binary:part(Rest, 0, min(Len, byte_size(Rest)))
        end,
    {close, Code, Reason};
ws_decode(<<_Fin:1, _Rsv:3, Opcode:4, 0:1, Len:7, Rest/binary>>) when Len < 126 ->
    Payload = binary:part(Rest, 0, Len),
    {ws_opcode_to_type(Opcode), Payload};
ws_decode(<<_Fin:1, _Rsv:3, Opcode:4, 0:1, 126:7, Len:16, Rest/binary>>) ->
    Payload = binary:part(Rest, 0, Len),
    {ws_opcode_to_type(Opcode), Payload};
ws_decode(Data) ->
    {raw, Data}.

ws_opcode_to_type(1) -> text;
ws_opcode_to_type(2) -> binary;
ws_opcode_to_type(_) -> unknown.
