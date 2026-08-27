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

  ## Configuration consumed by the gate

  - `:required` (default `true`) — when `true`, a signal with no
    notarization extension is refused and logged, mirroring
    `AgentExtension required: true` (a2a-extension.md §3/§5); when `false`,
    it passes through tagged unverified in the runtime context
    (`%{aph: %{notarization: :absent, tag: :unverified}}`).
  - `:require_mode` (default `nil`) — `"PrincipalSigned"` or
    `"NotaryAttested"`; when set, step 3 runs and the admit verdict names
    the satisfied policy.

  The full config surface (validation, `:signal_patterns`, `:refusal`,
  `:depth`, and the exact checked/not-checked table) lands with the config
  card (PRD-001 T8); the gate itself is complete here.

  ## Runtime context on admit

  An admitted signal contributes one runtime-context key, `:aph`, carrying
  the fixed verdict wording, the mode the proof STRUCTURE supports (from
  step 4), and the configured mode policy:

      %{aph: %{verdict: "notarization-shaped, mode policy satisfied (PrincipalSigned)",
               structure_mode: "PrincipalSigned",
               require_mode: "PrincipalSigned"}}

  With no mode policy configured the verdict is `"notarization-shaped"`
  alone — the guard never claims a policy it was not asked to enforce.
  """

  use Jido.Plugin,
    name: "aph_guard",
    state_key: :aph_guard,
    actions: []

  require Logger

  @doc """
  The §7.1.7.1 envelope byte bound enforced before any parse.
  """
  @spec max_envelope_bytes() :: pos_integer()
  def max_envelope_bytes, do: @max_envelope_bytes

  @impl Jido.Plugin
  def prepare_signal(%Jido.Signal{} = signal, context) do
    config = Map.get(context, :config) || %{}
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

    {:ok, signal,
     %{aph: %{verdict: verdict, structure_mode: structure_mode, require_mode: require_mode}}}
  end

  defp refuse(signal, reason) do
    Logger.warning("aph_guard: refusing signal #{inspect(signal.type)}: #{reason}")
    {:error, reason}
  end
end
