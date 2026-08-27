defmodule Demo.DeepVerifierTest do
  # Why this file exists: it is PRD-001 T12 — the deep leg, and the beat that
  # justifies the whole honesty contract. `JidoAph.Guard` is a STRUCTURAL gate:
  # it answers "notarization-shaped, mode policy satisfied" and nothing about
  # whether a single signature verifies. This file pins the other half of that
  # sentence by running a real verifier over the same bytes and showing, on a
  # runtime-derived forgery, that the guard admits what the verifier refuses.
  #
  # What each group pins:
  #
  #   * seam conformance (untagged, Node-free) — `Demo.DeepVerifier.TsSidecar`
  #     really satisfies the `JidoAph.DeepVerifier` behaviour the guard's
  #     `depth: :deep` config validation demands (T8), and its two caller-error
  #     guards fire before any subprocess is spawned;
  #   * `:deep`-tagged — the borrowed TypeScript verifier's real result field
  #     names and values on the golden, the key-sourcing story, the body-hash
  #     refusal, and the depth-split beat.
  #
  # Toolchain: the `:deep` tests need Node >= 20 and a built `dist/` in the
  # sibling clone's TypeScript interpreter. They are excluded by default
  # (test/test_helper.exs) so the core suite stays Node-free per PRD-001 §10
  # gate 7; run them with `mix test --include deep` or `APH_DEEP=1 mix test`.
  #
  # Fixture discipline (PRD-001 §10 gate 4): the forged envelope below is
  # derived IN MEMORY from the sibling clone's committed golden at runtime and
  # is never written anywhere. Signed fixtures are never text-edited. The
  # envelope reaches both the guard and the sidecar as JSON TEXT; the decode
  # here exists only to build the variant.
  #
  # async: false — the depth-split test drives the singleton `Demo.Jido`
  # instance and captures VM-wide logs.
  use ExUnit.Case, async: false

  alias Demo.DeepVerifier.TsSidecar
  alias Jido.AgentServer
  alias Jido.Signal

  @moduletag capture_log: true

  # The instant the golden is evaluated against, pinned rather than read from
  # the clock. The golden's window is validFrom 2026-05-21T00:00:00Z ..
  # validUntil 2026-05-22T00:00:00Z, and this is the aph testkit's own chosen
  # instant inside it (interpreters/typescript/testkit/golden.ts,
  # GOLDEN_EVALUATION_INSTANT) — reused so the two repos evaluate the same
  # fixture at the same moment. A verifier that read the wall clock would pass
  # today and fail in 2027; T13 states this pin out loud in its transcript.
  @pinned_now "2026-05-21T12:00:00Z"

  # The golden's notary. NOT a live service and never contacted: a did:web key
  # is published at a .well-known document a verifier would fetch (§8.4.4), and
  # this leg fetches nothing. Its bytes reach the verifier as a handed-in
  # parameter, imported from the aph repo's published RFC 8032 §7.1 TEST 3
  # vector (demo/priv/node/verify.mjs spells the derivation).
  @golden_notary "did:web:notary.squillo.com#key-1"

  # The body the golden binds: 427 bytes, git-tracked upstream, whose sha256 is
  # the envelope's own bodySha256. Pinned as a literal because PRD-001 §10 gate
  # 4 makes bodySize 427 part of the corpus pin.
  @golden_body_size 427

  defp golden, do: Demo.Corpus.example!("principal_signed_envelope.json")
  defp golden_body, do: Demo.Corpus.example!("principal_signed_body.txt")

  # A structurally PERFECT forgery: the principal's proofValue replaced by the
  # notary's own, which is a genuine 64-byte Ed25519 signature in the same
  # multibase base58btc spelling — so nothing about the document's SHAPE is
  # wrong. Two-element proof chain, both DataIntegrityProof/eddsa-jcs-2022,
  # both verificationMethods untouched, both `created` timestamps in order, the
  # PrincipalSigned label still matching the carriage §7.1.11 requires for it.
  # The only thing wrong with it is that the human never signed it — which is
  # precisely the class of defect a structural gate cannot see.
  defp forged_principal_signature do
    envelope = JSON.decode!(golden())
    [principal, notary] = envelope["proof"]

    envelope
    |> Map.put("proof", [Map.put(principal, "proofValue", notary["proofValue"]), notary])
    |> JSON.encode!()
  end

  # ---------------------------------------------------------------
  # Seam conformance — no Node required, so these run in the core suite
  # ---------------------------------------------------------------

  # Why: T8 built the `:deep` config seam and deliberately shipped no
  # implementation of it; T12 ships the first one. This is the test that the
  # two halves actually meet — that a Gateway configured `depth: :deep,
  # deep_verifier: Demo.DeepVerifier.TsSidecar` passes the guard's own Zoi
  # refinement, which checks the module is loaded, declares the behaviour, and
  # exports verify/2. Without this, "implements the behaviour" would be a
  # claim in a moduledoc.
  test "the sidecar satisfies the guard's depth: :deep verifier seam" do
    # resolve_config/2 probes the plugin with function_exported?/3 WITHOUT
    # loading it, so an unloaded module's config passes through unvalidated on
    # a lazily-loading VM (the trap pinned in the library's
    # test/jido_pins/plugin_config_schema_test.exs). Load first, always.
    {:module, JidoAph.Guard} = Code.ensure_loaded(JidoAph.Guard)
    {:module, TsSidecar} = Code.ensure_loaded(TsSidecar)

    assert %{depth: :deep, deep_verifier: TsSidecar} =
             Jido.Plugin.Config.resolve_config!(JidoAph.Guard, %{
               required: true,
               require_mode: "PrincipalSigned",
               depth: :deep,
               deep_verifier: TsSidecar
             })

    behaviours =
      TsSidecar.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    assert JidoAph.DeepVerifier in behaviours
    assert function_exported?(TsSidecar, :verify, 2)
  end

  # Why: `:now` is the parameter that keeps this leg testable, and the borrowed
  # verifier requires it ("Required — this module reads no clock",
  # interpreters/typescript/src/verify.ts VerifyOptions). A sidecar that
  # defaulted it to `DateTime.utc_now/0` would make the golden verify today and
  # fail in 2027, and would hide the pin the honesty transcript has to state.
  # Pinned as a raise, before any subprocess: a missing clock pin is a caller
  # bug, not a verdict about an envelope.
  test "verify/2 refuses to invent a clock" do
    assert_raise ArgumentError, ~r/requires :now/, fn ->
      TsSidecar.verify(golden(), require_mode: "PrincipalSigned")
    end
  end

  # Why: the behaviour documents a `:keys` option, and this implementation
  # deliberately does not honour it — it supplies exactly one key and no more
  # (§10 gate 8: the did:web identifier is quoted and explained, never
  # presented as live). Accepting caller key material would quietly turn a demo
  # into a general-purpose verifier whose trust anchors nobody reviewed. Pinned
  # so the narrowing stays deliberate rather than becoming an oversight someone
  # "fixes".
  test "verify/2 refuses caller-supplied :keys" do
    assert_raise ArgumentError, ~r/does not accept caller-supplied :keys/, fn ->
      TsSidecar.verify(golden(), now: @pinned_now, keys: %{@golden_notary => "anything"})
    end
  end

  # ---------------------------------------------------------------
  # The deep leg itself
  # ---------------------------------------------------------------

  # Why: when the deep tests are asked for and the toolchain is not there, the
  # honest outcome is a red test with instructions — not a green run that
  # checked nothing. This is the gate the rest of the file stands on, and its
  # failure message is the setup story (PRD-001 §10 gate 7).
  @tag :deep
  test "the deep leg is available" do
    assert :ok == TsSidecar.availability(),
           """
           the :deep suite was included but the deep leg is unavailable:

           #{case TsSidecar.availability() do
             {:error, %{message: message}} -> message
             other -> inspect(other)
           end}
           """
  end

  # Why: this is T12's headline DONE condition and the ADDS half of the depth
  # story. `bodyHashChecked` and `embeddedMandateChecked` are the borrowed
  # verifier's OWN field names (src/verify.ts, VerifiedEnvelope) and they are
  # reports of what RAN, not of what is possible — so asserting them true is
  # asserting that §8.3 step 8 hashed the delivered body and that §8.3.1 step
  # 1d checked the embedded mandate's bindings and both its signatures. Every
  # one of those is in the guard's not-checked column.
  @tag :deep
  test "the golden verifies, with the body hash and the embedded mandate actually checked" do
    envelope = golden()
    body = golden_body()

    assert {:ok, result} =
             TsSidecar.verify(envelope,
               now: @pinned_now,
               require_mode: "PrincipalSigned",
               body_bytes: body
             )

    assert result.verified == %{
             attestationMode: "PrincipalSigned",
             bodyHashChecked: true,
             embeddedMandateChecked: true
           }

    assert result.evaluated_at == @pinned_now
    assert result.require_mode == "PrincipalSigned"

    # Transport integrity without hashing anything on this side: the sidecar
    # reports the byte length of the envelope text it actually received, and it
    # must equal the bytes handed in. The envelope crosses as JSON TEXT and is
    # verified unparsed, so a boundary that mangled it would change this count.
    assert result.transport.envelope_bytes == byte_size(envelope)
    assert result.transport.body_bytes == @golden_body_size
    assert byte_size(body) == @golden_body_size
  end

  # Why: `bodyHashChecked` must report what ran. A verifier handed no body
  # cannot have hashed one, and a flag that read `true` regardless would be the
  # exact unearned claim §8 forbids — the same disease as calling structural
  # validity "verified". This is the negative that makes the positive above
  # mean something.
  @tag :deep
  test "bodyHashChecked is false when no body was supplied" do
    assert {:ok, result} =
             TsSidecar.verify(golden(), now: @pinned_now, require_mode: "PrincipalSigned")

    assert result.verified.bodyHashChecked == false
    assert result.verified.embeddedMandateChecked == true
    assert result.transport.body_bytes == nil
  end

  # Why: T12's key-sourcing DONE condition, and the paragraph the README owes
  # its readers. The golden's two proofs are anchored two different ways, and
  # the difference is the whole §8.4 story: the human principal is a `did:key`,
  # which carries its own public key bytes in the identifier (§8.4.3) and needs
  # nothing handed in; the notary is a `did:web`, whose key lives at a
  # .well-known document (§8.4.4) that this leg never fetches — so exactly one
  # key is supplied out of band and zero are fetched. Asserted as exact lists
  # so a second supplied key, or any fetch, fails here.
  @tag :deep
  test "exactly one key is supplied out of band, zero are fetched, the did:key needs none" do
    assert {:ok, result} =
             TsSidecar.verify(golden(),
               now: @pinned_now,
               require_mode: "PrincipalSigned",
               body_bytes: golden_body()
             )

    assert result.key_sourcing.supplied == [@golden_notary]
    assert result.key_sourcing.supplied_out_of_band == [@golden_notary]
    assert result.key_sourcing.fetched == []

    assert [principal_method] = result.key_sourcing.self_describing
    assert String.starts_with?(principal_method, "did:key:z")

    # The two lists together are exactly the envelope's proof chain: nothing
    # was resolved by a third route, because the verifier has none.
    assert length(result.key_sourcing.self_describing) +
             length(result.key_sourcing.supplied_out_of_band) == 2
  end

  # Why: PRD-001 §3.3 and T12 — the body binding is the point of carrying
  # `body_b64` at all. §8.3 step 8 hashes the bytes the transport DELIVERED,
  # never a re-serialization of a parsed object, so a delivered body that does
  # not hash to the envelope's `bodySha256` is a refusal (APH_E009,
  # EnvelopeBodyHashMismatch). The guard cannot reach this: it never hashes
  # anything.
  @tag :deep
  test "a tampered body is refused APH_E009, naming both digests" do
    tampered = golden_body() <> " "

    assert {:error, refusal} =
             TsSidecar.verify(golden(),
               now: @pinned_now,
               require_mode: "PrincipalSigned",
               body_bytes: tampered
             )

    assert refusal.kind == :refusal
    assert refusal.error == "AphError"
    assert refusal.code == "APH_E009"
    assert refusal.message =~ "EnvelopeBodyHashMismatch"

    # The envelope's own binding appears in the message as the digest that was
    # EXPECTED, so the refusal names what it compared against.
    assert refusal.message =~
             "dae0b23f649c05222b955ff4752507c6d85a51e00566da4fea1867e50b3b60cb"
  end

  # Why: a broken build must never be reportable as a verdict. The four
  # dynamic imports in verify.mjs used to sit inside the try whose catch
  # renders protocol refusals, so a stale or partial dist/ came back as
  # `%{kind: :refusal, code: nil}` — byte-shape-identical to a genuine
  # AphParseError or AphKeyUnavailableError refusal, both of which reserve
  # `code: nil` on purpose. A caller could not tell "the envelope was refused"
  # from "the verifier never loaded", and `availability/1` cannot close the
  # gap alone: it spot-checks four entry files, and a file that exists can
  # still export nothing. This builds exactly that dist — every file present,
  # `verifyEnvelope` absent — and pins that availability still says :ok while
  # verify/2 degrades to :unavailable/:dist_broken WITH build instructions.
  #
  # :deep-tagged because it spawns node, not because it needs a real build.
  @tag :deep
  test "a dist that loads but exports nothing is an environment gap, never a refusal" do
    repo =
      Path.join(System.tmp_dir!(), "jido_aph_broken_dist_#{System.unique_integer([:positive])}")

    dist = Path.join([repo, "interpreters", "typescript", "dist"])
    on_exit(fn -> File.rm_rf(repo) end)

    File.mkdir_p!(Path.join(dist, "src"))
    File.mkdir_p!(Path.join(dist, "testkit"))

    # Present, importable, and useless: the exact shape availability/1 cannot
    # see through.
    File.write!(Path.join([dist, "src", "verify.js"]), "export const nope = 1;\n")
    File.write!(Path.join([dist, "src", "didkey.js"]), "export const isDidKey = () => false;\n")
    File.write!(Path.join([dist, "src", "types.js"]), "export const proofsOf = () => [];\n")

    File.write!(
      Path.join([dist, "testkit", "vectors.js"]),
      "export const RFC8032_TEST_3 = {};\nexport const ed25519KeyMaterial = () => ({});\n"
    )

    # Availability is satisfied — which is the whole reason this gap existed.
    assert TsSidecar.availability(repo) == :ok

    assert {:error, error} = TsSidecar.verify(golden(), now: @pinned_now, aph_repo_path: repo)

    assert error.kind == :unavailable
    assert error.reason == :dist_broken

    # It degrades the way every other setup gap does: with the build line.
    assert error.message =~ "npm run build"
    assert error.message =~ "verifyEnvelope"
  end

  # Why: `:timeout` was documented, validated and never used — System.cmd/3
  # has no timeout, and nothing read the option. Measured before the fix: a
  # sidecar whose verifyEnvelope never resolves, called with `timeout: 500`,
  # was still blocked at 6s; brutal-killing the calling task left the node
  # child running, outliving the `after File.rm_rf(dir)` that should have
  # removed the temp dir holding the envelope and base64 body. In CI's :deep
  # job that is a job that hangs to the platform limit rather than failing
  # with something actionable. This pins all three properties: the budget is
  # honoured, the failure is a TOOLING failure (never a verdict), and the OS
  # process does not outlive it.
  #
  # The fixture must hold node's event loop open — node detects an unsettled
  # top-level await and exits on its own, which is not the hang being tested.
  @tag :deep
  test "verify/2 enforces its :timeout budget and leaves no orphan process" do
    repo = Path.join(System.tmp_dir!(), "jido_aph_hang_#{System.unique_integer([:positive])}")
    dist = Path.join([repo, "interpreters", "typescript", "dist"])
    on_exit(fn -> File.rm_rf(repo) end)

    File.mkdir_p!(Path.join(dist, "src"))
    File.mkdir_p!(Path.join(dist, "testkit"))

    File.write!(
      Path.join([dist, "src", "verify.js"]),
      "setInterval(() => {}, 1000);\nexport const verifyEnvelope = () => new Promise(() => {});\n"
    )

    File.write!(Path.join([dist, "src", "didkey.js"]), "export const isDidKey = () => false;\n")
    File.write!(Path.join([dist, "src", "types.js"]), "export const proofsOf = () => [];\n")

    File.write!(
      Path.join([dist, "testkit", "vectors.js"]),
      "export const RFC8032_TEST_3 = {};\nexport const ed25519KeyMaterial = () => ({});\n"
    )

    started = System.monotonic_time(:millisecond)

    assert {:error, error} =
             TsSidecar.verify(golden(), now: @pinned_now, aph_repo_path: repo, timeout: 800)

    elapsed = System.monotonic_time(:millisecond) - started

    # Bounded generously: the claim is that the budget is enforced at all, not
    # that it is precise to the millisecond.
    assert elapsed < 10_000

    assert error.kind == :sidecar_failure
    assert error.exit_status == :timeout
    assert error.message =~ "not a verdict about the envelope"

    # And the child is really dead, not merely disowned — the half that a
    # port-close alone does not achieve.
    assert {_, 1} = System.cmd("pgrep", ["-f", "jido_aph_deep_"], stderr_to_stdout: true)
  end

  # Why: THE DEPTH-SPLIT BEAT — the single test PRD-001 §8's honesty contract
  # rests on, and the reason "structurally valid" is never written as
  # "verified" anywhere in this repository.
  #
  # One envelope, two verdicts. It passes every check `JidoAph.Guard` performs:
  # under the 64 KiB bound (§7.1.7.1), strict-parses (§8.3 step 1), satisfies
  # the PrincipalSigned mode policy (§8.3.1 step 1a), and carries the
  # two-element proof chain that label requires (§7.1.11). Driven through the
  # REAL demo Gateway it is admitted and `Demo.Actions.DeliverReply` runs — the
  # message would go out. The sidecar then refuses it APH_E011: the principal's
  # proofValue is a real signature over the wrong bytes, and only a signature
  # check can tell.
  @tag :deep
  test "a structurally perfect forgery is admitted by the guard and refused by the sidecar" do
    forged = forged_principal_signature()

    # Half one: every gate the guard runs, run directly, all four passing.
    assert byte_size(forged) <= JidoAph.Guard.max_envelope_bytes()
    assert {:ok, _parsed} = APH.parse_envelope_json(forged)
    assert :ok == APH.require_attestation_mode(forged, "PrincipalSigned")
    assert {:ok, "PrincipalSigned"} == APH.verify_proof_structure(forged)

    # ...and the composite, through the agent stack the demo actually ships:
    # the Gateway admits it and the routed Action really runs.
    {:ok, gateway} =
      Demo.Jido.start_agent(Demo.Agents.Gateway,
        id: "deep-split-gateway-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> Demo.Jido.stop_agent(gateway) end)

    signal = Signal.new!("slack.reply.requested", %{reply_to: self()})
    {:ok, signal} = JidoAph.attach_notarization(signal, forged)

    assert {:ok, %Jido.Agent{}} = AgentServer.call(gateway, signal)
    assert_receive {:deliver_reply_ran, _params, context}, 1_000
    assert context.aph.verdict == "notarization-shaped, mode policy satisfied (PrincipalSigned)"

    # Half two: the same bytes, the deep leg, a refusal.
    assert {:error, refusal} =
             TsSidecar.verify(forged,
               now: @pinned_now,
               require_mode: "PrincipalSigned",
               body_bytes: golden_body()
             )

    assert refusal.kind == :refusal
    assert refusal.code == "APH_E011"
    assert refusal.message =~ "PrincipalSignatureInvalid"
    assert refusal.message =~ "the principal proof did not verify"

    # And the untampered golden still verifies under the identical call, so the
    # refusal is the forgery's doing and not the harness's.
    assert {:ok, %{verified: %{attestationMode: "PrincipalSigned"}}} =
             TsSidecar.verify(golden(),
               now: @pinned_now,
               require_mode: "PrincipalSigned",
               body_bytes: golden_body()
             )
  end
end
