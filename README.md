# arizona_cowboy

Cowboy HTTP/WebSocket adapter for the [Arizona](https://github.com/arizona-framework/arizona)
real-time web framework.

Implements the `arizona_req` behaviour against Cowboy and ships a listener boot
helper plus the matching router/HTTP/WS/static/reload handlers.

This is the **alternate** adapter -- use it when you need OTP 28 compatibility.
The default and recommended adapter is
[`arizona_roadrunner`](https://github.com/arizona-framework/arizona_roadrunner)
(requires OTP 29+).

## Requirements

- Erlang/OTP 28 or newer
- [Arizona](https://github.com/arizona-framework/arizona) `~> 0.1`
- [Cowboy](https://github.com/ninenines/cowboy) `~> 2.14`

## Installation

```erlang
{deps, [
    {arizona, "~> 0.1"},
    {arizona_cowboy, "~> 0.1"}
]}.
```

Add to your `.app.src` `applications` list:

```erlang
{applications, [kernel, stdlib, arizona, arizona_cowboy]}.
```

## Configuration

Tell Arizona to boot Cowboy by setting `adapter => arizona_cowboy_server` in
the `arizona` server env:

```erlang
[{arizona, [
    {server, #{
        adapter => arizona_cowboy_server,
        scheme => http,
        transport_opts => [{port, 4040}],
        routes => [
            {live, ~"/", my_page, #{layouts => [{my_layout, render}]}},
            {ws, ~"/ws", #{}},
            {asset, ~"/assets", {priv_dir, my_app, "static/assets"}}
        ]
    }}
]}].
```

`arizona_cowboy_server:start/2` calls `application:ensure_all_started(cowboy)`
itself, so cowboy doesn't need to be listed before `arizona` in your
`applications`.

## Modules

| Module                    | Purpose                                                          |
| ------------------------- | ---------------------------------------------------------------- |
| `arizona_cowboy_server`   | Listener boot — compiles routes, starts clear/TLS Cowboy         |
| `arizona_cowboy_router`   | Translates Arizona routes into a Cowboy dispatch table           |
| `arizona_cowboy_http`     | HTTP handler — delegates to `arizona_http:render/3`              |
| `arizona_cowboy_ws`       | WebSocket handler — delegates to `arizona_ws:prepare/3`          |
| `arizona_cowboy_static`   | Static file handler (directory + priv_dir)                       |
| `arizona_cowboy_req`      | `arizona_req` adapter for Cowboy requests                        |
| `arizona_cowboy_reload`   | Dev SSE endpoint streaming `arizona_reloader` events             |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache-2.0. See [LICENSE.md](LICENSE.md).
