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

  # The golden's window is 2026-05-21 -> 2026-05-22 and every published
  # example is now past it, so a test that wants to reach the ADMIT path has
  # to pin the clock inside the window. Pinned openly rather than by turning
  # the check off: `check_window: false` would exercise a gate the shipped
  # default does not use, and the whole reason this constant exists is that
  # the window check was missing and nothing failed.
  @pinned_now "2026-05-21T12:00:00Z"

  @principal_signed_config %{
    required: true,
    require_mode: "PrincipalSigned",
    clock: @pinned_now
  }

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

  # Why: the guard used to bind `{:ok, _normalized}` from the parse and throw
  # it away, so an admitted signal reached its Action with no idea WHO the
  # envelope named — pushing an implementer to dig the principal out of the
  # signal and label it nothing. This pins the four claims now surfaced, each
  # against the value read from the fixture at runtime rather than a
  # remembered constant, and pins that they live under their own `:claims`
  # key: the separation is the label, and a later binding check reporting what
  # it COMPARED must not be confusable with what the envelope merely SAID.
  test "an admitted envelope's own claims reach the action under :claims" do
    envelope_json = golden()
    {:ok, normalized} = APH.parse_envelope_json(envelope_json)
    decoded = JSON.decode!(normalized)
    subject = decoded["credentialSubject"]

    assert {:ok, _signal, %{aph: aph}} =
             Guard.prepare_signal(signal_with(envelope_json), ctx(@principal_signed_config))

    assert aph.claims == %{
             envelope_id: decoded["id"],
             human_principal_did: subject["humanPrincipal"]["id"],
             agent_did: subject["agent"]["id"],
             channel_kind: subject["channel"]["kind"]
           }

    # Not vacuous: these are the golden's real values.
    assert aph.claims.envelope_id == "urn:uuid:00000000-0000-4000-8000-0000000000f3"
    assert aph.claims.channel_kind == "slack"
    assert aph.claims.agent_did =~ "did:web:"
    assert aph.claims.human_principal_did =~ "did:key:"

    # The verdict is unchanged by the claims: surfacing what a document says
    # is not a check, and the wording that states what the gate DID must not
    # drift because the gate now also reports what it READ.
    assert aph.verdict == "notarization-shaped, mode policy satisfied (PrincipalSigned)"
    assert aph.depth == :structural

    # displayName is deliberately NOT surfaced — it is the field most likely
    # to be rendered straight into a UI next to an admitted action, and the
    # accessor exists for a caller that has decided how to label it.
    refute Map.has_key?(aph.claims, :human_principal_display_name)
    refute inspect(aph) =~ "Scott Wyatt"
  end

  # Why: a claims map assembled from one fixture would pass the test above
  # while being hardcoded. This runs a DIFFERENT golden — a NotaryAttested
  # envelope on a different channel with a different principal — through the
  # same gate with no mode policy, and pins that every claim moved with the
  # document.
  test "the claims come from the envelope in hand, not from one fixture" do
    discord = Corpus.example!("discord_dm_envelope.json")

    assert {:ok, _signal, %{aph: aph}} =
             Guard.prepare_signal(
               signal_with(discord),
               ctx(%{required: true, clock: @pinned_now})
             )

    assert aph.structure_mode == "NotaryAttested"
    assert aph.claims.channel_kind == "discord"
    assert aph.claims.envelope_id == "urn:uuid:00000000-0000-4000-8000-000000000003"

    golden_claims =
      Guard.prepare_signal(signal_with(golden()), ctx(@principal_signed_config))
      |> then(fn {:ok, _signal, %{aph: aph}} -> aph.claims end)

    refute aph.claims.envelope_id == golden_claims.envelope_id
    refute aph.claims.channel_kind == golden_claims.channel_kind
    refute aph.claims.human_principal_did == golden_claims.human_principal_did
  end

  # Why: a refused envelope must contribute NOTHING — the four-op gate decides
  # admission, and the decode that produces the claims runs only after it. If
  # the decode ever moved ahead of the gate, a refusal could start carrying a
  # claims map read out of a document aph-ex rejected, and a caller matching
  # on `{:error, reason}` would suddenly have attacker-chosen strings in
  # scope. Pins the refusal shape stays a bare 2-tuple on the forged label.
  test "a refused envelope contributes no claims at all" do
    assert {:error, reason} =
             Guard.prepare_signal(signal_with(forged_label()), ctx(@principal_signed_config))

    assert is_binary(reason)
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

  # Why: this input class used to CRASH the gate rather than be refused by
  # it. The Notarization schema's `:string` is a NimbleOptions binary, so
  # attach_notarization/3 accepts bytes that are not UTF-8; aph-ex's ops then
  # RAISE ArgumentError instead of returning {:error, _}, and through a real
  # agent that surfaced as "Plugin prepare_signal crashed" with no
  # details.reason and NO refusal log line — failing closed, but outside the
  # refusal contract the moduledoc promises and with no a2a-extension.md §5
  # audit record. The class is reachable by any A2A bridge doing exactly what
  # docs/a2a-carry-mapping.md instructs: attach the exact bytes received,
  # never a re-serialization. Pins both halves — the {:error, reason} shape
  # and the log line — plus the absence of an APH code (no protocol rule was
  # reached) and that the raise is really gone.
  test "non-UTF-8 envelope refused with a logged reason, not an ArgumentError" do
    not_text = <<0xFF, 0xFE>> <> golden()
    refute String.valid?(not_text)

    # aph-ex raises rather than refusing, which is what the gate absorbs.
    assert_raise ArgumentError, fn -> APH.parse_envelope_json(not_text) end

    {result, log} =
      with_log(fn ->
        Guard.prepare_signal(signal_with(not_text), ctx(@principal_signed_config))
      end)

    assert {:error, reason} = result
    assert reason =~ "not valid UTF-8 text"
    assert reason =~ "refused before any parse"
    refute reason =~ "APH_E"

    assert log =~ "aph_guard: refusing signal"
    assert log =~ reason
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
    no_mode_config = %{required: true, clock: @pinned_now}

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
    assert {:error, reason} = Guard.prepare_signal(bare_signal, ctx(%{clock: @pinned_now}))
    assert reason =~ "notarization extension missing"
  end

  # Why this test exists: it is the defect that started the pressure test.
  # The guard shipped with NO validity-window check at all — `lib/` held not
  # one reference to DateTime, validFrom or validUntil — so the demo's own
  # happy path admitted a golden that expired 2026-05-22, and all twelve
  # published examples are past their windows. This pins the refusal against
  # the REAL system clock, deliberately using no pinned clock, so the test
  # goes red again the day the check is removed or defaulted off.
  test "the expired golden is refused against the system clock (§8.3 time window)" do
    assert {:error, reason} =
             Guard.prepare_signal(signal_with(golden()), ctx(%{require_mode: "PrincipalSigned"}))

    assert reason =~ "window check"
    assert reason =~ "expired"
    # No borrowed code. APH_E003 is MandateExpired, scoped to a Communication
    # or Delegation Mandate — not an envelope's own window against a clock —
    # and miscitation is how a closed taxonomy stops meaning anything. The
    # gap is filed upstream (aph RFC 0003 proposes APH_E019).
    refute reason =~ "APH_E"
  end

  # Why this test exists: SQUILLO_BOOK ch.15 §202 — "A Security Guard Is Not
  # Verified Until a Mutant of It Is Killed". The window comparison is one
  # operator wide, and a `>` that should be `>=` (or a skew applied to the
  # wrong side) is exactly the mutation line coverage cannot see. These four
  # cells straddle the boundary at +/-1s around the 60s skew, so flipping the
  # comparator or dropping the skew term kills at least one of them.
  test "the skew boundary is pinned on both sides, at one-second resolution" do
    # validUntil is 2026-05-22T00:00:00Z; skew is 60s.
    admit = fn clock ->
      match?(
        {:ok, _, _},
        Guard.prepare_signal(signal_with(golden()), ctx(%{clock: clock}))
      )
    end

    assert admit.("2026-05-22T00:00:59Z"), "59s past validUntil is inside the 60s skew"
    assert admit.("2026-05-22T00:01:00Z"), "exactly 60s past validUntil is still inside the skew"
    refute admit.("2026-05-22T00:01:01Z"), "61s past validUntil is outside the skew"

    # The not-yet-valid side, which a check written only for expiry misses.
    refute admit.("2026-05-20T23:58:59Z"), "61s before validFrom is outside the skew"
    assert admit.("2026-05-20T23:59:01Z"), "59s before validFrom is inside the skew"
  end

  # Why this test exists: a verifier that cannot establish its own clock
  # cannot judge a window, and both verdicts it could invent are lies —
  # SQUILLO_BOOK ch.15 §146, "a port that carries a decision has no safe
  # default". Refusing is the only honest answer, so it is pinned.
  test "an unusable :clock refuses rather than guessing a verdict" do
    assert {:error, reason} =
             Guard.prepare_signal(signal_with(golden()), ctx(%{clock: "not-an-instant"}))

    assert reason =~ "window check"
    assert reason =~ ":clock"
  end
end
