# Pre-production notification to the aph maintainers

- **Date sent:** 2026-08-27
- **From:** the jido_aph project (PRD-001 — APH-Notarized Signals for jido Agents)
- **To:** the maintainers of https://github.com/squillo/aph
- **aph state cited throughout:** commit `f01e3470f86533c4099db8ab0ab6b155bd0ea4aa`
- **Delivery channel:** this session's report to the repo owner, who is the aph
  maintainer. There is no separate email or issue; the report IS the delivery.
- **Acknowledgment:** **RECEIVED 2026-08-27 — see [§5. Outcome](#5-outcome).**
  Publication was authorized in draft status and question (d) was answered;
  (a), (b) and (c) were not.

> **Editor's note, 2026-08-27.** Sections 1–4 below are preserved as the
> notification was sent, in the present tense it was written in — including its
> statements that nothing had shipped and that the repository was private.
> Those were true when sent and are now superseded. §5 records what came back.
> This document is amended by appending, never by rewriting, because a
> governance record that edits its own history is not a record.

## 1. The notification

To the aph maintainers:

We are building `jido_aph`, an Elixir library and demo that guards
jido-framework agent signals with APH envelopes. It parses APH envelopes,
verifies them through the aph-ex NIF sidecar, and carries `attestationMode`
values and `APH_E*` error codes as data in its results and telemetry. The
envelope crosses every boundary in our system as JSON text; no cryptography is
performed in Elixir.

Your CONTRIBUTING.md keeps a pre-production exception in force "until the
first external adopter" and states:

> **This exception expires the moment someone outside this repository depends
> on the wire format**, after which the versioning rules below apply without
> exception.

The precise test, as refined by the first downstream report
([squillo/aph#1](https://github.com/squillo/aph/issues/1)):

> The exception expires when someone outside ships an artifact that **asserts
> wire facts**: code that mints, parses, or verifies an envelope; a schema or
> receipt carrying `aphVersion`, `attestationMode`, `bodySha256`, or an
> `APH_E*` code as data; or conformance vectors containing real envelope
> bytes.

`jido_aph` is exactly that artifact class: it parses and verifies envelopes
and carries `attestationMode` and `APH_E*` codes as data. CONTRIBUTING.md
asks consumers to "tell us **before** you ship anything that asserts wire
facts, not after" — this notification is that telling. Nothing has shipped;
the repository is private and stays private until you acknowledge (T17). The
notification goes out at build start deliberately, so your answers to the
questions below can still steer our design decisions D2 and D7 while changing
course is cheap.

## 2. The four questions

We ask for recorded rulings on:

- **(a)** whether BEAM-side `:crypto.hash` for §8.3 step 8 would ever be
  acceptable (this design avoids it regardless)
- **(b)** whether in-org shipping counts as outside-the-repo (notify
  regardless)
- **(c)** whether reading `../aph/examples` goldens from a downstream repo is
  the intended consumption pattern versus vendored copies (flips D7 — an
  early answer is why this card runs first)
- **(d)** sign-off on the `jido_aph` name (flips D2 while a rename is still
  cheap)

## 3. Erratum report: `examples/README.md`'s body-binding summary is stale

All facts below were recomputed on 2026-08-27 against the aph working tree at
commit `f01e3470f86533c4099db8ab0ab6b155bd0ea4aa`, not taken on faith from any
document.

**Recomputed facts:**

- `examples/principal_signed_body.txt` is git-tracked (`git ls-files` lists
  it), is exactly **427 bytes**, and its SHA-256 is
  `dae0b23f649c05222b955ff4752507c6d85a51e00566da4fea1867e50b3b60cb`.
- `examples/principal_signed_envelope.json` carries
  `credentialSubject.communication.bodySha256` =
  `dae0b23f649c05222b955ff4752507c6d85a51e00566da4fea1867e50b3b60cb` and
  `bodySize` = `427` — both equal to the recomputed values. The golden's body
  binding is byte-real: the authorized bytes are published in the repo and
  hash to the envelope's digest.
- A sweep of all twelve `examples/*.json` files finds the empty-string SHA-256
  (`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`) in
  **ten** files. **Two** carry real digests: `principal_signed_envelope.json`
  (`dae0b23f…`, digest of the tracked body file) and
  `ts_minted_envelope.json` (`1e3c1c7d…`, digest of its in-file preview).

**The stale claims, quoted from `examples/README.md` at `f01e3470`:**

Lines 37–39 (file inventory):

> - `ts_minted_envelope.json` — the same `PrincipalSigned` Ed25519 shape,
>   **minted by the TypeScript implementation** rather than by the Rust one, and
>   the only file here whose body binding is real (see below)

Lines 48–52 (what's the same across all files):

> - `communication.bodySha256`: a fixed 64-char lowercase hex in **eleven of the
>   twelve** files (the SHA-256 of an empty string, used as an anchor for
>   deterministic round-trip testing — DOES NOT represent a real message body).
>   `ts_minted_envelope.json` is the exception and carries a real digest of a
>   real body.

Lines 158–162 (the ts_minted section):

> - **Its body binding is REAL.** The complete body is short enough to travel in
>   `preview` verbatim, `bodySize` is that text's UTF-8 length and `bodySha256`
>   its digest. It is the only file here against which §8.3 step 8 can be checked
>   at all — the other eleven pair the empty-string hash with a non-zero
>   `bodySize` and publish no body to hash.

**The corrections:**

1. `ts_minted_envelope.json` is **not** the only file with a real body
   binding: `principal_signed_envelope.json`'s binding is equally real, with
   its body published as the tracked file
   `examples/principal_signed_body.txt`.
2. The empty-hash count is **ten of twelve, not eleven of twelve**.
3. "The other eleven … publish no body to hash" is wrong for
   `principal_signed_envelope.json`, which publishes its 427-byte body in the
   repo; §8.3 step 8 can be checked against it too.
4. Incidentally: the README's own `principal_signed_envelope.json` section
   (lines 96–120) never mentions the tracked body file, so nothing in the
   file's dedicated prose corrects the summary's claim.

We report this rather than patching it because the aph repo is read-only to
us; the fix is a documentation edit on your side, at your discretion.

## 4. Record

- Notification sent: **2026-08-27**, via this session's report to the repo
  owner (the aph maintainer).
- Questions asked: **(a)** BEAM-side `:crypto.hash` for §8.3 step 8;
  **(b)** in-org shipping vs. outside-the-repo; **(c)** `../aph/examples`
  goldens vs. vendored copies; **(d)** `jido_aph` name sign-off.
- Erratum reported: `examples/README.md` body-binding summary (three stale
  claims quoted above).
- Acknowledgment: **received 2026-08-27** — recorded in §5 below. (This line
  read "not yet received" when the notification was sent; §5 is the amendment.)

## 5. Outcome

Recorded 2026-08-27, the same day the notification was sent. The aph
maintainer, who also owns this repository, responded by authorizing
publication and answering one of the four questions.

- **Publication: AUTHORIZED**, public and in draft status, as
  `squillo/aph-jido`. This publication is what expires the pre-production
  exception for this artifact — that expiry is disclosed, not avoided, and
  disclosing it is why this notification exists.
- **(d) Name: ANSWERED — `aph-jido`.** The proposal was `jido_aph`; the ruling
  moved `aph` to the front, which addresses the "could be mistaken for an
  agentjido package" concern more directly than a `jido_` prefix. The Elixir
  application keeps `:jido_aph` and its modules keep `JidoAph.*`, so repository
  name and package name deliberately differ.
- **(a) BEAM-side `:crypto.hash` for §8.3 step 8: NOT ANSWERED.** Recorded as
  open. The design avoids the question in practice — no cryptography, hashing
  included, runs on the BEAM here — so nothing shipped depends on the answer.
- **(b) In-org shipping vs. outside-the-repo: NOT ANSWERED.** Recorded as open.
  We notified regardless, which was always the plan, so the answer changes
  nothing that has happened.
- **(c) Sibling-clone goldens vs. vendored copies: NOT ANSWERED.** Recorded as
  open, and this one still has teeth: it governs decision D7. An answer
  preferring vendored vectors would change how this repository consumes the
  corpus, and that rework is not filed as cards because no answer has come.

Three of four questions stand open. They are listed as unanswered rather than
inferred from the authorization, because reading silence as assent is the
species of overclaim this repository exists to argue against.
