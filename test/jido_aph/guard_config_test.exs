defmodule JidoAph.GuardConfigTest do
  use ExUnit.Case, async: true

  # Why this file exists: PRD-001 T8 — the guard's config surface is the
  # deployment-facing security contract (a2a-extension.md §5 required
  # semantics, the mode policy, per-agent scoping, the :deep seam), and an
  # unvalidated or silently-stripped config key is a disabled gate. Every
  # validation test here runs through the REAL framework seam the demo's
  # agents will compile through (Jido.Plugin.Config.resolve_config!/2 /
  # Jido.Plugin.Instance.new/1 — Zoi end to end, pinned in
  # test/jido_pins/plugin_config_schema_test.exs), and the behavior tests
  # call prepare_signal/2 directly like test/jido_aph/guard_test.exs (T7),
  # which owns the four-step gate itself.

  import ExUnit.CaptureLog

  alias JidoAph.Corpus
  alias JidoAph.DeepVerifiers.NotAVerifier
  alias JidoAph.DeepVerifiers.SeamProbe
  alias JidoAph.Guard

  @moduletag capture_log: true

  setup_all do
    # resolve_config/2 probes config_schema/0 with function_exported?/3
    # WITHOUT loading the module, so an unloaded plugin's config passes
    # through UNVALIDATED on a lazily-loading VM — the T3-pinned trap
    # (test/jido_pins/plugin_config_schema_test.exs). Load first, always.
    {:module, Guard} = Code.ensure_loaded(Guard)
    :ok
  end

  defp golden, do: Corpus.example!("principal_signed_envelope.json")

  # Same forgery as T7's guard tests: a structurally sound single-object
  # proof wearing a PrincipalSigned label it cannot bear (§7.1.11).
  defp forged_label do
    Corpus.example!("slack_reply_envelope.json")
    |> JSON.decode!()
    |> put_in(["credentialSubject", "policy", "attestationMode"], "PrincipalSigned")
    |> JSON.encode!()
  end

  defp signal_with(envelope_json, type \\ "slack.reply.requested") do
    signal = Jido.Signal.new!(type, %{})
    {:ok, signal} = JidoAph.attach_notarization(signal, envelope_json)
    signal
  end

  defp ctx(config), do: %{config: config}

  # ---------------------------------------------------------------
  # Config validation (the Zoi config_schema, resolved at agent compile)
  # ---------------------------------------------------------------

  # Why: the documented defaults ARE the security posture — required: true
  # (fail closed on missing envelopes), no mode policy, gate everything,
  # refuse-and-log, structural depth, no verifier. This pins the exact
  # resolved map so a default drifting (e.g. required flipping to false)
  # fails a test, not a deployment.
  test "empty config resolves to the exact documented defaults" do
    assert Jido.Plugin.Config.resolve_config!(Guard, %{}) == %{
             required: true,
             require_mode: nil,
             signal_patterns: [],
             refusal: :refuse_and_log,
             depth: :structural,
             deep_verifier: nil
           }
  end

  # Why: PRD-001 §9 T9 mounts the guard with exactly this config on the
  # demo Gateway; pinning it here means T9 cannot be the first place the
  # schema meets its real consumer. Defaults must merge in around it.
  test "the demo Gateway's mount config validates and merges defaults" do
    assert Jido.Plugin.Config.resolve_config!(Guard, %{
             required: true,
             require_mode: "PrincipalSigned",
             signal_patterns: ["slack.reply.requested"]
           }) == %{
             required: true,
             require_mode: "PrincipalSigned",
             signal_patterns: ["slack.reply.requested"],
             refusal: :refuse_and_log,
             depth: :structural,
             deep_verifier: nil
           }
  end

  # Why: unknown keys must be REFUSED, not stripped (Zoi's default is
  # :strip) — a typo'd `require_mode` that silently vanishes IS a disabled
  # mode gate. Asserted at both seams: resolve_config's error and the
  # ArgumentError agents hit at compile time via Instance.new (the seam
  # pinned in test/jido_pins/plugin_config_schema_test.exs).
  test "a misspelled config key fails closed at the agent-compile seam" do
    assert {:error, errors} =
             Jido.Plugin.Config.resolve_config(Guard, %{require_mod: "PrincipalSigned"})

    assert Zoi.prettify_errors(errors) =~ "unrecognized key"

    assert_raise ArgumentError, ~r/Config validation failed/, fn ->
      Jido.Plugin.Instance.new({Guard, %{require_mod: "PrincipalSigned"}})
    end
  end

  # Why: require_mode is closed wire vocabulary — nil | "PrincipalSigned" |
  # "NotaryAttested", strings because attestation modes live in envelope
  # JSON text, never as BEAM atoms. A misspelled or atom-typed mode must
  # refuse, not coerce: a config that MEANT to demand PrincipalSigned and
  # silently didn't is the §8.3.1 downgrade the gate exists to prevent.
  test "require_mode accepts only nil or the two mode strings" do
    assert %{require_mode: nil} = Jido.Plugin.Config.resolve_config!(Guard, %{require_mode: nil})

    assert %{require_mode: "NotaryAttested"} =
             Jido.Plugin.Config.resolve_config!(Guard, %{require_mode: "NotaryAttested"})

    assert {:error, _} = Jido.Plugin.Config.resolve_config(Guard, %{require_mode: "Bogus"})

    assert {:error, _} =
             Jido.Plugin.Config.resolve_config(Guard, %{require_mode: :PrincipalSigned})
  end

  # Why: PRD-001 §7.1 fixes refusal to :refuse_and_log in v1. The key
  # exists so the refusal posture is named, explicit config — and any other
  # value (a hoped-for :raise, a typo) must refuse rather than silently
  # meaning "whatever the guard happens to do".
  test "refusal accepts only :refuse_and_log" do
    assert %{refusal: :refuse_and_log} =
             Jido.Plugin.Config.resolve_config!(Guard, %{refusal: :refuse_and_log})

    assert {:error, _} = Jido.Plugin.Config.resolve_config(Guard, %{refusal: :raise})
  end

  # Why: signal_patterns must be a list of pattern strings (the framework's
  # own type — deps/jido/lib/jido/plugin.ex validates the compile-time
  # variant as Zoi.list(Zoi.string())). A bare string or atom list would
  # match nothing at runtime while looking configured — refuse it.
  test "signal_patterns must be a list of strings" do
    assert {:error, _} =
             Jido.Plugin.Config.resolve_config(Guard, %{signal_patterns: "slack.*"})

    assert {:error, _} = Jido.Plugin.Config.resolve_config(Guard, %{signal_patterns: [:slack]})
  end

  # Why: PRD-001 §7.1/§9 T8 — config validation rejects :deep unless a
  # deep_verifier module is supplied, because nothing in-library provides
  # one. The refusal message must name JidoAph.DeepVerifier: the error IS
  # the signpost to the seam.
  test "depth: :deep without a deep_verifier is refused, naming the behaviour" do
    assert {:error, errors} = Jido.Plugin.Config.resolve_config(Guard, %{depth: :deep})
    assert Zoi.prettify_errors(errors) =~ "JidoAph.DeepVerifier"

    assert_raise ArgumentError, ~r/JidoAph.DeepVerifier/, fn ->
      Jido.Plugin.Instance.new({Guard, %{depth: :deep}})
    end
  end

  # Why: the :deep validation checks the BEHAVIOUR contract, not mere
  # module existence — a module without @behaviour JidoAph.DeepVerifier
  # and verify/2 can never be invoked as a verifier, so accepting it would
  # defer the failure to the worst possible moment (verification time).
  test "depth: :deep with a non-implementing module is refused" do
    assert {:error, errors} =
             Jido.Plugin.Config.resolve_config(Guard, %{
               depth: :deep,
               deep_verifier: NotAVerifier
             })

    assert Zoi.prettify_errors(errors) =~ "JidoAph.DeepVerifier"
  end

  # Why: the other half of the :deep rule — a module that genuinely
  # implements JidoAph.DeepVerifier (@behaviour declared, verify/2
  # exported) makes depth: :deep valid config. This is the seam T12's
  # sidecar implementation will pass through.
  test "depth: :deep with a behaviour-implementing module is accepted" do
    assert %{depth: :deep, deep_verifier: SeamProbe} =
             Jido.Plugin.Config.resolve_config!(Guard, %{
               depth: :deep,
               deep_verifier: SeamProbe
             })
  end

  # Why: naming a verifier under depth: :structural is legal (a deployment
  # may stage the module before flipping depth) — the cross-field rule only
  # binds :deep to a verifier, never the reverse.
  test "depth: :structural may name a deep_verifier without effect" do
    assert %{depth: :structural, deep_verifier: SeamProbe} =
             Jido.Plugin.Config.resolve_config!(Guard, %{deep_verifier: SeamProbe})
  end

  # ---------------------------------------------------------------
  # required: true / false behavior (a2a-extension.md §5 mirror)
  # ---------------------------------------------------------------

  # Why: PRD-001 §9 T8 "both required modes have behavior tests" — the
  # permissive half. Under required: false a signal with NO notarization
  # extension passes through TAGGED UNVERIFIED (a2a-extension.md §5 step 6:
  # permissive policy delivers with a "Not notarized" indicator), and the
  # tag rides the RUNTIME CONTEXT — the receiver-authored rail — never the
  # signal itself (see the guard moduledoc for the three source-grounded
  # reasons). The same bare signal under required: true refuses (the strict
  # half, pinned in full in test/jido_aph/guard_test.exs).
  test "required: false passes a bare signal through tagged unverified in the runtime context" do
    bare_signal = Jido.Signal.new!("slack.reply.requested", %{})

    log =
      capture_log(fn ->
        assert {:ok, ^bare_signal, %{aph: %{notarization: :absent, tag: :unverified}}} =
                 Guard.prepare_signal(bare_signal, ctx(%{required: false}))
      end)

    # Logged, and honestly: the pass-through announces itself as unverified
    # and never claims the words a gate must earn.
    assert log =~ "aph_guard"
    assert log =~ "unverified"
    refute log =~ ~r/\b(verified|signed)\b/

    # The signal itself is untouched — no extension added, nothing riding
    # the wire; the tag exists only in the receiver's runtime context.
    assert JidoAph.read_notarization(bare_signal) == nil

    # Contrast, same signal, strict half: required: true refuses.
    assert {:error, reason} = Guard.prepare_signal(bare_signal, ctx(%{required: true}))
    assert reason =~ "notarization extension missing"
  end

  # Why: required: false is permissive about ABSENT envelopes only. An
  # envelope that IS present always gets the full four-step gate — waving a
  # forged PrincipalSigned label through as merely "unverified" would
  # launder a §7.1.11 forgery into delivery. Present-but-bad refuses even
  # under the permissive setting.
  test "required: false still gates a present envelope: forged label refused APH_E013" do
    assert {:error, "APH_E013" <> _} =
             Guard.prepare_signal(signal_with(forged_label()), ctx(%{required: false}))
  end

  # ---------------------------------------------------------------
  # signal_patterns scoping (config-level, framework semantics)
  # ---------------------------------------------------------------

  # Why: config-level :signal_patterns scopes WHICH signals the guard
  # gates, mirroring what the framework does when spec-level patterns
  # exclude a signal (hook never invoked, signal continues untouched):
  # out-of-scope means pass-through with an EMPTY delta — no tag, no
  # refusal, no claim, because nothing was examined. In-scope bare signals
  # still refuse under required: true.
  test "out-of-scope signals pass through un-gated; in-scope signals are gated" do
    config = %{required: true, signal_patterns: ["slack.reply.requested"]}

    out_of_scope = Jido.Signal.new!("unrelated.event", %{})
    assert {:ok, ^out_of_scope, %{}} = Guard.prepare_signal(out_of_scope, ctx(config))

    in_scope = Jido.Signal.new!("slack.reply.requested", %{})
    assert {:error, reason} = Guard.prepare_signal(in_scope, ctx(config))
    assert reason =~ "notarization extension missing"
  end

  # Why: the matching semantics must be the FRAMEWORK's, not a lookalike —
  # T3 pinned (test/jido_pins/signal_patterns_test.exs) that a trailing
  # ".*" is a MULTI-segment prefix match that excludes the bare prefix
  # (deps/jido/lib/jido/agent_server.ex signal_type_matches?/2). "slack.*"
  # must gate "slack.reply.requested" (3 segments) and NOT gate bare
  # "slack"; a guard with divergent semantics would silently un-scope a
  # deployment's patterns.
  test "pattern matching mirrors the framework: trailing .* is multi-segment, excludes bare prefix" do
    config = %{required: true, signal_patterns: ["slack.*"]}

    gated = Jido.Signal.new!("slack.reply.requested", %{})
    assert {:error, _} = Guard.prepare_signal(gated, ctx(config))

    bare_prefix = Jido.Signal.new!("slack", %{})
    assert {:ok, ^bare_prefix, %{}} = Guard.prepare_signal(bare_prefix, ctx(config))
  end

  # ---------------------------------------------------------------
  # depth: :deep at runtime (the v1 gate stays structural)
  # ---------------------------------------------------------------

  # Why: PRD-001 §7.1 — depth is ":structural only" in v1: prepare_signal
  # never invokes the deep verifier even when :deep is validly configured.
  # SeamProbe refuses EVERY envelope, so the golden being ADMITTED under
  # depth: :deep is proof the gate did not consult it; and the runtime
  # context reports depth: :structural — what the gate RAN, never what the
  # config declared — so no downstream reader can harvest an unearned
  # deep-verification claim (§8 honesty contract).
  test "depth: :deep changes nothing in the gate: admitted structurally, context says :structural" do
    config = %{
      required: true,
      require_mode: "PrincipalSigned",
      depth: :deep,
      deep_verifier: SeamProbe
    }

    signal = signal_with(golden())

    assert {:ok, ^signal, %{aph: aph}} = Guard.prepare_signal(signal, ctx(config))
    assert aph.verdict == "notarization-shaped, mode policy satisfied (PrincipalSigned)"
    assert aph.depth == :structural
    refute aph.verdict =~ ~r/\bdeep\b/
  end
end
