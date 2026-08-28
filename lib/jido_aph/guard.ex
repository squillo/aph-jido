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
     input, so the byte bound is enforced first), followed by a UTF-8
     well-formedness check on the now-bounded bytes, because the extension
     schema's `:string` is a binary type and the `aph-ex` ops raise on
     anything that is not text;
  2. `APH.parse_envelope_json/1` — strict, unknown fields denied (§8.3
     step 1);
  3. `APH.require_attestation_mode/2` when `:require_mode` is configured
     (§8.3.1 step 1a; `APH_E012`; an absent mode normatively means
     NotaryAttested — §7.1.7 — so a PrincipalSigned policy refuses it up
     front, no silent downgrade);
  4. `APH.verify_proof_structure/1` — **always**, even with no mode policy,
     because the mode gate alone admits a forged PrincipalSigned label
     (§7.1.11; `APH_E013`).

  After those four — and only after — the gate decodes the NORMALIZED
  document `step 2` returned, via `JidoAph.Envelope.from_normalized/1`, so
  the admit context can report what the envelope says about itself. That
  decode is **not a fifth gate step**: it applies no rule, it can admit
  nothing the four ops refused, and it runs on bytes `serde_json` already
  adjudicated rather than on the wire bytes. See `JidoAph.Envelope` for why
  the distinction between the two is the whole reason that module exists.

  ## What a pass means — and what it does not

  An admitted signal is **"notarization-shaped"** and, when a mode policy is
  configured, **"mode policy satisfied"**. That is the guard's entire claim.
  Per aph-ex, a structure pass "says NOTHING about whether any signature
  verifies" — this guard runs zero cryptography, checks no signatures, no
  keys, no bodySha256, and no revocation. Cryptographic depth belongs to a
  deep verifier outside this gate.

  Two non-cryptographic checks it DOES make, both easy to miss: the closed
  channel-kind and content-class vocabularies (§7.1.5/§7.1.6), enforced at
  parse since aph `57431e6` turned those sets into the field types — no op
  to call and no code here to maintain — and the validity window, below.

  It DOES check the validity window (§8.3), because that is a `DateTime`
  comparison rather than a cipher and the "no cryptography" line never
  covered it. That check was missing until the day an expired golden was
  found admitted on the demo's own happy path; see `check_window/2`.

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
  - `:check_window` (default `true`) — the §8.3 validity-window check.
    Default ON: it was absent, and its absence admitted a 98-day-expired
    authorization. Setting it `false` is an explicit, named decision to
    accept envelopes outside their window, and the admit context records
    that the check did not run.
  - `:clock` (default `:system`) — `:system`, a `DateTime`, or an RFC 3339
    string. A pinned clock exists because every published example is now
    past its window, so a demo or a fixture-driven test must be able to
    reach the admit path — while SAYING it pinned the clock. A value that
    is neither refuses the envelope rather than inventing a verdict
    (SQUILLO_BOOK ch.15 §146).
  - `:clock_skew_seconds` (default `60`) — allowed drift on both edges of
    the window, per the spec's RECOMMENDED tolerance.

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
  | Validity window (§8.3, 60s skew) | YES — `:check_window`, default on | YES — against pinned `now`, stated | |
  | bodySha256 over received bytes (§8.3 step 8, APH_E009) | no | YES | |
  | Closed channel/contentClass vocabulary (§7.1.5/§7.1.6) | YES — at parse, since aph 57431e6 made the sets the field TYPES; no op to call | YES (TS enforces) | |
  | Key discovery: DNS TXT / did:web (§8.4) | no | no (TS never fetches; did:key decodes offline; the golden's one did:web notary key is supplied via `options.keys` and the transcript says so) | YES — named in README |
  | Revocation / credentialStatus transport | no | no (golden carries none; TS refuses status-bearing envelopes) | YES — named in README |
  | Live notary contact | no | no | YES — named in README |

  Zero cryptography runs in Elixir. The guard is depth 0–1 plus mode
  policy; the deep leg is full offline §8.3 (one out-of-band notary key,
  stated); the third column is stated, not implied.

  The table above is a table of CHECKS, and adding `:claims` to the admit
  context below added no row to it: the four field values it carries are
  READ from the document and compared against nothing. In particular
  `channel_kind` is not the closed-vocabulary row (still "no"), and
  `human_principal_did` is not the signatures row (still "no").

  ## Runtime context on admit

  An admitted signal contributes one runtime-context key, `:aph`, carrying
  the fixed verdict wording, the mode the proof STRUCTURE supports (from
  step 4), the configured mode policy, the depth the gate RAN, and — under
  a separate `:claims` key — four fields read out of the envelope:

      %{aph: %{verdict: "notarization-shaped, mode policy satisfied (PrincipalSigned)",
               structure_mode: "PrincipalSigned",
               require_mode: "PrincipalSigned",
               depth: :structural,
               claims: %{envelope_id: "urn:uuid:...",
                         human_principal_did: "did:key:...",
                         agent_did: "did:web:...",
                         channel_kind: "slack"}}}

  With no mode policy configured the verdict is `"notarization-shaped"`
  alone — the guard never claims a policy it was not asked to enforce.
  `:depth` is always `:structural` in v1 — it states what this gate DID,
  never what the config declared, so a `depth: :deep` deployment cannot
  read an unearned deep-verification claim out of the gate's own context.

  `:claims` is a separate key, and the separation is the label. Everything
  under it is **the envelope's own UNVERIFIED claim about itself**: a string
  lifted out of a document whose signatures nothing on this rail checked.
  `human_principal_did` does not mean that human authorized anything;
  `agent_did` is unauthenticated even in a fully signature-verified envelope
  (§7.1.11 gives the agent no proof role at all); `channel_kind` was not
  compared against any delivery context; `envelope_id` was not checked
  against anything previously seen. A value may be `nil` when the document
  omits the field — absent, never defaulted.

  It is surfaced anyway, and deliberately, because the alternative shipped
  for a while and was worse: with the guard silent about who the envelope
  names, an implementer who wants the principal's DID digs it out of the
  signal or re-parses the envelope at the Action and labels the result
  nothing at all. A labelled claim in the receiver's own runtime context is
  the honest version of a fact implementers were going to obtain regardless.
  Later checks that BIND against these fields would report themselves
  separately, because "this is what the envelope said" and "this is what we
  compared it to" are different sentences.
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
                     deep_verifier: Zoi.atom() |> Zoi.default(nil),
                     protect_actions: Zoi.list(Zoi.atom()) |> Zoi.default([]),
                     check_window: Zoi.boolean() |> Zoi.default(true),
                     clock: Zoi.any() |> Zoi.default(:system),
                     clock_skew_seconds: Zoi.integer() |> Zoi.default(60)
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

  alias JidoAph.Envelope

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

      # The extension schema guarantees envelope_json is a BINARY when the
      # extension is present — not that it is UTF-8 text, which the aph-ex
      # ops require; gate/3's check_text/1 closes that gap. Any other shape
      # falls through no clause here and fails closed (the server converts a
      # raise to an ExecutionError).
      case JidoAph.read_notarization(signal) do
        nil ->
          handle_missing(signal, required)

        %{envelope_json: envelope_json} when is_binary(envelope_json) ->
          gate(signal, envelope_json, require_mode, config)
      end
    else
      # Out of the configured scope: pass through un-gated with an empty
      # delta, mirroring what the framework does when spec-level patterns
      # exclude a signal (the hook is simply never invoked) — no tag, no
      # claim, because nothing was examined.
      {:ok, signal, %{}}
    end
  end

  @doc """
  Post-routing authorization: refuses a routed Action when a signal in the
  guard's scope arrives carrying no admit verdict.

  ## Why this hook exists at all

  `prepare_signal/2` gates on the way IN, and until 2026-08-28 that was the
  guard's only hook — which meant the guard was advisory rather than a gate.
  Four paths were proven to route an Action without `prepare_signal/2` ever
  seeing the signal; two of them are closable from a plugin and this closes
  them:

    * a co-mounted plugin returning `{:override, Action, renamed_signal}`,
      where the RENAME dodges this guard's `:signal_patterns` and the
      original gate never ran on the type that actually routed;
    * a route whose pattern is wider than the guard's — `"slack.reply.*"`
      against `["slack.reply.requested"]` — where a sibling type routes the
      same Action with the gate silently out of scope.

  The other two (`Jido.Agent.cmd/3` and `%Directive.RunInstruction{}`) never
  enter the hook chain at all and CANNOT be closed from here. They are the
  action's own responsibility, and `DeliverReply`'s moduledoc said otherwise
  until this landed.

  ## The rule

  Fail closed, and only where this guard has standing: if the signal is in
  the configured scope and the accumulated runtime context carries no `:aph`
  verdict, refuse. Out-of-scope signals pass — this plugin was configured
  not to speak for them, and inventing an opinion about traffic another
  mount owns is how a gate becomes a nuisance.

  A verdict from `prepare_signal/2` is the ONLY thing accepted as proof the
  gate ran. It cannot be forged by the sender: the runtime context is
  authored by the receiving agent's own hook chain and never travels on the
  wire (see the `:required` note above for why the tag lives here).
  """
  @impl Jido.Plugin
  def prepare_action(%Jido.Signal{} = signal, action_arg, context) do
    config = Map.get(context, :config) || %{}

    protected? = protected_action?(action_arg, Map.get(config, :protect_actions, []))

    if protected? or in_scope?(signal.type, Map.get(config, :signal_patterns, [])) do
      case get_in(context, [:runtime_context, :aph]) do
        nil ->
          Logger.warning(
            "aph_guard: refusing to run the action routed from #{inspect(signal.type)}: " <>
              "the signal is in this guard's scope but carries no admit verdict, so " <>
              "prepare_signal/2 never gated it"
          )

          {:error,
           "aph_guard: action refused — #{inspect(signal.type)} is in scope but reached " <>
             "routing with no admit verdict; prepare_signal/2 never gated this signal"}

        _verdict ->
          {:ok, %{}}
      end
    else
      {:ok, %{}}
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
  # Scope answers "is this signal type mine?", which a RENAME defeats by
  # construction: a co-mounted plugin returning {:override, Action, renamed}
  # produces a type the patterns do not match, so a scope-only check waves it
  # through while the original Action still runs. Authorizing the resolved
  # ACTION is the rename-proof question, and it is the one this hook was built
  # to ask — `action_arg` is handed to us precisely so the answer does not
  # depend on what the signal calls itself.
  #
  # Empty list = nothing named = scope alone decides, which is the v1 default
  # and NOT a silent one: an unconfigured :protect_actions cannot know a
  # deployment's action modules, and inventing a list would be worse than
  # saying so in the docs.
  defp protected_action?(_action_arg, []), do: false
  defp protected_action?(_action_arg, nil), do: false

  defp protected_action?(action_arg, protected) when is_list(protected) do
    action_arg |> action_modules() |> Enum.any?(&(&1 in protected))
  end

  # `action_arg_from_spec/1` (deps/jido/lib/jido/agent_server.ex) hands us one
  # spec, a list of them, or whatever else a route produced. Each spec is a
  # module or a {module, opts} pair. Anything unrecognized yields no module,
  # which means "not protected" — and that is safe here ONLY because scope is
  # still checked alongside: an unreadable action never turns a refusal into
  # an admit, it just fails to add one.
  defp action_modules(list) when is_list(list), do: Enum.flat_map(list, &action_modules/1)
  defp action_modules({mod, _opts}) when is_atom(mod), do: [mod]
  defp action_modules(mod) when is_atom(mod) and not is_nil(mod), do: [mod]
  defp action_modules(_other), do: []

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

  defp gate(signal, envelope_json, require_mode, config) do
    # `normalized` is APH.parse_envelope_json/1's OUTPUT, and it is the only
    # thing Envelope.from_normalized/1 is ever handed. Passing `envelope_json`
    # there instead would put a second parser on the trust path — see
    # JidoAph.Envelope's moduledoc for what that would cost, and
    # test/jido_aph/envelope_test.exs for the pin that keeps this call site
    # honest.
    with :ok <- check_size(envelope_json),
         :ok <- check_text(envelope_json),
         {:ok, normalized} <- APH.parse_envelope_json(envelope_json),
         :ok <- check_mode(envelope_json, require_mode),
         {:ok, structure_mode} <- APH.verify_proof_structure(envelope_json),
         {:ok, envelope} <- Envelope.from_normalized(normalized),
         :ok <- check_window(envelope, config) do
      admit(signal, envelope, structure_mode, require_mode)
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

  # Step 1's other half — also before any parse, also guard-authored, and
  # deliberately AFTER the byte bound so an unbounded blob is refused by size
  # rather than scanned. The extension schema's `:string` is a NimbleOptions
  # BINARY, not a text type: `attach_notarization/3` accepts bytes that are
  # not UTF-8, and an A2A bridge attaching the exact bytes it received —
  # which docs/a2a-carry-mapping.md instructs, precisely so nothing
  # re-serializes a signed document — can hand this gate some. aph-ex's ops
  # require UTF-8 and RAISE ArgumentError otherwise, which escapes
  # prepare_signal as a "Plugin prepare_signal crashed" ExecutionError
  # carrying no `details.reason` and writing no refusal line: still closed,
  # but outside the refusal contract and with no a2a-extension.md §5 audit
  # record. Refused here instead. No APH code and no spec citation — the
  # specification says nothing about transfer encoding, so neither does this.
  # §8.3's time-window step. It is a MUST in the specification and this gate
  # did not implement it — the demo's own happy path admitted a golden that
  # expired 2026-05-22, and every one of the twelve published examples is
  # past its window. The excuse available was the project's "no cryptography
  # in Elixir" non-goal, and it never covered this: comparing two RFC 3339
  # instants is a comparison, not a cipher.
  #
  # NO BORROWED CODE. The spec's closed §11 table has no code for an
  # envelope's own window failing against the clock: `APH_E003` is
  # `MandateExpired`, defined for "a Communication Mandate or Delegation
  # Mandate consulted past its expiresAt / validUntil" — a different subject.
  # Miscited codes are how a taxonomy stops meaning anything, so this refusal
  # carries a guard-authored message and no code, and the gap is filed
  # upstream (aph RFC 0003 proposes APH_E019).
  #
  # `:clock` exists because the published corpus is expired and a demo must
  # be able to run against it while SAYING SO. A pinned clock that lies
  # silently would be worse than no check; `admit/4` reports which clock
  # ruled, and the transcript prints it.
  defp check_window(envelope, config) do
    if Map.get(config, :check_window, true) do
      now = resolve_clock(Map.get(config, :clock, :system))
      skew = Map.get(config, :clock_skew_seconds, 60)

      compare_window(Envelope.valid_from(envelope), Envelope.valid_until(envelope), now, skew)
    else
      :ok
    end
  end

  defp resolve_clock(:system), do: DateTime.utc_now()
  defp resolve_clock(%DateTime{} = pinned), do: pinned

  defp resolve_clock(pinned) when is_binary(pinned) do
    case DateTime.from_iso8601(pinned) do
      {:ok, dt, _offset} -> dt
      _ -> :invalid_clock
    end
  end

  defp resolve_clock(_), do: :invalid_clock

  # A verifier that cannot establish its own clock cannot judge a window, and
  # inventing one of the two verdicts is exactly the fail-open this check
  # exists to delete. Refuse instead.
  defp compare_window(_from, _until, :invalid_clock, _skew),
    do: {:error, "window check: the configured :clock is not an RFC 3339 instant or a DateTime"}

  defp compare_window(nil, _until, _now, _skew),
    do: {:error, "window check: the envelope declares no validFrom"}

  defp compare_window(_from, nil, _now, _skew),
    do: {:error, "window check: the envelope declares no validUntil"}

  defp compare_window(from, until, now, skew) do
    with {:ok, from_dt, _} <- DateTime.from_iso8601(from),
         {:ok, until_dt, _} <- DateTime.from_iso8601(until) do
      cond do
        DateTime.compare(now, DateTime.add(from_dt, -skew, :second)) == :lt ->
          {:error,
           "window check: envelope not yet valid (validFrom #{from}, clock " <>
             "#{DateTime.to_iso8601(now)}, #{skew}s skew allowed)"}

        DateTime.compare(now, DateTime.add(until_dt, skew, :second)) == :gt ->
          {:error,
           "window check: envelope expired (validUntil #{until}, clock " <>
             "#{DateTime.to_iso8601(now)}, #{skew}s skew allowed)"}

        true ->
          :ok
      end
    else
      _ -> {:error, "window check: validFrom/validUntil are not both RFC 3339 instants"}
    end
  end

  defp check_text(envelope_json) do
    if String.valid?(envelope_json) do
      :ok
    else
      {:error, "envelope is not valid UTF-8 text; refused before any parse"}
    end
  end

  # Step 3 — §8.3.1 step 1a, only when a mode policy is configured. The
  # label alone is not evidence: step 4 always runs after this.
  defp check_mode(_envelope_json, nil), do: :ok

  defp check_mode(envelope_json, require_mode),
    do: APH.require_attestation_mode(envelope_json, require_mode)

  defp admit(signal, envelope, structure_mode, require_mode) do
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
         depth: :structural,
         claims: claims(envelope)
       }
     }}
  end

  # The envelope's own UNVERIFIED claims about itself, kept under their own
  # key so the shape carries the label rather than only the moduledoc. Nothing
  # here was compared against anything: not against a clock, not against a
  # delivery context, not against a key, not against anything previously seen.
  # A nil means the document omitted the field.
  defp claims(envelope) do
    %{
      envelope_id: Envelope.id(envelope),
      human_principal_did: Envelope.human_principal_did(envelope),
      agent_did: Envelope.agent_did(envelope),
      channel_kind: Envelope.channel_kind(envelope)
    }
  end

  defp refuse(signal, reason) do
    Logger.warning("aph_guard: refusing signal #{inspect(signal.type)}: #{reason}")
    {:error, reason}
  end
end
