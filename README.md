# jido_aph

APH-notarized signals for jido agents: a guard plugin and an honest-depth
demo. **Scaffold stage** — see `PRDs/PRD-001-Jido-APH-Guard.md` for what this
becomes; this README is a stub and will be rewritten (PRD-001 T14).

Community integration, not an agentjido package.

## Toolchain (actually proven on this scaffold, 2026-08-27)

- Elixir 1.20.3 / Erlang OTP 29.0.5 (jido's floor is `~> 1.18`, which this
  satisfies; the PRD's "1.18 / OTP 27" wording names the floor, not the run)
- cargo 1.96.0 (mandatory — the aph-ex rustler NIF compiles from source;
  no prebuilt `.so` ships)
- node v26.3.0 (optional, deep-verify leg only; not required for `mix test`)

## Setup

Clone `aph` (github.com/squillo/aph) and this repo as siblings — the
dependency is `{:aph, path: "../aph/interpreters/elixir"}`. Then:

```sh
mix deps.get
mix test
```

The first compile builds the aph-ex NIF and jido; expect several minutes.
