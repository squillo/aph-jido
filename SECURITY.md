# Security

## This is not a security product

`aph-jido` is a draft example. It demonstrates how a jido agent can refuse to
act on a signal that carries no APH notarization envelope, and it is scrupulous
about the fact that **the gate it demonstrates is structural, not
cryptographic**. Read the depth table in `README.md` before deciding what this
protects.

Specifically, and to save you the trip: `JidoAph.Guard` checks a byte bound, a
strict parse, an attestation-mode policy, and proof-chain *structure*. It
verifies **no signature**, resolves **no key**, checks **no validity window**,
consults **no revocation status**, and recomputes **no body hash**. An envelope
this guard admits may be a forgery. That is not a defect to report — it is the
documented boundary, and the demo's whole teaching point is that a structurally
perfect forgery passes the guard and is caught only by the deep leg.

Do not deploy this as an authorization control.

## Reporting a vulnerability

If you find a flaw in this repository's own code — the guard admitting
something its own documentation says it refuses, the sidecar reporting a
tooling failure as a protocol verdict, a refusal that can be bypassed — open an
issue on this repository. If it is sensitive enough that a public issue is the
wrong first move, use GitHub's private vulnerability reporting on this
repository instead.

Two classes of report belong somewhere else:

- **Flaws in the APH protocol or its reference implementation** belong to
  [squillo/aph](https://github.com/squillo/aph); see that repository's
  `SECURITY.md` and `spec/security-considerations.md`.
- **Flaws in jido** belong to [agentjido/jido](https://github.com/agentjido/jido).
  Nothing here is maintained by that project.

## No support commitment

This repository is a draft with no release, no Hex package, and no maintenance
promise. Reports are welcome and will be read; nothing here guarantees a
response time or a fix.
