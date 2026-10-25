# arizona_cowboy

Cowboy HTTP/WebSocket server adapter for the
[Arizona](https://github.com/arizona-framework/arizona) framework: the
`arizona_cowboy_*` modules implementing Arizona's `arizona_server` and `arizona_req`
behaviours. The adapter contract is Arizona's `docs/adapters.md`; Arizona's
conformance suite is what verifies it (`make test-conformance`).

`arizona` is deliberately **not** a dependency, only a test-profile one:
Arizona's test profile depends on this package, and rebar3 refuses the cycle a
dependency back would make. The modules compile with
`nowarn_undefined_behaviour` for the same reason.

Requires Erlang/OTP 29+.

## Build & test

```bash
rebar3 compile
make precommit          # fmt + checks + tests
make test-conformance   # Arizona's conformance suite against this checkout
make ci                 # full CI
```
