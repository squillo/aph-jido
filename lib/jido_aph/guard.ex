defmodule JidoAph.Guard do
  @max_envelope_bytes 65_536

  @moduledoc """
  The APH structural gate: a `Jido.Plugin` that refuses un-notarized or
  malformed signals in `prepare_signal/2`, before any Action runs.

  ## The four-step gate (fixed and complete, PRD-001 §7.1)

  Every signal carrying the `JidoAph.Signal.Ext.Notarization` extension is
  gated through the parity-locked four-op `aph-ex` surface, in this order,
  all steps mandatory:

  1. `byte_size(envelope_json) <= #{@max_envelope_bytes}` — **before any
     parse** (aph spec §7.1.7.1: canonicalization happens on unauthenticated
     input, so the byte bound is enforced first);
  2. `APH.parse_envelope_json/1` — strict, unknown fields denied (§8.3
     step 1);
  3. `APH.require_attestation_mode/2` when `:require_mode` is configured
     (§8.3.1 step 1a; `APH_E012`; an absent mode normatively means
     NotaryAttested — §7.1.7 — so a PrincipalSigned policy refuses it up
     front, no silent downgrade);
  4. `APH.verify_proof_structure/1` — **always**, even with no mode policy,
     because the mode gate alone admits a forged PrincipalSigned label
     (§7.1.11; `APH_E013`).

  ## What a pass means — and what it does not

  An admitted signal is **"notarization-shaped"** and, when a mode policy is
  configured, **"mode policy satisfied"**. That is the guard's entire claim.
  Per aph-ex, a structure pass "says NOTHING about whether any signature
  verifies" — this guard runs zero cryptography, checks no signatures, no
  keys, no validity window, no bodySha256, no closed vocabulary, and no
  revocation. Cryptographic depth belongs to a deep verifier outside this
  gate.

  ## Refusal contract

  A refusal returns `{:error, reason}` from `prepare_signal/2`, which halts
  the chain before routing — later plugins and the routed Action never run —
  and surfaces to the `Jido.AgentServer.call/2` caller as a
  `Jido.Error.ExecutionError` with the reason preserved verbatim under
  `details.reason` (pinned in `test/jido_pins/prepare_signal_contract_test.exs`).
  aph-ex refusal messages pass through untouched, so callers match by code
  prefix on `details.reason`:

      {:error, "APH_E012" <> _} # refused mode downgrade
      {:error, "APH_E013" <> _} # forged PrincipalSigned label

  Shape refusals (unknown field, malformed document) carry the parser's
  message and no code; the byte-bound and missing-extension refusals carry
  guard-authored messages and no code, because no protocol rule was reached.

  ## Configuration

  Per-agent config is validated by this module's Zoi `config_schema` when
  the agent compiles (`Jido.Plugin.Instance.new/1` runs
  `Jido.Plugin.Config.resolve_config!/2`, raising `ArgumentError`
  "Config validation failed" on any violation — pinned in
  `test/jido_pins/plugin_config_schema_test.exs`). Unknown keys are
  REFUSED, not stripped: a misspelled `require_mode` silently vanishing
  would disable the mode gate, so config typos fail closed.

  - `:required` (default `true`) — when `true`, a signal with no
    notarization extension is refused and logged, mirroring
    `AgentExtension required: true` (a2a-extension.md §3/§5: a deployment
    whose policy REQUIRES APH rejects and logs). When `false`, it passes
    through **tagged unverified**. How the tag rides: in the RUNTIME
    CONTEXT (`%{aph: %{notarization: :absent, tag: :unverified}}`), never
    on the signal itself. Grounded on the jido/jido_signal source, three
    reasons: (1) `prepare_signal/2`'s runtime-context delta is the
    framework's explicit rail for hook-derived facts, flowing to
    `prepare_action` and the routed Action's context
    (deps/jido/lib/jido/plugin.ex; pinned in
    `test/jido_pins/prepare_signal_contract_test.exs`); (2) anything
    riding the signal would have to be a registered extension
    (`put_extension/3` refuses unregistered namespaces) and a wire-borne
    extension is silently STRIPPED on any receiving VM without the
    namespace registered (deps/jido_signal/lib/jido_signal/serialization/
    schema.ex `unrecognized_keys: :strip`; pinned in
    `test/jido_aph/signal/ext/notarization_wire_shape_test.exs`) — a tag
    that can vanish in transit is worse than no tag; (3) a wire-borne tag
    would be sender-suppliable, while the runtime context is authored by
    the receiving agent's own guard — "unverified" must be the RECEIVER's
    claim.
  - `:require_mode` (default `nil`) — `nil`, `"PrincipalSigned"`, or
    `"NotaryAttested"` (strings: attestation modes are wire vocabulary,
    not BEAM atoms); when set, step 3 runs and the admit verdict names the
    satisfied policy.
  - `:signal_patterns` (default `[]` = gate every signal) — per-agent
    scoping, matched with the framework's OWN semantics
    (deps/jido/lib/jido/agent_server.ex `signal_type_matches?/2`, pinned
    in `test/jido_pins/signal_patterns_test.exs`: `[]` matches everything;
    a trailing `".*"` is a MULTI-segment prefix match excluding the bare
    prefix; an interior `"*"` is single-segment; anything else is
    equality). An out-of-scope signal passes through un-gated with an
    empty context delta — exactly what the framework does when a plugin's
    spec-level patterns exclude a signal (the hook is simply not invoked).
    Scoping lives in config rather than in this module's compile-time
    `use Jido.Plugin` option because the compile-time option cannot vary
    per agent; this module's compile-time patterns are `[]`, so the guard
    sees every signal and the config decides.
  - `:refusal` (default `:refuse_and_log`) — `:refuse_and_log` is the ONLY
    accepted value in v1; the key exists so the refusal posture is
    explicit, named config, not an implicit behavior a later version
    quietly changes.
  - `:depth` (default `:structural`) — `:structural` or `:deep`. Config
    validation REFUSES `:deep` unless `:deep_verifier` names a module
    implementing the `JidoAph.DeepVerifier` behaviour — which nothing
    in-library provides (the TS and Rust sidecar routes live outside this
    library). In v1 the gate itself is structural EITHER WAY:
    `prepare_signal/2` never invokes the deep verifier; the deep leg runs
    outside the gate, owned by the application. The seam exists so a
    deployment declaring `:deep` has already named a real verifier.
  - `:deep_verifier` (default `nil`) — a module implementing
    `JidoAph.DeepVerifier` (checked: the module loads, declares the
    behaviour, and exports `verify/2`).

  Note: tests calling `prepare_signal/2` directly bypass this validation —
  the gate reads `context.config` with the same defaults the schema
  declares, so unvalidated direct calls and validated agent-mounted calls
  behave identically on the keys the gate consumes.

  ## What is checked here — and what is not (PRD-001 §7.3)

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

  Zero cryptography runs in Elixir. The guard is depth 0–1 plus mode
  policy; the deep leg is full offline §8.3 (one out-of-band notary key,
  stated); the third column is stated, not implied.

  ## Runtime context on admit

  An admitted signal contributes one runtime-context key, `:aph`, carrying
  the fixed verdict wording, the mode the proof STRUCTURE supports (from
  step 4), the configured mode policy, and the depth the gate RAN:

      %{aph: %{verdict: "notarization-shaped, mode policy satisfied (PrincipalSigned)",
               structure_mode: "PrincipalSigned",
               require_mode: "PrincipalSigned",
               depth: :structural}}

  With no mode policy configured the verdict is `"notarization-shaped"`
  alone — the guard never claims a policy it was not asked to enforce.
  `:depth` is always `:structural` in v1 — it states what this gate DID,
  never what the config declared, so a `depth: :deep` deployment cannot
  read an unearned deep-verification claim out of the gate's own context.
  """

  # The per-agent config surface, validated at agent compile time (the
  # plugin layer is Zoi end to end — pinned in
  # test/jido_pins/plugin_config_schema_test.exs). `unrecognized_keys:
  # :error` makes typo'd keys fail closed instead of silently stripping a
  # gate out of the config; the object-level refine enforces the
  # cross-field rule that `:deep` names a real JidoAph.DeepVerifier.
  @config_schema Zoi.object(
                   %{
                     required: Zoi.boolean() |> Zoi.default(true),
                     require_mode:
                       Zoi.enum(["PrincipalSigned", "NotaryAttested"]) |> Zoi.default(nil),
                     signal_patterns: Zoi.list(Zoi.string()) |> Zoi.default([]),
                     refusal: Zoi.literal(:refuse_and_log) |> Zoi.default(:refuse_and_log),
                     depth: Zoi.enum([:structural, :deep]) |> Zoi.default(:structural),
                     deep_verifier: Zoi.atom() |> Zoi.default(nil)
                   },
                   unrecognized_keys: :error
                 )
                 |> Zoi.refine({__MODULE__, :validate_deep_config, []})

  use Jido.Plugin,
    name: "aph_guard",
    state_key: :aph_guard,
    actions: [],
    config_schema: @config_schema

  require Logger

  @doc """
  The §7.1.7.1 envelope byte bound enforced before any parse.
  """
  @spec max_envelope_bytes() :: pos_integer()
  def max_envelope_bytes, do: @max_envelope_bytes

  @impl Jido.Plugin
  def prepare_signal(%Jido.Signal{} = signal, context) do
    config = Map.get(context, :config) || %{}

    if in_scope?(signal.type, Map.get(config, :signal_patterns, [])) do
      required = Map.get(config, :required, true)
      require_mode = Map.get(config, :require_mode)

      # The extension schema guarantees envelope_json is a string when the
      # extension is present; any other shape falls through no clause here and
      # fails closed (the server converts a raise to an ExecutionError).
      case JidoAph.read_notarization(signal) do
        nil ->
          handle_missing(signal, required)

        %{envelope_json: envelope_json} when is_binary(envelope_json) ->
          gate(signal, envelope_json, require_mode)
      end
    else
      # Out of the configured scope: pass through un-gated with an empty
      # delta, mirroring what the framework does when spec-level patterns
      # exclude a signal (the hook is simply never invoked) — no tag, no
      # claim, because nothing was examined.
      {:ok, signal, %{}}
    end
  end

  @doc false
  # Object-level Zoi refinement for the config schema: `depth: :deep` is
  # refused unless `:deep_verifier` names a loaded module implementing the
  # JidoAph.DeepVerifier behaviour. Nothing in-library provides one; the TS
  # and Rust sidecar routes live outside this library (see
  # JidoAph.DeepVerifier's moduledoc).
  @spec validate_deep_config(map(), keyword()) :: :ok | {:error, String.t()}
  def validate_deep_config(config, _opts \\ []) do
    case config do
      %{depth: :deep} -> check_deep_verifier(Map.get(config, :deep_verifier))
      _ -> :ok
    end
  end

  defp check_deep_verifier(nil) do
    {:error,
     "depth: :deep requires a :deep_verifier module implementing the " <>
       "JidoAph.DeepVerifier behaviour; nothing in-library provides one " <>
       "(the TS and Rust sidecar routes live outside this library)"}
  end

  defp check_deep_verifier(mod) when is_atom(mod) do
    # Code.ensure_loaded/1 is load-bearing: function_exported?/3 and
    # module_info are false/unavailable for a not-yet-loaded module on a
    # lazily-loading VM (the same trap pinned for resolve_config itself in
    # test/jido_pins/plugin_config_schema_test.exs).
    with {:module, ^mod} <- Code.ensure_loaded(mod),
         true <- implements_deep_verifier?(mod) do
      :ok
    else
      _ ->
        {:error,
         "deep_verifier #{inspect(mod)} does not implement the " <>
           "JidoAph.DeepVerifier behaviour (@behaviour declared and verify/2 exported); " <>
           "depth: :deep is refused"}
    end
  end

  defp implements_deep_verifier?(mod) do
    behaviours =
      mod.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    JidoAph.DeepVerifier in behaviours and function_exported?(mod, :verify, 2)
  end

  # Config-level scoping with the framework's own matching semantics —
  # deps/jido/lib/jido/agent_server.ex signal_matches_plugin?/2 +
  # signal_type_matches?/2, pinned in test/jido_pins/signal_patterns_test.exs:
  # [] matches everything; trailing ".*" is a multi-segment prefix match
  # excluding the bare prefix; interior "*" is single-segment; otherwise
  # equality.
  defp in_scope?(_type, []), do: true
  defp in_scope?(_type, nil), do: true

  defp in_scope?(type, patterns) when is_list(patterns) do
    Enum.any?(patterns, &pattern_matches?(type, &1))
  end

  defp pattern_matches?(type, pattern) do
    cond do
      pattern == type ->
        true

      String.ends_with?(pattern, ".*") ->
        prefix = String.trim_trailing(pattern, ".*")
        String.starts_with?(type, prefix <> ".")

      String.contains?(pattern, "*") ->
        pattern_regex =
          pattern
          |> Regex.escape()
          |> String.replace("\\*", "[^.]*")

        Regex.match?(~r/^#{pattern_regex}$/, type)

      true ->
        false
    end
  end

  # Missing extension, required: true — reject and log, the
  # a2a-extension.md §5 `AgentExtension required: true` mirror.
  defp handle_missing(signal, true) do
    refuse(
      signal,
      "notarization extension missing: signal #{inspect(signal.type)} carries no " <>
        "APH envelope and this guard requires one (required: true, a2a-extension.md §5)"
    )
  end

  # Missing extension, required: false — pass through tagged unverified
  # (the messaging-side "deliver flagged as unverified").
  defp handle_missing(signal, false) do
    Logger.warning(
      "aph_guard: signal #{inspect(signal.type)} carries no notarization envelope; " <>
        "passing through tagged unverified (required: false)"
    )

    {:ok, signal, %{aph: %{notarization: :absent, tag: :unverified}}}
  end

  defp gate(signal, envelope_json, require_mode) do
    with :ok <- check_size(envelope_json),
         {:ok, _normalized} <- APH.parse_envelope_json(envelope_json),
         :ok <- check_mode(envelope_json, require_mode),
         {:ok, structure_mode} <- APH.verify_proof_structure(envelope_json) do
      admit(signal, structure_mode, require_mode)
    else
      {:error, reason} -> refuse(signal, reason)
    end
  end

  # Step 1 — §7.1.7.1 byte bound, BEFORE any parse. The envelope text has
  # not touched a parser when this refuses; the refusal is guard-authored
  # and carries no APH code because no protocol rule was reached.
  defp check_size(envelope_json) when byte_size(envelope_json) <= @max_envelope_bytes, do: :ok

  defp check_size(envelope_json) do
    {:error,
     "envelope exceeds the #{@max_envelope_bytes}-byte bound " <>
       "(#{byte_size(envelope_json)} bytes); refused before any parse (spec §7.1.7.1)"}
  end

  # Step 3 — §8.3.1 step 1a, only when a mode policy is configured. The
  # label alone is not evidence: step 4 always runs after this.
  defp check_mode(_envelope_json, nil), do: :ok

  defp check_mode(envelope_json, require_mode),
    do: APH.require_attestation_mode(envelope_json, require_mode)

  defp admit(signal, structure_mode, require_mode) do
    verdict =
      case require_mode do
        nil -> "notarization-shaped"
        mode -> "notarization-shaped, mode policy satisfied (#{mode})"
      end

    Logger.info("aph_guard: #{verdict} — admitting signal #{inspect(signal.type)}")

    # :depth states what this gate RAN — always :structural in v1, even when
    # the config declares :deep (the deep leg runs outside prepare_signal).
    {:ok, signal,
     %{
       aph: %{
         verdict: verdict,
         structure_mode: structure_mode,
         require_mode: require_mode,
         depth: :structural
       }
     }}
  end

  defp refuse(signal, reason) do
    Logger.warning("aph_guard: refusing signal #{inspect(signal.type)}: #{reason}")
    {:error, reason}
  end
end
