defmodule JidoAph.GuardTest do
  use ExUnit.Case, async: true

  # Why this file exists: PRD-001 T7 — the guard's four-step structural gate
  # (byte bound -> strict parse -> mode gate -> proof structure) is the
  # library's entire security claim, and every branch must be pinned against
  # the REAL aph-ex refusal messages, not remembered ones. Every negative
  # here is derived in-memory at runtime from the sibling clone's goldens
  # (decode -> tamper -> re-encode builds the variant; the guard itself only
  # ever sees JSON text) — signed fixtures are never text-edited and nothing
  # derived is ever committed. Tests call prepare_signal/2 directly with a
  # context carrying :config, the one key the gate reads (the AgentServer
  # supplies more; test/jido_pins/prepare_signal_contract_test.exs pins how
  # the server wraps these returns).

  import ExUnit.CaptureLog

  alias JidoAph.Corpus
  alias JidoAph.Guard

  @moduletag capture_log: true

  defp golden, do: Corpus.example!("principal_signed_envelope.json")
  defp mode_absent, do: Corpus.example!("slack_reply_envelope.json")

  # A structurally sound NotaryAttested envelope (single-object proof) with
  # a forged PrincipalSigned label written above a structure that cannot
  # bear it (§7.1.11: the label MUST accompany a two-element chain).
  defp forged_label do
    mode_absent()
    |> JSON.decode!()
    |> put_in(["credentialSubject", "policy", "attestationMode"], "PrincipalSigned")
    |> JSON.encode!()
  end

  defp signal_with(envelope_json) do
    signal = Jido.Signal.new!("slack.reply.requested", %{})
    {:ok, signal} = JidoAph.attach_notarization(signal, envelope_json)
    signal
  end

  defp ctx(config), do: %{config: config}

  @principal_signed_config %{required: true, require_mode: "PrincipalSigned"}

  # Why: the happy path (PRD-001 §3 step 2). Pins the guard's entire admit
  # contract at once: the strict 3-tuple prepare_signal return the server
  # demands, the signal passing through unmodified, the structure-supported
  # mode "PrincipalSigned" from §7.1.11 surfacing in the runtime context,
  # and the FIXED verdict wording — which must never contain the bare words
  # "verified" or "signed", because a structure pass says nothing about
  # whether any signature verifies (§8 honesty contract).
  test "golden admitted: signal unmodified, structure mode PrincipalSigned, fixed verdict wording" do
    signal = signal_with(golden())

    assert {:ok, ^signal, %{aph: aph}} =
             Guard.prepare_signal(signal, ctx(@principal_signed_config))

    assert aph.structure_mode == "PrincipalSigned"
    assert aph.require_mode == "PrincipalSigned"
    assert aph.verdict == "notarization-shaped, mode policy satisfied (PrincipalSigned)"
    refute aph.verdict =~ ~r/\b(verified|signed)\b/
  end

  # Why: spec §7.1.7.1 — canonicalization happens on unauthenticated input,
  # so the byte bound must be enforced BEFORE any parse. This test pins
  # ATTRIBUTION, not ordering: golden bytes padded with trailing whitespace
  # still satisfy the strict parser (asserted first), so the guard's refusal
  # of the same bytes can only have come from the size gate. WHICH STEP RAN
  # FIRST is a separate claim needing separate bytes — the test below is the
  # one that catches a hoisted parse. The refusal is guard-authored: no APH
  # code, because no protocol rule was reached.
  test "oversize envelope refused by the size gate, not the parser, with no APH code" do
    padded = golden() <> String.duplicate(" ", 70_000)
    assert byte_size(padded) > Guard.max_envelope_bytes()

    # The parser itself would ADMIT these bytes — whitespace padding does
    # not disturb strict parsing — so the refusal is the size gate's alone.
    assert {:ok, _} = APH.parse_envelope_json(padded)

    assert {:error, reason} =
             Guard.prepare_signal(signal_with(padded), ctx(@principal_signed_config))

    assert reason =~ "65536-byte bound"
    assert reason =~ "refused before any parse"
    refute reason =~ "APH_E"
  end

  # Why: the ORDER of steps 1 and 2, which the test above cannot prove and
  # for a while nobody did — moving APH.parse_envelope_json/1 ahead of the
  # byte bound in gate/3 left the whole suite green, because padded-golden
  # bytes parse cleanly and a parse-first gate reaches the identical size
  # refusal one step later. §7.1.7.1 exists precisely so that unbounded,
  # unauthenticated input never reaches a parser at all, so the ordering is
  # the property and it needs bytes that are over the bound AND unparseable.
  # These are both: 70,000 bytes of "x". A parse-first gate answers with the
  # PARSER's message (asserted here against aph-ex directly); only a gate
  # that bounds first answers with the byte bound.
  test "the byte bound runs BEFORE the parse: unparseable oversize input never reaches the parser" do
    junk = String.duplicate("x", 70_000)
    assert byte_size(junk) > Guard.max_envelope_bytes()

    # What a parse-first gate would have said instead.
    assert {:error, parser_message} = APH.parse_envelope_json(junk)

    assert {:error, reason} =
             Guard.prepare_signal(signal_with(junk), ctx(@principal_signed_config))

    assert reason =~ "65536-byte bound"
    assert reason =~ "refused before any parse"
    refute reason == parser_message
    refute reason =~ "APH_E"
  end

  # Why: §8.3 step 1 — APH parses with unknown fields DENIED, and a shape
  # refusal must carry the parser's message untouched and claim no APH code
  # it did not earn. Pins pass-through by asserting the guard's reason is
  # byte-identical to what aph-ex itself returns for the same bytes.
  test "unknown envelope field refused with the parser's message and no APH code" do
    tampered =
      golden()
      |> JSON.decode!()
      |> Map.put("jidoAphUnknownField", true)
      |> JSON.encode!()

    assert {:error, reason} =
             Guard.prepare_signal(signal_with(tampered), ctx(@principal_signed_config))

    assert {:error, ^reason} = APH.parse_envelope_json(tampered)
    assert reason =~ "jidoAphUnknownField"
    refute reason =~ "APH_E"
  end

  # Why: §7.1.11 — a forged PrincipalSigned label above a single-object
  # proof is the exact forgery the proof-structure step exists to refuse,
  # and the refusal must surface as APH_E013 with the aph-ex message passed
  # through untouched (matched by code prefix, PRD-001 §7.1).
  test "forged PrincipalSigned label refused APH_E013, message passed through untouched" do
    forged = forged_label()

    assert {:error, "APH_E013" <> _ = reason} =
             Guard.prepare_signal(signal_with(forged), ctx(@principal_signed_config))

    assert {:error, ^reason} = APH.verify_proof_structure(forged)
  end

  # Why: §8.3.1 step 1a / §7.1.7 — an absent attestationMode normatively
  # means NotaryAttested, so a PrincipalSigned policy must refuse it up
  # front with APH_E012, no silent downgrade. The fixture's structure is
  # sound (asserted: §7.1.11 alone would say {:ok, "NotaryAttested"}), so
  # the refusal provably comes from the mode gate and nothing else.
  test "mode-absent envelope vs PrincipalSigned policy refused APH_E012" do
    envelope = mode_absent()
    assert {:ok, "NotaryAttested"} = APH.verify_proof_structure(envelope)

    assert {:error, "APH_E012" <> _ = reason} =
             Guard.prepare_signal(signal_with(envelope), ctx(@principal_signed_config))

    assert {:error, ^reason} = APH.require_attestation_mode(envelope, "PrincipalSigned")
  end

  # Why: THE mandatory T7 test (PRD-001 §9 T7, acceptance gate 3). The mode
  # gate checks only the DECLARED label, so it ALONE admits a forged
  # PrincipalSigned label — aph-ex documents that calling
  # require_attestation_mode without verify_proof_structure "accepts one".
  # This proves the admission-then-catch: step 3 says :ok on the forgery,
  # and only step 4 refuses it — which is why the guard runs
  # verify_proof_structure ALWAYS, even when the mode policy is satisfied.
  test "the mode gate ALONE admits a forged PrincipalSigned label; only proof structure catches it" do
    forged = forged_label()

    # Step 3 in isolation: the forged label satisfies the mode policy.
    assert :ok = APH.require_attestation_mode(forged, "PrincipalSigned")

    # Step 4 in isolation: the structure cannot bear the label.
    assert {:error, "APH_E013" <> _} = APH.verify_proof_structure(forged)

    # The assembled gate refuses despite the satisfied mode policy.
    assert {:error, "APH_E013" <> _} =
             Guard.prepare_signal(signal_with(forged), ctx(@principal_signed_config))
  end

  # Why: PRD-001 §7.1 gate step 4 is marked ALWAYS — with no mode policy
  # configured, step 3 is skipped but the forged label must still be
  # refused, and an admitted envelope's verdict must claim only what was
  # checked: "notarization-shaped" alone, never a mode policy nobody
  # configured (§8 honesty contract: claims graded to what each layer
  # earned).
  test "proof structure runs even with no mode policy; verdict claims no policy" do
    no_mode_config = %{required: true}

    assert {:error, "APH_E013" <> _} =
             Guard.prepare_signal(signal_with(forged_label()), ctx(no_mode_config))

    assert {:ok, _signal, %{aph: aph}} =
             Guard.prepare_signal(signal_with(golden()), ctx(no_mode_config))

    assert aph.verdict == "notarization-shaped"
    assert aph.structure_mode == "PrincipalSigned"
    assert aph.require_mode == nil
  end

  # Why: the a2a-extension.md §3/§5 `AgentExtension required: true` mirror
  # (PRD-001 §3 refusal-matrix row 1): a signal with no notarization
  # extension is rejected AND logged under required: true — and :required
  # must DEFAULT to true, because a guard that silently waves envelopes
  # through when its config forgot the key would be the a2a §5 violation it
  # exists to mirror. Refusal carries no APH code: no envelope was seen.
  test "missing extension under required: true rejected and logged; required defaults to true" do
    bare_signal = Jido.Signal.new!("slack.reply.requested", %{})

    log =
      capture_log(fn ->
        assert {:error, reason} =
                 Guard.prepare_signal(bare_signal, ctx(@principal_signed_config))

        assert reason =~ "notarization extension missing"
        refute reason =~ "APH_E"
      end)

    assert log =~ "aph_guard"
    assert log =~ "notarization extension missing"

    # The default with no :required key is true — same refusal.
    assert {:error, reason} = Guard.prepare_signal(bare_signal, ctx(%{}))
    assert reason =~ "notarization extension missing"
  end
end
