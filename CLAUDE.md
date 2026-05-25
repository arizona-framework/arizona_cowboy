# arizona_cowboy

Cowboy HTTP/WebSocket adapter for the
[Arizona](https://github.com/arizona-framework/arizona) framework.

See [arizona/CLAUDE.md](../arizona/CLAUDE.md) for the engine overview,
architecture, and conventions. This repo ships only the seven
`arizona_cowboy_*` modules that implement the `arizona_req` behaviour and
the matching listener/router/HTTP/WS/static/reload handlers.

## Build & test

```bash
rebar3 compile
make precommit             # fmt + check-fast + tests
make ci                    # full CI: check + test + cover + doc
```
