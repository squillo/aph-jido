/**
 * The deep leg, in full: hand the envelope TEXT, the body BYTES and a pinned
 * `now` to the sibling `aph` clone's TypeScript verifier, and report what it
 * actually checked.
 *
 * WHY A SIDECAR AT ALL. `aph-ex` — the Elixir NIF this demo's guard runs on —
 * exposes four structural operations and no cryptography, deliberately and
 * parity-locked. Every signature in APH is checked by an implementation of the
 * spec, and this repository ships none: it borrows one. So the deep leg is a
 * process boundary, not a library call, and `JidoAph.DeepVerifier` is the
 * behaviour that names the seam.
 *
 * WHAT THIS SCRIPT DOES NOT DO. It never fetches. That is not this script's
 * restraint but the verifier's own boundary, stated at the top of
 * `interpreters/typescript/src/verify.ts`: "this verifier parses bytes it is
 * handed and NEVER fetches. §8.4 key discovery and §6.3.3's status fetch are
 * both network acts, so keys arrive as parameters and `now` arrives as a
 * parameter." Both parameters are supplied below from the request document —
 * the caller pins the instant, and the one un-decodable key is handed in.
 *
 * REQUEST / RESPONSE. argv[2] is a JSON request document
 * `{aphRepoPath, envelope, now, requireMode, bodyB64}`; argv[3] is where the
 * JSON response is written. Files rather than stdout because a crash inside
 * node must be distinguishable from a protocol refusal: a refusal writes a
 * response and exits 1, a crash writes no response at all, and stdout/stderr
 * stay free for diagnostics the Elixir side captures verbatim.
 *
 * A failure response carries a `kind`, and the three are never interchangeable:
 * `refusal` (the verifier reached a verdict about the envelope),
 * `loadFailure` (the built dist/ could not be loaded or does not export what
 * this script needs — an environment gap), and `unexpected` (something threw
 * that is not one of the verifier's own error classes — a tooling failure).
 * Only the first is ever a statement about the document.
 *
 * `envelope` is the envelope's JSON TEXT and is passed to `verifyEnvelope`
 * unparsed. An APH envelope's proof carriage is an untagged union decided by
 * the bytes (§7.1.11), and the §7.1.7.1 byte bound is a bound on bytes, so
 * re-serializing a parsed term onto the trust path would be checking a
 * different document than the one that arrived.
 */

import { readFileSync, writeFileSync } from 'node:fs';

/**
 * The golden's notary, and the one verification method in this demo that
 * cannot be resolved offline.
 *
 * `did:web:notary.squillo.com#key-1` is NOT a live service and is never
 * contacted: a `did:web` key is published at a `.well-known` document a
 * verifier would fetch (spec §8.4.4), and nothing here fetches anything. The
 * key therefore arrives as a parameter, and its bytes come from the aph
 * repository's own published test material — `interpreters/typescript/testkit/
 * vectors.js`, whose `RFC8032_TEST_3` is RFC 8032 §7.1 TEST 3, the seed
 * `examples/README.md` names as the notary throughout that corpus ("Every key
 * derives from a fixed public test seed — RFC 8032 §7.1 TEST 2 (the principal)
 * and TEST 3 (the notary)"). Imported rather than transcribed so no key byte
 * is ever spelled inside this repository.
 *
 * The golden's OTHER party — the human principal — is a `did:key`, which
 * carries its own public key bytes in the identifier (§8.4.3) and needs no
 * entry here. That asymmetry is the key-sourcing story the response reports.
 */
const NOTARY_VERIFICATION_METHOD = 'did:web:notary.squillo.com#key-1';

const [, , requestPath, responsePath] = process.argv;
const request = JSON.parse(readFileSync(requestPath, 'utf8'));
const dist = `${request.aphRepoPath}/interpreters/typescript/dist`;

/**
 * The verifier's own error classes (`src/errors.ts`). Only these three are
 * protocol verdicts; anything else that escapes `verifyEnvelope` is this
 * script's problem or the build's, and must not be reported as a refusal.
 */
const APH_ERROR_NAMES = new Set(['AphError', 'AphParseError', 'AphKeyUnavailableError']);

let response;
let verifyEnvelope;
let isDidKey;
let proofsOf;
let ed25519KeyMaterial;
let RFC8032_TEST_3;

/**
 * LOADING IS NOT VERIFYING, and the two must never produce the same document.
 *
 * These imports used to sit inside the try below, whose catch renders protocol
 * refusals — so a partial, stale or corrupt `dist/` came back as
 * `{kind: :refusal, code: null}`, which is byte-shape-identical to a genuine
 * no-code refusal (`AphParseError`, `AphKeyUnavailableError`). A caller could
 * not tell "the envelope was refused" from "the verifier never loaded", and
 * the Elixir side's availability check cannot close the gap on its own: it
 * spot-checks four entry files, and a file that exists can still export
 * nothing. So the load has its own try and its own response kind, and the
 * exports are checked rather than assumed.
 */
try {
  ({ verifyEnvelope } = await import(`${dist}/src/verify.js`));
  ({ isDidKey } = await import(`${dist}/src/didkey.js`));
  ({ proofsOf } = await import(`${dist}/src/types.js`));
  ({ RFC8032_TEST_3, ed25519KeyMaterial } = await import(`${dist}/testkit/vectors.js`));

  for (const [name, value] of [
    ['verifyEnvelope', verifyEnvelope],
    ['isDidKey', isDidKey],
    ['proofsOf', proofsOf],
    ['ed25519KeyMaterial', ed25519KeyMaterial],
  ]) {
    if (typeof value !== 'function') {
      throw new TypeError(`${dist} loaded but exports no \`${name}\` function`);
    }
  }

  if (RFC8032_TEST_3 === undefined) {
    throw new TypeError(`${dist}/testkit/vectors.js loaded but exports no RFC8032_TEST_3`);
  }
} catch (error) {
  response = { ok: false, kind: 'loadFailure', errorName: error.name, message: error.message };
}

if (response === undefined) {
  try {
    const keys = { [NOTARY_VERIFICATION_METHOD]: ed25519KeyMaterial(RFC8032_TEST_3) };
    const bodyBytes =
      request.bodyB64 === null || request.bodyB64 === undefined
        ? undefined
        : new Uint8Array(Buffer.from(request.bodyB64, 'base64'));

    const verified = await verifyEnvelope(request.envelope, {
      now: request.now,
      requireMode: request.requireMode ?? undefined,
      keys,
      bodyBytes,
    });

    // The key-sourcing story, DERIVED from the envelope that just verified
    // rather than asserted: every verification method the proofs name is either
    // self-describing (`did:key`) or was resolved from the supplied map, because
    // `resolveVerifyingKey` has no third source — an unsupplied non-`did:key`
    // method throws `AphKeyUnavailableError` and never reaches this line.
    const methods = proofsOf(verified.envelope).map((proof) => proof.verificationMethod);

    response = {
      ok: true,
      // Verbatim `VerifiedEnvelope` field names (src/verify.ts). The parsed
      // `envelope` member is deliberately NOT forwarded: the caller already
      // holds the text, and shipping back a re-serialization would hand it a
      // second, differently-spelled copy of a signed document.
      verified: {
        attestationMode: verified.attestationMode,
        bodyHashChecked: verified.bodyHashChecked,
        embeddedMandateChecked: verified.embeddedMandateChecked,
      },
      keySourcing: {
        supplied: Object.keys(keys),
        suppliedOutOfBand: methods.filter((method) => !isDidKey(method)),
        selfDescribing: methods.filter((method) => isDidKey(method)),
        fetched: [],
      },
      transport: {
        envelopeBytes: new TextEncoder().encode(request.envelope).length,
        bodyBytes: bodyBytes === undefined ? null : bodyBytes.length,
      },
      verifier: { runtime: process.version, dist },
    };
  } catch (error) {
    // Only the verifier's OWN error classes are verdicts about the envelope.
    // Anything else that escapes verifyEnvelope — a TypeError from a stale
    // dist, a RangeError, whatever — is a tooling failure wearing a refusal's
    // clothes, and gets its own kind so nobody has to guess.
    //
    // For a real verdict: a §11 code when there is one, `null` when there is
    // not. `AphParseError` and `AphKeyUnavailableError` carry no code on
    // purpose (src/errors.ts explains both absences), and inventing one here
    // would widen a set the specification closed.
    response = APH_ERROR_NAMES.has(error.name)
      ? {
          ok: false,
          kind: 'refusal',
          errorName: error.name,
          code: error.code ?? null,
          message: error.message,
        }
      : { ok: false, kind: 'unexpected', errorName: error.name, message: error.message };
  }
}

writeFileSync(responsePath, JSON.stringify(response));
process.exitCode = response.ok ? 0 : 1;
