# jido_aph

An [APH](https://github.com/squillo/aph) notarization gate for
[jido](https://hex.pm/packages/jido) agents: a `Jido.Plugin` that refuses to
let an agent act on a signal that carries no notarization envelope, plus a
demo that is scrupulous about what that refusal actually proves.

> **Community integration, not an agentjido package.** The `jido_` prefix
> names what this integrates with, not who publishes it. Nothing here is
> endorsed by, affiliated with, or maintained by the agentjido project or the
> aph maintainers. The name itself is out for sign-off (see
> [Governance](#governance) below), and the repository stays private until
> that comes back.

---

## Read this first

Everything in this repository follows from one paragraph in the aph Elixir
binding's own documentation, quoted here verbatim from
`../aph/interpreters/elixir/lib/aph.ex` — the `@doc` on
`APH.verify_proof_structure/1`, the strongest check this gate can run:

> A successful return says the structure is sound. It says NOTHING about
> whether any signature verifies — a caller that reports "the human signed
> this" on the strength of this function alone is reporting a claim no key has
> backed.

So `JidoAph.Guard` does not say it. Its fixed verdict wording is
**`notarization-shaped, mode policy satisfied`**, and the bare words
"verified" and "signed" never appear in anything the guard *writes*. Scoped to
its own words on purpose, because a refusal log line is not all the guard's:
aph-ex's messages pass through verbatim, and a strict-parse refusal quotes the
offending field name back, so an envelope carrying a top-level field named
`verified` logs ``unknown field `verified`, expected one of …``. That fragment
is the sender's word, not the gate's. Everything the guard authors is asserted
by test over real captured logs, in four places: the demo's happy path, its
refusal matrix, and both transcript tests. The assertions are word-boundary
matches, not substring bans, because the guard must be free to write
`PrincipalSigned` (closed spec vocabulary, §7.1.7) and `tagged unverified` —
both of which are the honest thing to say and both of which a substring ban
would forbid.

What the guard **does** claim, and all it claims:

1. the envelope parsed under APH's strict schema, unknown fields denied
   (spec §8.3 step 1);
2. its proof structure matches its declared label in both directions
   (§7.1.11) — which is what catches a forged `PrincipalSigned` label;
3. the configured attestation-mode policy is satisfied with no silent
   downgrade (§8.3.1 step 1a).

Zero cryptography runs on the BEAM. No signature is checked, no key is
resolved, no clock is read, no digest is recomputed. That is not a gap this
README glosses; it is the whole subject of the next section.

The demo's teaching climax exists because of exactly this: a structurally
perfect envelope carrying a **transplanted `proofValue`** passes every single
guard check and is admitted, and is then refused on signature verification by
an independent implementation. This is why structural validity is never
called verification.

---

## The verification-depth split

Reproduced from PRD-001 §7.3, and carried byte-identically in
`JidoAph.Guard`'s own moduledoc so the code and the README cannot drift apart.
The third column is stated, not implied.

| Check (spec ref) | Guard (BEAM, aph-ex) | Deep leg (TS sidecar, optional) | Nowhere in this repo |
|---|---|---|---|
| Envelope byte bound (§7.1.7.1) | YES — before parse | YES (maxEnvelopeBytes) | |
| Strict parse, unknown fields denied (§8.3 step 1) | YES | YES | |
| Attestation-mode policy (§8.3.1 step 1a, APH_E012) | YES | YES (requireMode) | |
| Proof structure, label-vs-structure both directions (§7.1.11, APH_E013) | YES | YES | |
| Signatures over JCS/RFC 8785 (§8.3) | no | YES — all four Ed25519 | |
| Issuance order (§7.2.1) | no | YES | |
| Embedded delegation-mandate binding (§8.3.1 step 1d) | no | YES | |
| Validity window (60s skew) | no | YES — against pinned `now`, stated | |
| bodySha256 over received bytes (§8.3 step 8, APH_E009) | no | YES | |
| Closed channel/contentClass vocabulary (§7.1.5/§7.1.6) | no (aph-ex exposes no such op) | YES (TS enforces) | |
| Key discovery: DNS TXT / did:web (§8.4) | no | no (TS never fetches; did:key decodes offline; the golden's one did:web notary key is supplied via `options.keys` and the transcript says so) | YES — named in README |
| Revocation / credentialStatus transport | no | no (golden carries none; TS refuses status-bearing envelopes) | YES — named in README |
| Live notary contact | no | no | YES — named in README |

The guard is depth 0–1 plus mode policy. The deep leg is full offline §8.3 in
a second, independent implementation, with exactly one key supplied out of
band and said so out loud. The right-hand column is the honest end of the
story: key discovery, revocation transport, and any contact with a live notary
happen **nowhere in this repository**, and no output anywhere implies
otherwise.

---

## Setup

Two sibling clones. The dependency is a path dep — aph-ex is not on hex.pm.

```sh
git clone https://github.com/squillo/aph.git
git clone <this repo> jido_aph      # sibling of aph, not inside it
cd jido_aph
mix deps.get
mix test
```

A Rust toolchain is **mandatory**, not optional: the aph-ex binding is a
rustler NIF that compiles from source, and no prebuilt `.so` ships. The first
compile builds the NIF and all of jido; expect several minutes.

### Recorded toolchain

These are the versions this repository was actually built and tested on — not
a compatibility range, and not the floor:

| | Version | Notes |
|---|---|---|
| Elixir | **1.20.3** | `mix.exs` declares `~> 1.18`, which is jido's own floor |
| Erlang/OTP | **29.0.5** | erts-17.0.5 |
| cargo | **1.96.0** | mandatory — builds the aph-ex NIF |
| Node | **v26.3.0** | optional, deep leg only; the TS package's floor is `>= 20` |

Resolved dependencies (`mix.lock`): **jido 2.3.3**, **jido_signal 2.2.2**
(`~> 2.2` — deliberately *not* `3.0.0-beta.1`, which jido 2.3.3 does not
accept), jido_action 2.3.2, rustler 0.30.0, zoi 0.18.7. The aph-ex rustler
pins are upstream-owned and untouched here.

### The demo

The demo is a separate mix app under `demo/`, with its own deps and its own
formatter config:

```sh
cd demo
mix deps.get
mix test          # Node-free; :deep-tagged tests are excluded by default
mix demo.run      # the structural leg — no Node, no network
```

The corpus is read from the sibling clone at runtime through the application
key `config :jido_aph, aph_repo_path:` (`"../aph"` at the library root,
`"../../aph"` from `demo/`). A missing clone raises loudly with the exact
`git clone` line rather than failing somewhere subtle.

### The optional deep leg

Starting from `demo/`, where the previous block left you:

```sh
cd ../../aph/interpreters/typescript && npm install && npm run build  # builds dist/
cd -                       # back to demo/ — both commands below need it
mix test --include deep    # or: APH_DEEP=1 mix test
mix demo.deep_verify
```

The `cd -` matters. Both mix commands live in the demo app: run them at the
repository root instead and `mix demo.deep_verify` reports that the task does
not exist, while `mix test --include deep` prints **`77 passed`** — the
library suite, which contains no `:deep`-tagged tests at all. A pass for work
that never ran is the one outcome this repository is built to refuse, so read
that number as the wrong-directory signal it is.

`npm install`, not `npm ci`: the sibling commits no lockfile and says why in
its own `interpreters/typescript/.gitignore` — "a lockfile would be a
durable-looking record of a dependency graph this package's whole claim is
that it does not have. CI installs with `npm install`." `npm ci` refuses to
run without one, so it fails on every fresh clone. The build writes only
untracked artifacts into the sibling; nothing else here ever writes to it.

`mix demo.deep_verify` degrades on purpose: with Node or the built `dist/`
missing it prints `DEEP LEG UNAVAILABLE — nothing was verified, and nothing is
claimed.`, the reason, the full setup instructions, and exits non-zero. It
never falls back to a shallower check and reports it as a verification.

---

## What the library gives you

Take these three modules; the demo is illustration, not a dependency.

**`JidoAph.Guard`** — `use Jido.Plugin, name: "aph_guard"`. All gating happens
in `prepare_signal/2`, which halts the chain **before routing**, so a refused
signal never reaches an Action. The gate order is fixed and every step is
mandatory:

1. `byte_size(envelope_json) <= 65_536` — **before any parse**, because
   canonicalization happens on unauthenticated input (§7.1.7.1) — then a
   UTF-8 well-formedness check on the now-bounded bytes, since the extension
   schema's `:string` is a binary type and the `aph-ex` ops raise on anything
   that is not text;
2. `APH.parse_envelope_json/1` — strict, unknown fields denied (§8.3 step 1);
3. `APH.require_attestation_mode/2` when `:require_mode` is configured
   (§8.3.1 step 1a, `APH_E012`);
4. `APH.verify_proof_structure/1` — **always**, even with no mode policy,
   because the mode gate alone admits a forged `PrincipalSigned` label
   (§7.1.11, `APH_E013`). A mandatory test proves that admission-then-catch.

Six config keys, Zoi-validated at agent compile time with unknown keys
**refused** rather than stripped (a silently-dropped `require_mode` would
disable the mode gate): `:required`, `:require_mode`, `:signal_patterns`,
`:refusal`, `:depth`, `:deep_verifier`.

```elixir
defmodule MyApp.Gateway do
  use Jido.Agent,
    name: "gateway",
    plugins: [
      {JidoAph.Guard,
       %{required: true, require_mode: "PrincipalSigned",
         signal_patterns: ["slack.reply.requested"]}}
    ],
    signal_routes: [{"slack.reply.requested", MyApp.Actions.DeliverReply}]
end
```

On admit, the guard contributes one runtime-context key that the routed Action
reads as `context.aph`:

```elixir
%{aph: %{verdict: "notarization-shaped, mode policy satisfied (PrincipalSigned)",
         structure_mode: "PrincipalSigned",
         require_mode: "PrincipalSigned",
         depth: :structural}}
```

With no mode policy configured the verdict is `"notarization-shaped"` alone —
the guard never names a policy nobody asked it to enforce. `:depth` reports
what the gate **ran**, never what the config declared.

Refusals return `{:error, reason}` with aph-ex's own message passed through
byte-untouched. Through a live agent they arrive at the
`Jido.AgentServer.call/2` caller wrapped as
`%Jido.Error.ExecutionError{message: "Plugin prepare_signal failed", details:
%{plugin: JidoAph.Guard, reason: reason}}` — **match on `details.reason`**, not
on the message, which is a fixed framework string.

**`JidoAph.Signal.Ext.Notarization`** — the registered `Jido.Signal.Ext` that
carries the envelope, with `JidoAph.attach_notarization/3` and
`JidoAph.read_notarization/1` as the consumer-facing helpers:

```elixir
{:ok, signal} =
  JidoAph.attach_notarization(signal, envelope_json, body_b64: Base.encode64(body))

case JidoAph.read_notarization(signal) do
  nil -> :no_notarization_on_this_signal
  %{envelope_json: json} = data ->
    # body_b64 is optional: reach for it with Map.get, never a required match
    {json, Map.get(data, :body_b64)}
end
```

The envelope crosses every boundary as **JSON text**. It is never decoded into
a map on the trust path, in either direction: aph-ex is JSON-in/JSON-out, the
untagged proof union is decided by the bytes, and two JSON texts that parse
equal can hash differently.

**`JidoAph.DeepVerifier`** — a behaviour and nothing else:
`verify(envelope_json, opts) :: {:ok, map} | {:error, term}`, with `:body_bytes`,
`:now`, `:require_mode`, and `:keys` as the documented options. There is no
in-library implementation and a test sweeps `lib/` to keep it that way. The two
known routes — a TypeScript sidecar (implemented in `demo/`) and a future Rust
sidecar over the published crates — both live outside this library, because the
aph binding surface is parity-locked at four ops across Elixir/wasm/Python and
nothing here grows, wraps, or forks it.

---

## The signal-carry pattern: two identifiers, one meaning

Folded in from [`docs/a2a-carry-mapping.md`](docs/a2a-carry-mapping.md), which
is derived from a **pinned byte-level test**
(`test/jido_aph/signal/ext/notarization_wire_shape_test.exs`) rather than from
framework documentation — jido_signal's serialized extension shape is
undocumented upstream, so it is pinned, not guessed.

| Rail | Identifier | Travels on the wire? |
| --- | --- | --- |
| A2A: `Message.metadata` key (extension URI) | `aph://extensions/notarization/v1` | **Yes** — it *is* the metadata key |
| jido: signal extension namespace | `aph.notarization.v1` | **No** — binds only via the receiver's extension registry |

The A2A URI is pinned in `spec/a2a-extension.md` §2: compared byte-for-byte,
opaque, never dereferenced. jido extension namespaces must match
`^[a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)*$`, which forbids `:` and `/` — so the URI
literally cannot be the namespace, and the two live as two single constants in
`JidoAph.Signal.Ext.Notarization` (`a2a_uri/0`, `namespace/0`). A self-grep test
proves the URI literal appears exactly once under `lib/` and is never assembled
from substrings.

Serializing a signal that carries the extension produces this frame, asserted
byte-for-byte by the pinned test (which pins both observed member orders — see
the first bullet below for why there are two):

```json
{"body_b64":"Qk9EWQ==","envelope_json":"{\"pin\":\"not an envelope\"}","id":"wire-shape-pin-0001","jido_schema_version":1,"source":"/scribe","specversion":"1.0.2","type":"slack.reply.requested"}
```

| Fact carried | jido signal rail (pinned by test) | A2A rail (spec + precedent) |
| --- | --- | --- |
| Which extension this is | Receiver-registry binding of namespace `aph.notarization.v1`; the identifier does not travel | `Message.metadata` key `aph://extensions/notarization/v1`; the identifier *is* the key (§2) |
| The envelope | Top-level `envelope_json` member — one escaped JSON string, envelope text verbatim | `metadata[uri].envelope` — envelope inline |
| Authorized body bytes | Top-level `body_b64` member — base64 of the received bytes, verbatim; absent key = no body traveled | `metadata[uri].bodyRef` points at a message part, and its own note requires verbatim transport in a real deployment |
| "You must present notarization" | Guard config `required: true` → reject and log the envelope-less signal | Recipient deployment policy REQUIRES APH and the AgentCard declares no APH extension → reject and log for audit (§5 step 5). `AgentExtension.required` (§3) is the *sender's* flag — whether the agent asks recipients to verify — and defaults to `false` in v0.1 |
| Envelope-less traffic under a permissive policy | Guard `required: false` → pass through tagged unverified | §5 permissive flow: "Not notarized" indicator, deliver under existing trust rules |
| Support discovery | Compile-time: the mounted plugin and registered extension *are* the declaration | Runtime: scan `agent_card.extensions[]` for the URI — no AgentCard exists on the jido rail |

Three consequences worth carrying away, all pinned by that test:

- **The carry frame is not byte-canonical.** Extension members flatten to top
  level with no `extensions` wrapper, and their order relative to the core
  members is stable within a VM but not across VMs. Never hash, sign, or
  byte-compare the frame. APH binds the envelope text and the body bytes; the
  frame binds nothing.
- **An unregistered receiver loses the notarization silently.** jido_signal
  registers extensions from an `@after_compile` hook that a warm `_build` never
  fires; on a VM without the namespace registered, wire-schema validation
  *strips* `envelope_json`/`body_b64` with no error. For a `required: true`
  guard that fails closed; for a naive consumer it is silent loss. Call
  `JidoAph.Signal.Ext.Notarization.ensure_registered/0` before deserializing —
  the attach/read helpers already do.
- **`jido_schema_version` rides back as an opaque extension.** A bridge must
  construct A2A metadata from `read_notarization/1` and key it by `a2a_uri()`,
  never blind-forward the extensions map.

### The A2A rail disclaimer

**jido signals are the rail here, not A2A HTTP.** Nothing in this repository
serves or fetches an AgentCard, speaks JSON-RPC `message/send`, or opens a
network connection of any kind. What the extension mirrors is the *carry
pattern* and the `AgentExtension required: true` / `required: false` semantics
— the mapping above is a semantic correspondence, not a structural one (A2A
nests both facts in one object under the URI key; the jido frame flattens two
ungrouped members). And carrying asserts nothing on either rail: presence of
the extension is transport, never verification.

---

## Key sourcing: one key handed in, one that needs none, zero fetched

The golden envelope's two proofs are anchored two different ways, and the
difference is the entire §8.4 story — the one this repository does not
implement.

The human principal is a `did:key`: the identifier **is** the public key,
base58-encoded behind a multicodec prefix, so it decodes offline and needs
nothing supplied. Its bytes travel inside the envelope itself.

The notary is a `did:web`. A `did:web` key is published at a document a
verifier would **fetch** (§8.4.4), and this repository fetches nothing — so
that one key arrives as a parameter to the deep leg, under the verification
method `did:web:notary.squillo.com#key-1`. **That is a fixture identifier.** It
was not resolved, not fetched, and not contacted — here or anywhere else in
this repository — and nothing presents it as live or resolvable. Its key bytes
are neither invented nor transcribed into this repository: `demo/priv/node/verify.mjs`
imports `RFC8032_TEST_3` from the aph clone's own testkit, the published
RFC 8032 §7.1 TEST 3 vector that upstream `examples/README.md` names as the
notary's seed throughout that corpus. Anyone can re-derive it; nobody has to
trust this repository for it. The sidecar accepts no caller-supplied `:keys` at
all — it refuses the option — so its one trust anchor stays the reviewed one.

The live notary surface, `did:web:aph-notary.squillo.com`, is named in this
repository for exactly one purpose: to say that it **was not contacted**, by
anything, at any point. Domain canon throughout is squillo.com; the retired
domain appears nowhere, and [`scripts/hygiene_check.sh`](scripts/hygiene_check.sh)
fails the build if it ever does.

---

## Provenance

Every claim in this repository is attributable to specific bytes in the sibling
clone. These digests were **recomputed from the fixture files**, not read out of
upstream prose — upstream's `examples/README.md` body-binding summary is
currently stale, and this repository reports that as an erratum (see
[Governance](#governance)) rather than repeating it.

| Fact | Value |
|---|---|
| aph pin | `f01e3470f86533c4099db8ab0ab6b155bd0ea4aa` |
| `examples/principal_signed_envelope.json` | 3382 bytes, sha256 `8a6015d873786b533fa00f16b3f789a7984be61d631d5cd9e3515f7c5e721466` |
| `examples/principal_signed_body.txt` | **427 bytes**, sha256 `dae0b23f649c05222b955ff4752507c6d85a51e00566da4fea1867e50b3b60cb` |
| envelope's `credentialSubject.communication.bodySha256` | `dae0b23f649c05222b955ff4752507c6d85a51e00566da4fea1867e50b3b60cb` — equal to the recomputed digest of the tracked body file |
| envelope's `bodySize` | `427` — equal to the bytes on disk |
| envelope validity window | `2026-05-21T00:00:00Z` .. `2026-05-22T00:00:00Z` (past; the deep leg's pinned `now` is `2026-05-21T12:00:00Z`, and says so) |
| `examples/slack_reply_envelope.json` | sha256 `b8ffb64d42682db4406cc0c25d4c15f52c23eaff7da456aad5d82c6fb71a3640` — the mode-absent fixture, refusal row 3 |

The golden's body binding is **byte-real**: the authorized bytes are published
in the aph repo as a tracked file and they hash to the envelope's own digest.
That is what makes the demo's `body_b64` carry real rather than notional — the
authorized bytes travel verbatim and the deep leg hashes the bytes it received,
never a re-serialization.

The pin is a pin on purpose. Upstream fixture regeneration or a
verification-surface change should break this repository **loudly**, and bumping
the pin is a deliberate reviewed change (CI's drift gate, PRD-001 T15). The demo
transcripts *read* the SHA from whatever clone they actually ran against and say
so, rather than asserting a pin they do not enforce.

---

## Governance

This repository is exactly the artifact class that expires the aph repo's
pre-production spec exception: it parses and verifies envelopes and carries
`attestationMode` and `APH_E*` codes as data. aph's `CONTRIBUTING.md` asks
consumers to tell the maintainers **before** shipping anything that asserts
wire facts, not after.

- **Notification sent:** 2026-08-27, recorded in full at
  [`docs/governance/2026-08-27-preproduction-notification.md`](docs/governance/2026-08-27-preproduction-notification.md).
- **Four rulings requested:** (a) whether BEAM-side `:crypto.hash` for §8.3
  step 8 would ever be acceptable (this design avoids it regardless);
  (b) whether in-org shipping counts as outside-the-repo (we notify
  regardless); (c) whether reading `../aph/examples` goldens from a downstream
  repo is the intended consumption pattern versus vendored copies; (d) sign-off
  on the `jido_aph` name, while a rename is still cheap.
- **Erratum reported:** upstream `examples/README.md` calls
  `ts_minted_envelope.json` the only file with a real body binding and counts
  the empty-string hash in eleven of twelve files. Recomputed against
  `f01e3470`: the count is **ten of twelve**, and
  `principal_signed_envelope.json`'s binding is equally real — its 427-byte body
  is tracked in the repo and hashes to the envelope's `bodySha256`. Reported
  rather than patched, because the aph repo is read-only to this project.
- **Acknowledgment: PENDING.** No response is recorded yet.

**Publish is blocked on that acknowledgment.** The repository stays private
until it is recorded here (PRD-001 T17), and the cross-repo pointer PR (T18)
waits behind it. If a ruling flips a decision — the name (D2) or the corpus
consumption pattern (D7) — the rework is filed as cards before publish, not
after.

---

## Repo hygiene

[`scripts/hygiene_check.sh`](scripts/hygiene_check.sh) enforces two naming
invariants over every git-tracked file. The `core` job in
[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs it unchanged, with
no arguments:

1. **The retired domain appears nowhere.** No allowlist, no exceptions. The
   script assembles the forbidden string at runtime so its own source never
   contains it and it cannot pass itself by accident.
2. **`did:web:notary.squillo.com` appears only where it is quoted and
   explained** — the deep transcript, `verify.mjs`'s keys map, the sidecar and
   its narration, the tests pinning the key-sourcing story, the PRD, and the
   key-sourcing section above. The allowlist is an explicit path list with a
   reason recorded per entry; anywhere else is a failure. The library proper
   (`lib/`) is not on that list and does not mention the identifier at all.

```sh
scripts/hygiene_check.sh              # check this repo
scripts/hygiene_check.sh --self-test  # prove the checks actually fail on planted violations
```

The self-test builds a throwaway git repo, plants one violation of each rule
plus one allowlisted occurrence that must pass, and asserts the checker's
verdict on each. A hygiene gate that has never been observed to fail is not
evidence of anything.

---

## Repo map

```
lib/jido_aph.ex                              attach/read helpers
lib/jido_aph/signal/ext/notarization.ex      the two single-constant identifiers
lib/jido_aph/guard.ex                        the four-step structural gate
lib/jido_aph/deep_verifier.ex                behaviour only — the seam
test/jido_pins/                              jido 2.3.3 contracts, pinned by test
test/support/corpus.ex                       runtime :aph_repo_path resolution
docs/a2a-carry-mapping.md                    the mapping, derived from the pinned wire test
docs/governance/                             the pre-production notification
docs/transcripts/                            both committed transcripts
scripts/hygiene_check.sh                     the naming gate, self-testable
.github/workflows/ci.yml                     the two-job gate; only `core` is required
demo/                                        two agents, two mix tasks, the TS sidecar
PRDs/PRD-001-Jido-APH-Guard.md               the design record this repo implements
```

Every test in this repository opens with a comment saying why it exists and
what it pins. Tampered envelopes are derived in memory at runtime and never
committed; the signed fixtures upstream are never text-edited.

---

## Appendix A — `mix demo.run`, verbatim

The real stdout of the structural leg, committed at
[`docs/transcripts/demo_run.txt`](docs/transcripts/demo_run.txt) and regenerable
with `mix demo.run --out ../docs/transcripts/demo_run.txt` from `demo/`. It
needs no Node and reaches no network. A golden-output test
(`demo/test/demo_run_transcript_test.exs`) asserts the provenance banner, the
verdict wording, `APH_E012`, `APH_E013`, and the honesty footer against real
stdout; the `core` CI job greps the same strings out of a live run
(`.github/workflows/ci.yml`). The task is also a gate, not only a story: if
the run departs from what the transcript narrates — a leg refusing at a
different step than it declared, say — it prints a `DEVIATIONS` block and
exits non-zero rather than publishing a tidy fiction.

The transcript is assembled rather than console-captured, and says so: the
narrative is written by the task process while the guard logs from jido's
signal-call task, so nothing orders the two streams. A custom `:logger` handler
collects the demo's own events and each leg renders its own, inline.

<details>
<summary><strong>Full transcript (426 lines)</strong></summary>

```text
==============================================================================
jido_aph — mix demo.run

An APH-notarized signal crossing two jido agents, and a gate that refuses to
act without one. Read the honesty footer at the bottom before quoting
anything from the middle.
==============================================================================


[1] PROVENANCE — the exact bytes every claim below rests on
------------------------------------------------------------------------------
Nothing here is vendored. The fixtures are read at runtime from a sibling
clone of the aph repo (PRD-001 D7), so the SHA below is what attributes
every claim in this transcript to bytes a reader can fetch for themselves.

  corpus source         sibling aph clone, resolved at runtime from
                        config :jido_aph, aph_repo_path: "../../aph"
  aph HEAD              f01e3470f86533c4099db8ab0ab6b155bd0ea4aa
  aph worktree          clean at HEAD
  aph examples/         clean

  That SHA is READ from the clone, not asserted against a pin. Pinning it,
  and failing the build on fixture drift, is CI's job (PRD-001 T15); the
  demo's job is to say which bytes it actually ran on.

  golden envelope       examples/principal_signed_envelope.json
    bytes               3382
    id                  urn:uuid:00000000-0000-4000-8000-0000000000f3
    aphVersion          0.1
    channel.kind        slack  (closed vocabulary, §7.1.5)
    contentClass        Reply  (closed vocabulary, §7.1.6)
    attestationMode     PrincipalSigned  (§7.1.7)
    proof               2-element chain
    validFrom           2026-05-21T00:00:00Z
    validUntil          2026-05-22T00:00:00Z

  authorized body       examples/principal_signed_body.txt
    bytes on disk       427
    envelope claims     bodySize 427
    envelope claims     bodySha256
      dae0b23f649c05222b955ff4752507c6d85a51e00566da4fea1867e50b3b60cb

  Read those last two lines exactly as written: they are the ENVELOPE's own
  words, quoted. bodySize is compared against the bytes on disk and agrees.
  bodySha256 is NOT recomputed — not here, and not in any leg below. No
  cryptography runs on the BEAM in this demo, and PRD-001 §5 counts hashing
  as cryptography.

  mode-absent fixture   examples/slack_reply_envelope.json
    bytes               2148
    policy              carries NO attestationMode key

  An absent attestationMode normatively means NotaryAttested (§7.1.7), so a
  PrincipalSigned policy must refuse it rather than quietly accept whatever
  the envelope happens to offer. Leg [6] is that refusal; leg [5] forges a
  PrincipalSigned label onto this same fixture.


[2] THE GATE — what JidoAph.Guard runs, in this order, before routing
------------------------------------------------------------------------------
S1  §7.1.7.1        envelope byte bound (65536 B),
                    enforced BEFORE any parse
S2  §8.3 step 1     APH.parse_envelope_json/1 — strict parse, with
                    unknown fields denied
S3  §8.3.1 step 1a  APH.require_attestation_mode/2 — only when a mode
                    policy is configured (APH_E012)
S4  §7.1.11         APH.verify_proof_structure/1 — ALWAYS, even with
                    no mode policy, because S3 alone admits a forged
                    label (APH_E013)

And the six things no leg below runs, at any depth, ever:

N1  Ed25519 signatures over JCS/RFC 8785 (§8.3)
N2  key discovery — DNS TXT / did:web (§8.4)
N3  validity window (60s skew)
N4  revocation / credentialStatus
N5  bodySha256 over the received bytes (§8.3 step 8, APH_E009)
N6  closed channel / contentClass vocabulary (§7.1.5 / §7.1.6)

Each leg names, from what actually happened, which of S1-S4 RAN, which one
REFUSED, and which were NEVER REACHED. N1-N6 are constant: they are what
this whole rail does not do.

Lines marked `log [level]` are verbatim Logger output from JidoAph.Guard
and Demo.Actions.DeliverReply, routed into this narrative so they appear
inside the leg that produced them. jido's AgentServer emits its own [error]
line for a refused prepare_signal hook after it has already replied to the
caller; that line is real, and it is not reproduced here.


[3] LEG 1 — HAPPY PATH: the golden envelope crosses two agents
------------------------------------------------------------------------------
Scribe reads examples/principal_signed_envelope.json — 3382 bytes of
verbatim JSON text — and examples/principal_signed_body.txt, the 427
authorized body bytes. It attaches both to a "slack.reply.requested" signal
with JidoAph.attach_notarization/3 — envelope as text, body as base64 — and
hands the signal to Gateway with Jido.AgentServer.call/2.

Gateway mounts JidoAph.Guard as required: true, require_mode:
"PrincipalSigned", signal_patterns: ["slack.reply.requested"].

The envelope is a PRE-MINTED committed golden. Presenting it asserts nothing
about this run: nothing here was minted, and no human authorized anything.

  log [info] aph_guard: notarization-shaped, mode policy satisfied
                (PrincipalSigned) — admitting signal "slack.reply.requested"
  log [info] deliver_reply: would deliver (no channel adapter)

  outcome               ADMITTED — call/2 returned {:ok, %Jido.Agent{}}
  routed action         Demo.Actions.DeliverReply RAN
  context.aph, as the routed action received it:
      verdict
          "notarization-shaped, mode policy satisfied (PrincipalSigned)"
      structure_mode  "PrincipalSigned"
      require_mode    "PrincipalSigned"
      depth           :structural

  `structure_mode` is the mode the proof STRUCTURE supports; `require_mode`
  is the policy that was configured. They agree here, and the guard reports
  them separately on purpose — a verdict that conflated them would be
  claiming the envelope PROVED the policy rather than merely matching it.
  `depth: :structural` states what this gate RAN, never what a config
  declared.

  cross-check           APH.verify_proof_structure/1 on the same bytes
                        returns this identical result, byte for byte:
                        the guard passed it through untouched, and the
                        framework's error wrapping did not alter it

  gate steps, this leg:
      S1  §7.1.7.1        RAN
      S2  §8.3 step 1     RAN
      S3  §8.3.1 step 1a  RAN
      S4  §7.1.11         RAN
  never run, this or any leg:
      N1 signatures     N2 key discovery   N3 validity window
      N4 revocation     N5 bodySha256      N6 closed vocabulary


[4] LEG 2 — REFUSAL 1/6: no notarization extension, required: true
------------------------------------------------------------------------------
A "slack.reply.requested" signal with no notarization extension at all —
the ordinary case of an agent that simply does not speak APH.

This is the a2a-extension.md §5 step 5 mirror: where the extension is absent
and the recipient's deployment policy REQUIRES APH, "the endpoint REJECTS
messages from the agent and SHOULD log the rejection for audit" — both
halves, the rejection and the log line, are visible in this block.

  log [warning] aph_guard: refusing signal "slack.reply.requested":
                notarization extension missing: signal "slack.reply.requested"
                carries no APH envelope and this guard requires one (required:
                true, a2a-extension.md §5)

  outcome               REFUSED before routing
  routed action         Demo.Actions.DeliverReply did NOT run
  reason, verbatim, as Jido.AgentServer.call/2 handed it back:
      notarization extension missing: signal "slack.reply.requested" carries
      no APH envelope and this guard requires one (required: true,
      a2a-extension.md §5)

  No envelope existed, so no gate step ran and no APH_E code is claimed:
  the taxonomy codes belong to protocol rules, and a document that was
  never presented reached none of them.

  gate steps, this leg:
      S1  §7.1.7.1        NOT REACHED
      S2  §8.3 step 1     NOT REACHED
      S3  §8.3.1 step 1a  NOT REACHED
      S4  §7.1.11         NOT REACHED
  never run, this or any leg:
      N1 signatures     N2 key discovery   N3 validity window
      N4 revocation     N5 bodySha256      N6 closed vocabulary


[5] LEG 3 — REFUSAL 2/6: a forged PrincipalSigned label (APH_E013)
------------------------------------------------------------------------------
Derived in memory, on this run: examples/slack_reply_envelope.json with a
"PrincipalSigned" attestationMode written over its policy. Its proof is a
single object, which cannot carry that label — §7.1.11 requires the label
and the structure to agree in BOTH directions.

This is the forgery a mode gate ALONE waves through: on these exact bytes
APH.require_attestation_mode/2 answers :ok, because the label does say what
the policy asked for. Only S4 catches the lie, which is why the guard runs
S4 unconditionally.

Nothing derived here is ever written to disk; the committed fixtures are
never edited (PRD-001 §10 gate 4).

  log [warning] aph_guard: refusing signal "slack.reply.requested": APH_E013:
                proof chain invalid: `attestationMode` is `PrincipalSigned`
                but `proof` is a single object; the label MUST accompany a
                two-element chain (§7.1.11)

  outcome               REFUSED before routing
  routed action         Demo.Actions.DeliverReply did NOT run
  reason, verbatim, as Jido.AgentServer.call/2 handed it back:
      APH_E013: proof chain invalid: `attestationMode` is `PrincipalSigned`
      but `proof` is a single object; the label MUST accompany a two-element
      chain (§7.1.11)

  S3 on these bytes     :ok   <- admitted the forgery
  S4 on these bytes     refused, above

  cross-check           APH.verify_proof_structure/1 on the same bytes
                        returns this identical result, byte for byte:
                        the guard passed it through untouched, and the
                        framework's error wrapping did not alter it

  gate steps, this leg:
      S1  §7.1.7.1        RAN
      S2  §8.3 step 1     RAN
      S3  §8.3.1 step 1a  RAN
      S4  §7.1.11         REFUSED  <- the leg stops here
  never run, this or any leg:
      N1 signatures     N2 key discovery   N3 validity window
      N4 revocation     N5 bodySha256      N6 closed vocabulary


[6] LEG 4 — REFUSAL 3/6: mode-absent vs a PrincipalSigned policy (APH_E012)
------------------------------------------------------------------------------
examples/slack_reply_envelope.json, untampered. Its policy carries no
attestationMode key at all, and an absent mode normatively means
NotaryAttested (§7.1.7) — weaker than the configured PrincipalSigned
policy, so §8.3.1 step 1a refuses it up front instead of silently
downgrading to whatever the envelope offers.

Its structure is sound, so the refusal is the mode policy and nothing else.

  log [warning] aph_guard: refusing signal "slack.reply.requested": APH_E012:
                attestation mode refused: required `PrincipalSigned`, envelope
                is `NotaryAttested`

  outcome               REFUSED before routing
  routed action         Demo.Actions.DeliverReply did NOT run
  reason, verbatim, as Jido.AgentServer.call/2 handed it back:
      APH_E012: attestation mode refused: required `PrincipalSigned`, envelope
      is `NotaryAttested`

  S4 on these bytes     {:ok, "NotaryAttested"}   <- the structure is sound
  policy.decision       "AskEveryTime"

  That decision field records the human's STANDING CONFIGURATION — the
  policy mode they chose for this channel — and is never the verdict on this
  act. §7.1.7 is explicit that it "Records the human's standing
  configuration, NOT the verdict on this act", the verdict being carried by
  the state the envelope was issued from, so an AskEveryTime envelope
  truthfully carries AskEveryTime after the human said yes.
  "Implementations that read this field as a per-act decision have shipped
  real defects; do not." Nothing in this repo reads it as one: the guard
  never looks at decision, and this refusal is about attestationMode alone.

  cross-check           APH.require_attestation_mode/2 on the same bytes
                        returns this identical result, byte for byte:
                        the guard passed it through untouched, and the
                        framework's error wrapping did not alter it

  gate steps, this leg:
      S1  §7.1.7.1        RAN
      S2  §8.3 step 1     RAN
      S3  §8.3.1 step 1a  REFUSED  <- the leg stops here
      S4  §7.1.11         NOT REACHED
  never run, this or any leg:
      N1 signatures     N2 key discovery   N3 validity window
      N4 revocation     N5 bodySha256      N6 closed vocabulary


[7] LEG 5 — REFUSAL 4/6: an unknown envelope field (strict parse, no code)
------------------------------------------------------------------------------
Derived in memory, on this run: the golden with one extra top-level field,
"jidoAphUnknownField". §8.3 step 1 parses STRICTLY, with unknown fields
denied, so a key the protocol never defined is a hard refusal rather than a
silently dropped one.

The refusal carries the parser's own message and no APH_E code — a document
that never parsed reached no protocol rule and may cite none.

  log [warning] aph_guard: refusing signal "slack.reply.requested": unknown
                field `jidoAphUnknownField`, expected one of `aphVersion`,
                `@context`, `type`, `id`, `issuer`, `validFrom`, `validUntil`,
                `credentialSubject`, `linkedMandate`, `credentialStatus`,
                `proof` at line 1 column 1770

  outcome               REFUSED before routing
  routed action         Demo.Actions.DeliverReply did NOT run
  reason, verbatim, as Jido.AgentServer.call/2 handed it back:
      unknown field `jidoAphUnknownField`, expected one of `aphVersion`,
      `@context`, `type`, `id`, `issuer`, `validFrom`, `validUntil`,
      `credentialSubject`, `linkedMandate`, `credentialStatus`, `proof` at
      line 1 column 1770

  cross-check           APH.parse_envelope_json/1 on the same bytes
                        returns this identical result, byte for byte:
                        the guard passed it through untouched, and the
                        framework's error wrapping did not alter it

  gate steps, this leg:
      S1  §7.1.7.1        RAN
      S2  §8.3 step 1     REFUSED  <- the leg stops here
      S3  §8.3.1 step 1a  NOT REACHED
      S4  §7.1.11         NOT REACHED
  never run, this or any leg:
      N1 signatures     N2 key discovery   N3 validity window
      N4 revocation     N5 bodySha256      N6 closed vocabulary


[8] LEG 6 — REFUSAL 5/6: over the byte bound, refused before any parse
------------------------------------------------------------------------------
Derived in memory, on this run: the golden followed by 70,000 spaces —
73382 bytes against the 65536-byte bound of §7.1.7.1.

The bound exists because canonicalization happens on UNAUTHENTICATED input,
so it has to be enforced before a parser ever sees the bytes. That ordering
is provable from outside the guard: trailing whitespace is legal JSON, so
the strict parser ADMITS these very bytes.

  log [warning] aph_guard: refusing signal "slack.reply.requested": envelope
                exceeds the 65536-byte bound (73382 bytes); refused before any
                parse (spec §7.1.7.1)

  outcome               REFUSED before routing
  routed action         Demo.Actions.DeliverReply did NOT run
  reason, verbatim, as Jido.AgentServer.call/2 handed it back:
      envelope exceeds the 65536-byte bound (73382 bytes); refused before any
      parse (spec §7.1.7.1)

  S2 on these bytes     {:ok, <canonical JSON text>}
                        ^ the parser would take them, so the refusal
                          above can only be the byte bound

  gate steps, this leg:
      S1  §7.1.7.1        REFUSED  <- the leg stops here
      S2  §8.3 step 1     NOT REACHED
      S3  §8.3.1 step 1a  NOT REACHED
      S4  §7.1.11         NOT REACHED
  never run, this or any leg:
      N1 signatures     N2 key discovery   N3 validity window
      N4 revocation     N5 bodySha256      N6 closed vocabulary


[9] LEG 7 — ROW 6/6: a bare signal under required: false, delivered tagged
------------------------------------------------------------------------------
The same bare signal as leg [4], sent to a gateway identical to Gateway in
every respect but one: required: false.

This is the other half of the a2a-extension.md §5 mirror — step 6, the
permissive deployment that "MAY display a 'Not notarized' UI indicator and
proceed to deliver the message under the recipient's existing trust rules".
Delivery happens; it happens FLAGGED.

  log [warning] aph_guard: signal "slack.reply.requested" carries no
                notarization envelope; passing through tagged unverified
                (required: false)
  log [info] deliver_reply: would deliver (no channel adapter)

  outcome               PASSED THROUGH, TAGGED — nothing was examined
  routed action         Demo.Actions.DeliverReply RAN
  context.aph           %{notarization: :absent, tag: :unverified}

  Note what is not there: no verdict, no "notarization-shaped", no mode.
  Nothing was examined, so nothing is claimed. The tag rides the RUNTIME
  CONTEXT the receiving guard authored, never the signal — a wire-borne
  tag would be sender-suppliable, and is silently stripped on any VM
  where the extension namespace is unregistered.

  gate steps, this leg:
      S1  §7.1.7.1        NOT REACHED
      S2  §8.3 step 1     NOT REACHED
      S3  §8.3.1 step 1a  NOT REACHED
      S4  §7.1.11         NOT REACHED
  never run, this or any leg:
      N1 signatures     N2 key discovery   N3 validity window
      N4 revocation     N5 bodySha256      N6 closed vocabulary


[10] HONESTY FOOTER — what this run did not establish
------------------------------------------------------------------------------
Seven signals were gated. One was admitted, five were refused, one was
passed through and tagged. The admission means exactly three things: the
envelope PARSED strictly, its declared attestation mode satisfied the
configured policy without downgrade, and its proof STRUCTURE matched that
label in both directions.

Here is what it does not mean — about any envelope above, the admitted one
included:

  N1  No Ed25519 signature was checked. Not the principal's, not the
      notary's, not the two on the embedded delegation mandate. Zero
      cryptography ran on the BEAM (§8.3).
  N2  No key was discovered or resolved: no DNS TXT lookup, no did:web
      fetch, no did:key decode. Nothing on this rail resolves anything
      (§8.4).
  N3  The validity window was never compared against any clock. The golden
      declares 2026-05-21T00:00:00Z .. 2026-05-22T00:00:00Z and no leg
      above read it.
  N4  Revocation was never consulted. The golden carries no
      credentialStatus, and no status transport exists in this repo.
  N5  bodySha256 was never recomputed over the 427 received bytes. The
      digest quoted in the banner
      (dae0b23f649c05222b955ff4752507c6d85a51e00566da4fea1867e50b3b60cb)
      is the envelope's own claim (§8.3 step 8, APH_E009).
  N6  The closed channel and contentClass vocabularies were never enforced.
      aph-ex exposes no such op (§7.1.5 / §7.1.6).

  The live notary at did:web:aph-notary.squillo.com was not contacted, by
  anything, at any point. Nothing above reached the network at all.

aph-ex says it plainly of the one structural op this gate leans on hardest
(../aph/interpreters/elixir/lib/aph.ex, verify_proof_structure/1):

    "A successful return says the structure is sound. It says NOTHING
     about whether any signature verifies — a caller that reports "the
     human signed this" on the strength of this function alone is
     reporting a claim no key has backed."

That is the whole reason the verdict reads "notarization-shaped, mode
policy satisfied" and never a word stronger, and the reason the guard's own
log lines above are checked by test for those two bare words.

Cryptographic depth is a different leg, in a second and independent
implementation, and it is not this one:

    mix demo.deep_verify        (optional, Node >= 20)

==============================================================================
```

</details>

---

## Appendix B — `mix demo.deep_verify`, verbatim

The real stdout of the optional deep leg, committed at
[`docs/transcripts/demo_deep_verify.txt`](docs/transcripts/demo_deep_verify.txt)
and regenerable with `mix demo.deep_verify --out ../docs/transcripts/demo_deep_verify.txt`
from `demo/`. It requires Node and the built TS `dist/`; it still reaches no
network. A `:deep`-tagged golden-output test
(`demo/test/demo_deep_verify_transcript_test.exs`) asserts the pinned-`now`
statement, the wall-clock refusal, the depth-split line, and the key-sourcing
line against real stdout; the optional `deep` CI job greps the same strings
(`.github/workflows/ci.yml`).

Two notes on reading it. The bare words "verified" and "signed" appear freely
here and that is correct — this leg *earned* them, having checked four Ed25519
signatures; the bare-word rule binds the guard's own log lines, which are
extracted and checked separately inside this very transcript. And the wall-clock
refusal is `APH_E003 (MandateExpired)`, a validity-window refusal that arrives
*after* every signature has already verified — it is proof the pin is
load-bearing, not proof of a signature problem.

<details>
<summary><strong>Full transcript (407 lines)</strong></summary>

```text
==============================================================================
jido_aph — mix demo.deep_verify

The optional second leg. The same golden envelope `mix demo.run` gated
STRUCTURALLY is handed here to an independent implementation of the same
specification — the aph repo's TypeScript verifier, running under node — which
checks every signature. Read [7] and [8] before quoting anything from the
middle: this leg adds a great deal, and there are still three things it does
not do.
==============================================================================


[1] PROVENANCE — the bytes, and the verifier that ruled on them
------------------------------------------------------------------------------
Nothing here is vendored: neither the fixtures nor the verifier. Both are
read at runtime from a sibling clone of the aph repo (PRD-001 D5/D7), so the
SHA below is what attributes every verdict in this transcript to bytes a
reader can fetch and re-run for themselves.

  corpus + verifier     one sibling aph clone, resolved at runtime
  aph HEAD              f01e3470f86533c4099db8ab0ab6b155bd0ea4aa
  aph worktree          clean at HEAD
  aph typescript/       source clean at HEAD

  That last line is about SOURCE, and it is worth saying what it does not
  cover: `dist/` is a build artifact, git-ignored upstream, so nothing here
  can prove the built JavaScript was compiled from the source at that SHA.
  Rebuilding it is one command, named in this task's own failure message,
  and CI's :deep job builds it fresh at the pinned SHA (PRD-001 T16).

  verifier              interpreters/typescript, under node
    entry point         demo/priv/node/verify.mjs
    calls               dist/src/verify.js  verifyEnvelope (§8.3 + §8.3.1)
    dist                interpreters/typescript/dist  (inside the clone above)
    node runtime        v26.3.0

  The verifier runs in a SUBPROCESS, not on the BEAM. Zero cryptography runs
  on the BEAM anywhere in this repository (PRD-001 §5), and aph-ex — the NIF
  the guard is built on — exposes four structural operations and no signature
  check at all, on purpose and parity-locked.

  golden envelope       examples/principal_signed_envelope.json
    bytes               3382
    id                  urn:uuid:00000000-0000-4000-8000-0000000000f3
    aphVersion          0.1
    channel.kind        slack  (closed vocabulary, §7.1.5)
    contentClass        Reply  (closed vocabulary, §7.1.6)
    attestationMode     PrincipalSigned  (§7.1.7)
    proof               2-element chain
    mandate             embedded §6.1 mandate, allowedChannels ["slack"]
    credentialStatus    absent — §6.3.3.4 case 1, SKIP (not a pass)

  authorized body       examples/principal_signed_body.txt
    bytes on disk       427
    envelope claims     bodySize 427
    envelope claims     bodySha256
      dae0b23f649c05222b955ff4752507c6d85a51e00566da4fea1867e50b3b60cb

  `mix demo.run` quotes that digest and says plainly that it never recomputes
  it. This leg does recompute it — inside node, over the body bytes as the
  sidecar received them, never over a re-serialization of a parsed object
  (§8.3 step 8). Leg [3] reports whether that check actually ran.


[2] THE PIN — the instant every verdict below rests on
------------------------------------------------------------------------------
The borrowed verifier takes `now` as a PARAMETER and reads no clock. Its own
source says why, at the top of src/verify.ts: "this verifier parses bytes it
is handed and NEVER fetches", and separately, of `now`: "Required — this
module reads no clock", because "a library that read its own clock could not
be tested deterministically".

So the caller pins the instant. This task pins it out loud:

  pinned now            2026-05-21T12:00:00Z
  envelope validFrom    2026-05-21T00:00:00Z
  envelope validUntil   2026-05-22T00:00:00Z
  inside the window     yes — compared on this run, not asserted
  clock skew            60 s, the §8.3 RECOMMENDED default
                        (DEFAULT_CLOCK_SKEW_SECONDS, src/types.ts)

`now` is pinned because the window is fixed, not because time is negotiable.

  The instant is not invented either: it is the aph repo's own
  GOLDEN_EVALUATION_INSTANT (interpreters/typescript/testkit/golden.ts), so
  this demo and its upstream evaluate the same fixture at the same moment.

  A verifier that quietly read the wall clock would do two dishonest things
  at once: it would pass today and fail tomorrow for reasons no reader could
  see, and it would hide which instant a verdict rested on. Leg [5] runs the
  same envelope against the real clock and is refused — which is what makes
  this pin load-bearing rather than decorative.


[3] LEG 1 — THE GOLDEN, VERIFIED AT THE PINNED INSTANT
------------------------------------------------------------------------------
The whole golden envelope — 3382 bytes of JSON TEXT, unparsed, exactly as
it sits in the clone — plus the 427 authorized body bytes, plus the pinned
instant, plus one key. Handed across a process boundary to verifyEnvelope and
asked for the full §8.3 / §8.3.1 procedure.

  require_mode          "PrincipalSigned"
  now                   2026-05-21T12:00:00Z
  body bytes supplied   yes, 427 — so §8.3 step 8 can run

  outcome               VERIFIED — verifyEnvelope returned a VerifiedEnvelope

  what it reports, in its own field names (src/verify.ts):
      attestationMode         "PrincipalSigned"
      bodyHashChecked         true
      embeddedMandateChecked  true

  Those last two are reports of what RAN, not of what is possible.
  `bodyHashChecked: true` means §8.3 step 8 hashed the delivered bytes and
  they matched the envelope's bodySha256. `embeddedMandateChecked: true`
  means the §6.1 mandate embedded in this envelope's policy was checked —
  its bindings to this human and this agent, its allowedChannels, its window
  around the envelope's own, and BOTH of its signatures.

    transport           envelope 3382 B, body 427 B
                        measured by the verifier on the far side of the
                        process boundary, and equal to what was handed in

  Four Ed25519 signatures were checked in total: the principal's and the
  notary's over the envelope, and the mandate's principalSignature and
  notarySignature over their own §6.1 bases. `mix demo.run` checked none.

  verifier steps, this leg:
      D1   §7.1.7.1         RAN
      D2   §8.3 step 1      RAN
      D3   §8.3.1 step 1a   RAN
      D4   §7.1.11          RAN
      D5   §8.3 step 1b-1c  RAN
      D6   §7.2.1 step 1e   RAN
      D7   §8.3 steps 2-5   RAN
      D8   §8.3.1 step 1d   RAN
      D9   §8.3 step 6      RAN
      D10  §8.3 step 8      RAN
      D11  §8.3 step 8a     RAN — credentialStatus absent, so SKIP


[4] KEY SOURCING — where each verifying key came from
------------------------------------------------------------------------------
The golden's two proofs are anchored two different ways, and the difference is
the entire §8.4 story — the one this repository does not implement.

One key handed in out of band, one that needs none, and zero fetched.

  self-describing       1  (did:key — §8.4.3)
      did:key:z6MkiaMbhXHNA4eJVCCj8dbzKzTgYDKf6crKgHVHid1F1WCT#z6MkiaMbhXHNA4eJVCCj8dbzKzTgYDKf6crKgHVHid1F1WCT

  supplied out of band  1  (§8.4.4 would fetch; nothing here does)
      did:web:notary.squillo.com#key-1

  fetched               0

  The human principal is a `did:key`: the identifier IS the public key,
  base58-encoded behind a multicodec prefix, so it decodes offline and needs
  nothing handed in. Its bytes travelled inside the envelope, on the signal,
  through the guard, into node.

  The notary is a `did:web`. A `did:web` key is published at a .well-known
  document a verifier would FETCH (§8.4.4), and this leg fetches nothing — so
  its key arrives as a parameter. Those bytes are neither invented nor
  transcribed into this repository: demo/priv/node/verify.mjs imports
  RFC8032_TEST_3 from the aph clone's own testkit — the published RFC 8032
  §7.1 TEST 3 vector that examples/README.md names as the notary's seed
  throughout that corpus. Anyone can re-derive it; nobody has to trust this
  repository for it.

  did:web:notary.squillo.com#key-1 is a FIXTURE IDENTIFIER.
  It was not resolved, not fetched and not contacted, here or anywhere else
  in this repository. A verdict above rests on a key a human handed the
  verifier, and saying so is the whole purpose of this section.

  The two lists together are the entire proof chain, because there is no
  third source: resolveVerifyingKey (src/verify.ts) decodes a did:key or
  reads the supplied map, and throws AphKeyUnavailableError for anything
  else — so a method resolved by some other route could not have reached
  this report.


[5] LEG 2 — THE WALL-CLOCK BEAT: the same envelope, right now
------------------------------------------------------------------------------
The same bytes, the same key, the same everything — with `now` read from this
machine's clock instead of pinned.

  now                   2026-08-27T19:58:25.990272Z   <- varies every run
  envelope window       2026-05-21T00:00:00Z .. 2026-05-22T00:00:00Z

  outcome               REFUSED on the validity window
  code                  APH_E003
  the verifier's own words, verbatim:
      APH_E003 (MandateExpired): evaluated at 2026-08-27T19:58:25.990272Z,
      outside the envelope window 2026-05-21T00:00:00Z .. 2026-05-22T00:00:00Z

  Read that as the good news it is. The golden's window closed on
  2026-05-22, so a fixture minted in May cannot be presented as authority
  in August. §8.3 step 6 is exactly the rule that says so, with 60 seconds
  of skew tolerance and not a day more.

  It is also the proof that leg [3]'s pin is doing work. If `now` were
  ignored, or defaulted, or quietly widened, this call would have returned
  the same VerifiedEnvelope as leg [3]. It did not. The pin is stated in
  section [2] rather than hidden precisely so this refusal can be shown
  next to it instead of explained away.

  Note what this refusal is NOT: it is not a signature problem. §8.3 step 6
  runs at D9, after every signature in the document has already verified —
  the enumeration below says so.

  verifier steps, this leg:
      D1   §7.1.7.1         RAN
      D2   §8.3 step 1      RAN
      D3   §8.3.1 step 1a   RAN
      D4   §7.1.11          RAN
      D5   §8.3 step 1b-1c  RAN
      D6   §7.2.1 step 1e   RAN
      D7   §8.3 steps 2-5   RAN
      D8   §8.3.1 step 1d   RAN
      D9   §8.3 step 6      REFUSED  <- the leg stops here
      D10  §8.3 step 8      NOT REACHED
      D11  §8.3 step 8a     NOT REACHED


[6] LEG 3 — THE DEPTH-SPLIT BEAT: one envelope, two verdicts
------------------------------------------------------------------------------
Derived in memory, on this run, and written nowhere: the golden with the
principal's proofValue replaced by the NOTARY's own. That is not a corrupted
field — it is a genuine 64-byte Ed25519 signature in the same multibase
base58btc spelling, over the wrong bytes. Nothing about the document's SHAPE
is wrong: two-element proof chain, both DataIntegrityProof/eddsa-jcs-2022,
both verificationMethods untouched, the PrincipalSigned label still matching
the carriage §7.1.11 requires for it.

The only thing wrong with it is that the human never signed it.

Committed fixtures are never text-edited and derived negatives are never
committed (PRD-001 §10 gate 4).

HALF ONE — every check JidoAph.Guard runs, run on these exact bytes:

    S1 §7.1.7.1         2736 B under the 65536 B bound: PASSES
    S2 §8.3 step 1      strict parse: PASSES
    S3 §8.3.1 step 1a   mode gate: :ok
    S4 §7.1.11          proof structure: {:ok, "PrincipalSigned"}

...and the composite, through the agent stack the demo actually ships. The
real Demo.Agents.Gateway, mounting JidoAph.Guard with required: true and
require_mode: "PrincipalSigned", was started and handed the forgery on a
"slack.reply.requested" signal:

  log [info] aph_guard: notarization-shaped, mode policy satisfied
                (PrincipalSigned) — admitting signal "slack.reply.requested"
  log [info] deliver_reply: would deliver (no channel adapter)

    call/2 returned     {:ok, %Jido.Agent{}} — ADMITTED
    routed action       Demo.Actions.DeliverReply RAN
    context.aph.verdict
        "notarization-shaped, mode policy satisfied (PrincipalSigned)"

  The message would have gone out.

HALF TWO — the same bytes, this leg:

  outcome               REFUSED
  code                  APH_E011
  the verifier's own words, verbatim:
      APH_E011 (PrincipalSignatureInvalid): the principal proof did not verify
      over its §7.2.1 base (the envelope with the notary proof discarded,
      `proof` kept as a ONE-ELEMENT ARRAY, and the principal's own proofValue
      emptied)

  control               still verifies (attestationMode "PrincipalSigned")
                        the untampered golden, same call, same instant, run
                        after the forgery — so the refusal above is the
                        forgery's doing and not the harness's

  One envelope. The structural gate admitted it and the action ran; the
  signature check refused it. Both are correct, and the guard was never
  wrong, because the guard never claimed this: its verdict says
  "notarization-shaped, mode policy satisfied" and stops there, and aph-ex
  says of the very operation it leans on hardest that a successful return
  "says NOTHING about whether any signature verifies".

This is why structural validity is never called verification.

  It is also why a deployment running only the guard is not thereby broken:
  it is a deployment that has chosen depth 0-1, and the honest thing is to
  say which depth ran, in the log line, every time.

  verifier steps, this leg:
      D1   §7.1.7.1         RAN
      D2   §8.3 step 1      RAN
      D3   §8.3.1 step 1a   RAN
      D4   §7.1.11          RAN
      D5   §8.3 step 1b-1c  REFUSED  <- the leg stops here
      D6   §7.2.1 step 1e   NOT REACHED
      D7   §8.3 steps 2-5   NOT REACHED
      D8   §8.3.1 step 1d   NOT REACHED
      D9   §8.3 step 6      NOT REACHED
      D10  §8.3 step 8      NOT REACHED
      D11  §8.3 step 8a     NOT REACHED


[7] WHAT THIS LEG ADDS over the structural gate
------------------------------------------------------------------------------
The eleven steps below are what verifyEnvelope really runs, in the order
src/verify.ts runs them. D1-D4 are the same four JidoAph.Guard runs — the
value there is not novelty but INDEPENDENCE: a second implementation, in a
second language, reaching the same structural verdict. D5-D11 are the ones
the guard cannot reach at all, because no cryptography runs on the BEAM.

  D1   §7.1.7.1        envelope byte bound, before any parse
  D2   §8.3 step 1     strict parse, unknown fields denied — and, unlike the
                       guard's S2, the CLOSED channel and contentClass
                       vocabularies of §7.1.5 / §7.1.6 enforced here
  D3   §8.3.1 step 1a  attestation-mode policy (APH_E012)
  D4   §7.1.11         label versus proof structure, both directions
                       (APH_E013)
  ------------------   everything below this line is new -----------------
  D5   §8.3 step 1b-1c the PRINCIPAL's Ed25519 signature over its §7.2.1
                       base — the envelope with the notary proof discarded,
                       `proof` kept as a ONE-ELEMENT ARRAY, and the
                       principal's own proofValue emptied (APH_E011)
  D6   §7.2.1 step 1e  issuance order: the notary's decisionTimestamp, then
                       the principal's proof, then the notary's — each
                       signature covering only bytes that existed when it
                       was made (APH_E013)
  D7   §8.3 steps 2-5  the NOTARY's Ed25519 signature over its own §7.2.1
                       base (APH_E001)
  D8   §8.3.1 step 1d  the embedded §6.1 delegation mandate: bound to this
                       human and this agent, its allowedChannels covering
                       this channel, its window enclosing the envelope's,
                       and its OWN two signatures — principalSignature
                       (APH_E011) and notarySignature (APH_E006)
  D9   §8.3 step 6     the validity window against the pinned `now`, 60 s
                       skew (APH_E003)
  D10  §8.3 step 8     bodySha256 recomputed over the body bytes AS
                       RECEIVED — never over a re-serialization of a parsed
                       object, because two JSON texts that parse equal can
                       hash differently (APH_E009)
  D11  §8.3 step 8a    credentialStatus. Absent here, so §6.3.3.4 case 1:
                       SKIP. Present would be case 2 — REFUSED, APH_E008 —
                       because a verifier with no status transport must not
                       let an attacker who can break the status check
                       thereby choose that it is skipped

All canonicalization is JCS / RFC 8785. Four Ed25519 signatures in total,
and every one of them sits in `mix demo.run`'s not-checked column.


[8] WHAT IT STILL DOES NOT DO
------------------------------------------------------------------------------
Three things, and none of them is an oversight. Each is a network act, and
this whole rail is offline by construction.

  X1  NETWORK KEY DISCOVERY (§8.4). The borrowed verifier never fetches;
      that is the first sentence of its own source. Nothing resolved a
      did:web document, queried a DNS TXT record, or opened a socket. This
      is exactly why the notary's key had to be handed in as a parameter —
      section [4] names it, counts it and says where its bytes came from,
      rather than letting a verdict quietly rest on an anchor nobody
      declared.

  X2  REVOCATION (§6.3.3). No status was consulted, because no status
      transport exists in this repository at all. The golden carries no
      credentialStatus member, so D11 skipped — correctly, and by the
      specification's own trichotomy. An envelope that DID carry one would
      be refused APH_E008 here, never waved through.

  X3  THE LIVE NOTARY. did:web:notary.squillo.com#key-1 is a
      fixture identifier and was never contacted. The live surface
      did:web:aph-notary.squillo.com was not contacted either, by anything,
      at any point.

And one more, which is not about depth at all: nothing here was MINTED. The
envelope is a pre-minted committed golden — 3382 bytes that were sitting
in the clone before this task started — so running it asserts nothing
whatsoever about whether a human authorized anything today. What it asserts
is that the signatures on a document from May 2026 are the signatures that
document claims, evaluated at an instant this transcript prints in full.


[9] HONESTY FOOTER — what to say, and what not to, about this run
------------------------------------------------------------------------------
Say this: the golden envelope independently passes full offline §8.3 in a
second implementation of the specification — all four Ed25519 signatures
over their RFC 8785 canonical bases, issuance order, the embedded mandate's
bindings and both of its signatures, the validity window against a PINNED
instant that this transcript prints, and bodySha256 recomputed over the body
bytes as received — with exactly one key supplied out of band, named in
section [4].

Do not say this: that any key was discovered, that any revocation status was
checked, that any notary was contacted, or that anything was minted.

And do not read leg [6] backwards. The structural gate admitted a forgery and
was not thereby wrong: it answered the question it was asked, in the words it
was allowed to use. The failure mode this repository is built to avoid is not
a shallow check — it is a shallow check DESCRIBED as a deep one.

The structural leg, which needs no Node and reaches no network:

    mix demo.run

==============================================================================
```

</details>

---

## Status

Pre-publish and private, blocked on the governance acknowledgment above.

`.github/workflows/ci.yml` is committed and carries both jobs — `core gate (no
Node)` and `deep leg (optional, Node >= 20)` — but **GitHub Actions has never
executed it**: this repository has no remote yet, so every gate described above
is a gate that exists, verified by local replay of the workflow's own steps, not
a gate that has been observed green on Actions. When the remote lands, require
the `core` check and nothing else; `deep` declares no `needs:` and nothing
declares `needs: deep`, so it can be red, skipped, or deleted without touching
the Node-free pipeline.

**No license has been chosen yet** — there is no `LICENSE` file in this repository,
so no license is granted; that is a deliberate blank to be filled before
publish, not an oversight to read around.

See PRD-001 for scope, decisions, and the tasks that built this. The non-goals
there are load-bearing, not throat-clearing: no new aph-ex ops, no cryptography
in Elixir, no real A2A HTTP, no Slack delivery, no key discovery, no revocation,
no live notary, no minting, no hex.pm publish.
