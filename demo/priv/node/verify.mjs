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

let response;
try {
  const { verifyEnvelope } = await import(`${dist}/src/verify.js`);
  const { isDidKey } = await import(`${dist}/src/didkey.js`);
  const { proofsOf } = await import(`${dist}/src/types.js`);
  const { RFC8032_TEST_3, ed25519KeyMaterial } = await import(`${dist}/testkit/vectors.js`);

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
  // A §11 code when the refusal is a protocol verdict, `null` when it is not:
  // `AphParseError` and `AphKeyUnavailableError` carry no code on purpose
  // (src/errors.ts explains both absences), and inventing one here would widen
  // a set the specification closed.
  response = {
    ok: false,
    errorName: error.name,
    code: error.code ?? null,
    message: error.message,
  };
}

writeFileSync(responsePath, JSON.stringify(response));
process.exitCode = response.ok ? 0 : 1;
