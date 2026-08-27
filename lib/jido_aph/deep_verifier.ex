defmodule JidoAph.DeepVerifier do
  @moduledoc """
  The behaviour seam for cryptographic ("deep") verification. **Behaviour
  only — this library ships NO implementation**, and none is planned here:
  aph-ex's four-op surface is parity-locked, zero cryptography runs in
  Elixir, and both known implementation routes live OUTSIDE this library:

  1. **TS sidecar** — shell out (for example `System.cmd/3` to `node`) to a
     small script calling `verifyEnvelope` from the sibling clone's built
     TypeScript dist (`../aph/interpreters/typescript`). That verifier's
     option surface is the ground truth this behaviour's opts mirror:
     `now` (required — the TS module reads no clock), `requireMode`, `keys`,
     `bodyBytes`, `maxEnvelopeBytes`
     (`interpreters/typescript/src/verify.ts`, `VerifyOptions`).
  2. **Rust sidecar** — a separate process built on the published aph crates
     (the upstream Rust interpreter), spoken to over stdio or a socket.

  Deep verification is everything the `JidoAph.Guard` structural gate does
  NOT do (see the guard's checked/not-checked table): all Ed25519 signatures
  over JCS/RFC 8785, issuance order, embedded delegation-mandate binding,
  the validity window against a caller-pinned instant, `bodySha256`
  recomputed over the received body bytes, and the closed
  channel/contentClass vocabulary. Key discovery (DNS TXT / did:web
  fetching), revocation transport, and live notary contact belong to
  neither leg — an implementation of this behaviour still works offline
  from caller-supplied keys.

  ## The callback

  `verify(envelope_json, opts)` — `envelope_json` is the envelope as JSON
  TEXT, passed through byte-for-byte exactly as it crossed the wire (the
  untagged proof union is decided by the bytes; implementations MUST NOT
  re-serialize a parsed term back to JSON on the trust path). Returns
  `{:ok, map}` where the map reports what the implementation actually
  checked (the TS route's `VerifiedEnvelope` reports, for example, the mode
  the STRUCTURE proved and whether the body-hash step actually ran), or
  `{:error, term}` carrying the implementation's refusal.

  Documented `opts` (all optional at the behaviour level; a given
  implementation may require some — the TS route requires `:now`):

  - `:body_bytes` — the exact authorized body bytes as received (spec §8.3
    step 8 hashes the bytes the transport delivered, never a
    re-serialization; from a notarized signal these are
    `Base.decode64!(body_b64)` of the `JidoAph.Signal.Ext.Notarization`
    carry field).
  - `:now` — the instant to evaluate the validity window against, RFC 3339
    text. Implementations read no clock; a caller pinning a past instant
    (as the demo does, inside the golden's window) MUST say so in any
    transcript it prints — a pass at a pinned `now` is not a pass at wall
    clock.
  - `:require_mode` — `"PrincipalSigned"` or `"NotaryAttested"`, the §8.3.1
    step 1a policy gate. Omit to accept whichever mode the envelope proves.
  - `:keys` — out-of-band verification key material, keyed by DID URL or
    bare DID, for verification methods that cannot be decoded offline
    (every `did:web`, every DNS-published notary key). A `did:key` carries
    its own bytes and never needs an entry. Implementations MUST NOT fetch
    keys from the network.

  ## How the guard references this behaviour

  `JidoAph.Guard`'s config validation refuses `depth: :deep` unless
  `:deep_verifier` names a module implementing this behaviour — but in v1
  the guard's gate itself never invokes `verify/2`; the deep leg runs
  outside `prepare_signal/2`, owned by the application (the demo's
  `mix demo.deep_verify` route). The seam exists so a deployment that
  declares `:deep` has already named a real verifier when the invocation
  point arrives.
  """

  @typedoc """
  One documented `verify/2` option. See the moduledoc for each key's
  contract; implementations may accept more, but these four names are the
  shared vocabulary.
  """
  @type verify_opt ::
          {:body_bytes, binary()}
          | {:now, String.t()}
          | {:require_mode, String.t()}
          | {:keys, %{optional(String.t()) => term()}}

  @callback verify(envelope_json :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
end
