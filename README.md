# arizona_cowboy

Cowboy HTTP/WebSocket server adapter for the
[Arizona](https://github.com/arizona-framework/arizona) real-time web framework.

It implements Arizona's `arizona_server` and `arizona_req` behaviours on
[Cowboy](https://github.com/ninenines/cowboy). The contract it meets, and the conformance
suite that verifies it, are described in Arizona's
[adapter guide](https://github.com/arizona-framework/arizona/blob/main/docs/adapters.md).

## Requirements

- Erlang/OTP 29 or newer
- [Arizona](https://github.com/arizona-framework/arizona) 0.4 or newer

## Installation

Depend on both Arizona and the adapter: the adapter does not pull Arizona in
itself (Arizona's own test suites depend on it, and a dependency back would be
a cycle).

```erlang
{deps, [
    {arizona, "~> 0.4"},
    {arizona_cowboy, "~> 0.1"}
]}.
```

and list both in your application's `applications`:

```erlang
{applications, [kernel, stdlib, arizona, arizona_cowboy]}.
```

## Configuration

Name the adapter in the `arizona` server env; Arizona has no default:

```erlang
[{arizona, [
    {server, #{
        adapter => arizona_cowboy_server,
        transport_opts => [{port, 4040}],
        routes => [
            {live, ~"/", my_page, #{layouts => [{my_layout, render}]}},
            {ws, ~"/ws", #{}},
            {asset, ~"/assets", {priv_dir, my_app, "static/assets"}}
        ]
    }}
]}].
```

A TLS listener (`scheme => https` with a `tls` list) negotiates HTTP/2 or
HTTP/1.1 by ALPN, and a live session may open its WebSocket over HTTP/2.
Cowboy's own protocol options go in `proto_opts`; see
`arizona_cowboy_server` for the rest.

## On a listener another framework owns

`arizona_cowboy_server:mount/2` serves Arizona routes on a Cowboy listener something else
started (a Nova or plain Cowboy app): put `arizona_cowboy_middleware` before the owner's router
in the listener's middlewares, and mount the routes under the listener's ref. Requests an
Arizona route matches are served exactly as on a listener this adapter started; everything else
continues down the owner's chain.

```erlang
{ok, _} = cowboy:start_clear(my_listener, [{port, 8080}], #{
    middlewares => [arizona_cowboy_middleware, cowboy_router, cowboy_handler],
    env => #{dispatch => MyDispatch}
}),
ok = arizona_cowboy_server:mount(my_listener, #{routes => ArizonaRoutes}).
```

## Modules

| Module | Purpose |
| ------ | ------- |
| `arizona_cowboy_server` | The `arizona_server` adapter: boots, drains and stops listeners |
| `arizona_cowboy_handler` | The listener's one handler: routes with `arizona_route_table` |
| `arizona_cowboy_req` | The `arizona_req` adapter |
| `arizona_cowboy_middleware` | Serves mounted Arizona routes on a listener another framework owns |

## Development

```bash
make precommit         # fmt, compile, checks, tests
make test-conformance  # Arizona's conformance suite against this checkout
make ci                # everything CI runs
```

`make test-conformance` clones Arizona (`ARIZONA_REF`, default its `main`)
and runs its conformance suite with this checkout linked in through
`_checkouts`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache-2.0. See [LICENSE.md](LICENSE.md).
