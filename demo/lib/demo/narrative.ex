defmodule Demo.Narrative do
  @moduledoc """
  Builds the `mix demo.run` transcript by actually running the demo.

  Every line this module emits about an outcome is rendered from what the
  real agents really did on this run — the `Jido.AgentServer.call/2` result,
  the guard's own `Logger` output, the runtime context the routed action
  received. Nothing is scripted. When reality departs from what a leg
  expects, the departure is recorded as a DEVIATION and `run/0` returns it;
  `Mix.Tasks.Demo.Run` turns a non-empty deviation list into a non-zero
  exit, so a transcript that reads correctly can never be a transcript that
  lied.

  ## Why this is a library module and not a Mix task

  Two consumers need it: the task (which prints it) and the golden-output
  test (which asserts on it, PRD-001 T11). Building the transcript as a
  STRING rather than as a stream of `IO.puts` calls is what lets the test
  assert the banner, the verdict wording, each `APH_E*` code and the
  honesty footer directly, without capturing IO or re-running the task.

  ## Determinism

  The transcript is byte-identical across runs except for the two lines that
  MUST vary — the sibling clone's HEAD SHA and its worktree cleanliness —
  because those are provenance, read from the clone at runtime rather than
  asserted from a constant. No timestamps, no pids, no agent ids and no
  absolute paths appear anywhere: an absolute path would pin the transcript
  to one machine's home directory without adding a single verifiable fact,
  and the SHA already attributes every byte.

  Log lines are collected by `Demo.Narrative.LogCapture` rather than left on
  the console, so they land inside the leg that produced them instead of
  scattered through the prose. See that module for the ordering argument.
  """

  alias Demo.Narrative.LogCapture
  alias Demo.Narrative.PassThroughGateway
  alias Jido.AgentServer
  alias Jido.Signal

  @width 78
  @label_width 22

  @envelope_file "principal_signed_envelope.json"
  @body_file "principal_signed_body.txt"
  @mode_absent_file "slack_reply_envelope.json"

  # The guard's fixed verdict wording (PRD-001 §3 step 2 / §8), spelled here
  # so a drift in JidoAph.Guard fails the transcript test loudly rather than
  # quietly changing what the demo claims.
  @verdict "notarization-shaped, mode policy satisfied (PrincipalSigned)"

  # The four gate steps, in the order JidoAph.Guard runs them.
  @step_order [:s1, :s2, :s3, :s4, :s5]

  @step_labels %{
    s1: "S1  §7.1.7.1",
    s2: "S2  §8.3 step 1",
    s3: "S3  §8.3.1 step 1a",
    s4: "S4  §7.1.11",
    s5: "S5  §8.3 step 6"
  }

  # The never-run list, PRD-001 §3 step 2's "and which did NOT". Rendered in
  # full in the honesty footer, referenced by tag on every leg.
  @never_run_line_1 "N1 signatures     N2 key discovery   N3 revocation"
  @never_run_line_2 "N4 bodySha256     N5 live notary"

  # aph-ex's own warning about the op this gate leans on hardest, quoted from
  # ../aph/interpreters/elixir/lib/aph.ex (the @doc on verify_proof_structure/1)
  # and re-wrapped to this transcript's width. It is the ONLY place in the
  # whole transcript where either of the two bare words this repo's honesty
  # contract forbids may appear — and it appears inside a sentence written to
  # forbid it. The transcript test pins exactly that.
  @aph_ex_quote """
      "A successful return says the structure is sound. It says NOTHING
       about whether any signature verifies — a caller that reports "the
       human signed this" on the strength of this function alone is
       reporting a claim no key has backed."\
  """

  @doc """
  The guard's fixed verdict wording under the demo's mode policy.
  """
  @spec verdict() :: String.t()
  def verdict, do: @verdict

  @doc """
  The aph-ex warning as it appears in the transcript, byte for byte.

  Exposed so the transcript test can excise it before asserting that the
  bare words "verified" and "signed" appear nowhere else in the run.
  """
  @spec aph_ex_quote() :: String.t()
  def aph_ex_quote, do: @aph_ex_quote

  @doc """
  Runs the whole demo and returns the transcript plus any deviations.

  `:deviations` is empty when every leg did what it said it would. A
  non-empty list means the transcript describes something other than the
  demo this repo claims to ship, and the caller must fail.
  """
  @spec run() :: %{transcript: String.t(), deviations: [String.t()]}
  def run do
    token = LogCapture.install(self())

    try do
      build()
    after
      LogCapture.uninstall(token)
    end
  end

  # ----------------------------------------------------------------------
  # Transcript assembly
  # ----------------------------------------------------------------------

  defp build do
    corpus = read_corpus()

    {leg_blocks, deviations} =
      [
        &leg_happy_path/1,
        &leg_missing_extension/1,
        &leg_forged_label/1,
        &leg_mode_absent/1,
        &leg_unknown_field/1,
        &leg_oversize/1,
        &leg_pass_through/1
      ]
      |> Enum.map_reduce([], fn leg, acc ->
        {lines, devs} = leg.(corpus)
        {lines, acc ++ devs}
      end)

    lines =
      List.flatten([
        title(),
        provenance(corpus),
        gate_vocabulary(),
        leg_blocks,
        footer(corpus)
      ])

    %{transcript: Enum.join(lines, "\n") <> "\n", deviations: deviations}
  end

  # Reads every fixture ONCE, up front, so the banner and the legs provably
  # talk about the same bytes. Envelopes are held as JSON TEXT; the decoded
  # maps exist only to quote a fixture's own claims in the banner and to
  # derive tampered variants — never on the trust path.
  defp read_corpus do
    envelope = Demo.Corpus.example!(@envelope_file)
    body = Demo.Corpus.example!(@body_file)
    mode_absent = Demo.Corpus.example!(@mode_absent_file)

    %{
      envelope: envelope,
      envelope_map: JSON.decode!(envelope),
      body: body,
      mode_absent: mode_absent,
      mode_absent_map: JSON.decode!(mode_absent)
    }
  end

  defp title do
    [
      rule("="),
      "jido_aph — mix demo.run",
      "",
      "An APH-notarized signal crossing two jido agents, and a gate that refuses to",
      "act without one. Read the honesty footer at the bottom before quoting",
      "anything from the middle.",
      rule("=")
    ]
  end

  # ----------------------------------------------------------------------
  # [1] Provenance
  # ----------------------------------------------------------------------

  defp provenance(corpus) do
    env = corpus.envelope_map
    subject = env["credentialSubject"]
    communication = subject["communication"]
    policy = subject["policy"]

    {head, worktree, examples} = git_provenance()

    section("1", "PROVENANCE — the exact bytes every claim below rests on") ++
      [
        "Nothing here is vendored. The fixtures are read at runtime from a real aph",
        "checkout (PRD-001 D7) — by default the pinned `:aph` dependency, whose git",
        "`subdir:` brings the whole repository into deps/, examples/ included. The",
        "SHA below is what attributes every claim in this transcript to bytes a",
        "reader can fetch for themselves.",
        "",
        kv("corpus source", "the :aph dependency's checkout, resolved at"),
        kv("", "runtime (APH_PATH, or an explicit"),
        kv("", ":aph_repo_path, override it)"),
        kv("aph HEAD", head),
        kv("aph worktree", worktree),
        kv("aph examples/", examples),
        "",
        kv("clock (S5 judges", Demo.Corpus.pinned_now() <> "  — PINNED"),
        kv("the window against)", ""),
        "",
        "  The clock is pinned, and saying so is the point. The golden's window is",
        "  #{env["validFrom"]} .. #{env["validUntil"]}, which has passed — as has",
        "  every published example's. Against the wall clock the gate refuses this",
        "  fixture at S5, correctly, and there would be no happy path to show. The",
        "  demo pins an instant INSIDE the window rather than switching the check",
        "  off, because a demo that disabled the gate to reach a green result would",
        "  be demonstrating a configuration nobody should ship.",
        "",
        "  That SHA is READ from the checkout, not asserted against a pin. mix.exs",
        "  does pin the dependency by ref, but this banner reports what it FOUND —",
        "  an APH_PATH working tree would print its own SHA here. Failing the build",
        "  on fixture drift is CI's job (PRD-001 T15); the demo's job is to say",
        "  which bytes it actually ran on.",
        "",
        kv("golden envelope", "examples/" <> @envelope_file),
        kv("  bytes", "#{byte_size(corpus.envelope)}"),
        kv("  id", env["id"]),
        kv("  aphVersion", env["aphVersion"]),
        kv("  channel.kind", "#{subject["channel"]["kind"]}  (closed vocabulary, §7.1.5)"),
        kv("  contentClass", "#{communication["contentClass"]}  (closed vocabulary, §7.1.6)"),
        kv("  attestationMode", "#{policy["attestationMode"]}  (§7.1.7)"),
        kv("  proof", proof_shape(env["proof"])),
        kv("  validFrom", env["validFrom"]),
        kv("  validUntil", env["validUntil"]),
        "",
        kv("authorized body", "examples/" <> @body_file),
        kv("  bytes on disk", "#{byte_size(corpus.body)}"),
        kv("  envelope claims", "bodySize #{communication["bodySize"]}"),
        kv("  envelope claims", "bodySha256"),
        "      " <> communication["bodySha256"],
        "",
        "  Read those last two lines exactly as written: they are the ENVELOPE's own",
        "  words, quoted. bodySize is compared against the bytes on disk and agrees.",
        "  bodySha256 is NOT recomputed — not here, and not in any leg below. No",
        "  cryptography runs on the BEAM in this demo, and PRD-001 §5 counts hashing",
        "  as cryptography.",
        "",
        kv("mode-absent fixture", "examples/" <> @mode_absent_file),
        kv("  bytes", "#{byte_size(corpus.mode_absent)}"),
        kv("  policy", "carries NO attestationMode key"),
        "",
        "  An absent attestationMode normatively means NotaryAttested (§7.1.7), so a",
        "  PrincipalSigned policy must refuse it rather than quietly accept whatever",
        "  the envelope happens to offer. Leg [6] is that refusal; leg [5] forges a",
        "  PrincipalSigned label onto this same fixture."
      ]
  end

  defp proof_shape(proof) when is_list(proof), do: "#{length(proof)}-element chain"
  defp proof_shape(_proof), do: "single object"

  # Provenance is read from the clone with `git -C` at runtime. A clone
  # without git metadata, or a dirty worktree, is REPORTED rather than
  # papered over: a transcript that claims a SHA it cannot show is worse than
  # one that admits it does not have one.
  defp git_provenance do
    repo = Demo.Corpus.repo_path!()

    head =
      case git(repo, ["rev-parse", "HEAD"]) do
        {:ok, sha} -> sha
        {:error, why} -> "unavailable (#{why}) — provenance unverifiable"
      end

    {head, dirt_report(repo, ["."], "clean at HEAD"), dirt_report(repo, ["examples"], "clean")}
  end

  defp dirt_report(repo, paths, clean_label) do
    case git(repo, ["status", "--porcelain", "--"] ++ paths) do
      {:ok, ""} ->
        clean_label

      {:ok, output} ->
        n = output |> String.split("\n", trim: true) |> length()
        "DIRTY — #{n} path(s) differ from HEAD; the bytes below may not match the SHA"

      {:error, why} ->
        "unavailable (#{why})"
    end
  end

  defp git(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, code} -> {:error, "git exited #{code}"}
    end
  rescue
    e in ErlangError -> {:error, "git not runnable: #{inspect(e.original)}"}
  end

  # ----------------------------------------------------------------------
  # [2] The gate vocabulary every leg below refers to
  # ----------------------------------------------------------------------

  defp gate_vocabulary do
    section("2", "THE GATE — what JidoAph.Guard runs, in this order, before routing") ++
      [
        "S1  §7.1.7.1        envelope byte bound (#{JidoAph.Guard.max_envelope_bytes()} B),",
        "                    enforced BEFORE any parse",
        "S2  §8.3 step 1     APH.parse_envelope_json/1 — strict parse, with",
        "                    unknown fields denied",
        "S3  §8.3.1 step 1a  APH.require_attestation_mode/2 — only when a mode",
        "                    policy is configured (APH_E012)",
        "S4  §7.1.11         APH.verify_proof_structure/1 — ALWAYS, even with",
        "                    no mode policy, because S3 alone admits a forged",
        "                    label (APH_E013)",
        "S5  §8.3 step 6     the validity window, 60s skew, against the clock",
        "                    named in the banner. A DateTime comparison, not a",
        "                    cipher — which is why its absence until 2026-08-28",
        "                    was never covered by \"no cryptography on the BEAM\"",
        "",
        "And the six things no leg below runs, at any depth, ever:",
        "",
        "N1  Ed25519 signatures over JCS/RFC 8785 (§8.3)",
        "N2  key discovery — DNS TXT / did:web (§8.4)",
        "N3  revocation / credentialStatus",
        "N4  bodySha256 over the received bytes (§8.3 step 8, APH_E009)",
        "N5  the live notary — never contacted, by anything, at any point",
        "",
        "Each leg names, from what actually happened, which of S1-S4 RAN, which one",
        "REFUSED, and which were NEVER REACHED. N1-N6 are constant: they are what",
        "this whole rail does not do.",
        "",
        "Lines marked `log [level]` are verbatim Logger output from JidoAph.Guard",
        "and Demo.Actions.DeliverReply, routed into this narrative so they appear",
        "inside the leg that produced them. jido's AgentServer emits its own [error]",
        "line for a refused prepare_signal hook after it has already replied to the",
        "caller; that line is real, and it is not reproduced here."
      ]
  end

  # ----------------------------------------------------------------------
  # [3] Leg 1 — the happy path, Scribe to Gateway
  # ----------------------------------------------------------------------

  defp leg_happy_path(corpus) do
    outcome = drive_scribe_to_gateway()

    setup = [
      "Scribe reads examples/#{@envelope_file} — #{byte_size(corpus.envelope)} bytes of",
      "verbatim JSON text — and examples/#{@body_file}, the #{byte_size(corpus.body)}",
      "authorized body bytes. It attaches both to a \"slack.reply.requested\" signal",
      "with JidoAph.attach_notarization/3 — envelope as text, body as base64 — and",
      "hands the signal to Gateway with Jido.AgentServer.call/2.",
      "",
      "Gateway mounts JidoAph.Guard as required: true, require_mode:",
      "\"PrincipalSigned\", signal_patterns: [\"slack.reply.requested\"].",
      "",
      "The envelope is a PRE-MINTED committed golden. Presenting it asserts nothing",
      "about this run: nothing here was minted, and no human authorized anything."
    ]

    facts = context_facts(outcome.context)

    cross =
      cross_check(
        "APH.verify_proof_structure/1 on the same bytes",
        APH.verify_proof_structure(corpus.envelope),
        {:ok, "PrincipalSigned"}
      )

    render_leg(
      "3",
      "LEG 1 — HAPPY PATH: the golden envelope crosses two agents",
      setup,
      outcome,
      %{kind: :admitted},
      facts ++ cross.lines,
      cross.deviations
    )
  end

  defp context_facts(nil),
    do: [kv("context.aph", "ABSENT — the routed action never reported")]

  defp context_facts(ctx) do
    claims = Map.get(ctx, :claims) || %{}

    [
      "  context.aph, as the routed action received it:",
      "      verdict",
      "          " <> inspect(Map.get(ctx, :verdict)),
      "      structure_mode  " <> inspect(Map.get(ctx, :structure_mode)),
      "      require_mode    " <> inspect(Map.get(ctx, :require_mode)),
      "      depth           " <> inspect(Map.get(ctx, :depth)),
      "      claims          the envelope's own UNVERIFIED claims,",
      "                      read after the gate, compared against nothing:",
      "          envelope_id         " <> inspect(Map.get(claims, :envelope_id)),
      "          human_principal_did",
      "              " <> inspect(Map.get(claims, :human_principal_did)),
      "          agent_did           " <> inspect(Map.get(claims, :agent_did)),
      "          channel_kind        " <> inspect(Map.get(claims, :channel_kind)),
      "",
      "  `structure_mode` is the mode the proof STRUCTURE supports; `require_mode`",
      "  is the policy that was configured. They agree here, and the guard reports",
      "  them separately on purpose — a verdict that conflated them would be",
      "  claiming the envelope PROVED the policy rather than merely matching it.",
      "  `depth: :structural` states what this gate RAN, never what a config",
      "  declared.",
      "",
      "  `claims` is what the DOCUMENT asserts about itself, decoded from the",
      "  bytes aph-ex normalized and compared against nothing at all: no clock,",
      "  no delivery context, no key, nothing previously seen. N1-N6 below hold",
      "  over every one of these four strings. They are reported anyway, and",
      "  under their own key, because the alternative shipped for a while and",
      "  was worse — with the guard silent about who the envelope names, an",
      "  action that wants the principal's DID digs it out of the signal and",
      "  labels it nothing."
    ]
  end

  # ----------------------------------------------------------------------
  # [4]-[8] The refusal matrix, five refused rows
  # ----------------------------------------------------------------------

  defp leg_missing_extension(_corpus) do
    outcome = drive(Demo.Agents.Gateway, bare_signal())

    setup = [
      "A \"slack.reply.requested\" signal with no notarization extension at all —",
      "the ordinary case of an agent that simply does not speak APH.",
      "",
      "This is the a2a-extension.md §5 step 5 mirror: where the extension is absent",
      "and the recipient's deployment policy REQUIRES APH, \"the endpoint REJECTS",
      "messages from the agent and SHOULD log the rejection for audit\" — both",
      "halves, the rejection and the log line, are visible in this block."
    ]

    render_leg(
      "4",
      "LEG 2 — REFUSAL 1/6: no notarization extension, required: true",
      setup,
      outcome,
      %{kind: :refused, code: :none, refused_at: nil},
      [
        "",
        "  No envelope existed, so no gate step ran and no APH_E code is claimed:",
        "  the taxonomy codes belong to protocol rules, and a document that was",
        "  never presented reached none of them."
      ],
      []
    )
  end

  defp leg_forged_label(corpus) do
    forged =
      corpus.mode_absent_map
      |> put_in(["credentialSubject", "policy", "attestationMode"], "PrincipalSigned")
      |> JSON.encode!()

    outcome = drive(Demo.Agents.Gateway, notarized_signal(forged))
    admits = APH.require_attestation_mode(forged, "PrincipalSigned")

    setup = [
      "Derived in memory, on this run: examples/#{@mode_absent_file} with a",
      "\"PrincipalSigned\" attestationMode written over its policy. Its proof is a",
      "single object, which cannot carry that label — §7.1.11 requires the label",
      "and the structure to agree in BOTH directions.",
      "",
      "This is the forgery a mode gate ALONE waves through: on these exact bytes",
      "APH.require_attestation_mode/2 answers :ok, because the label does say what",
      "the policy asked for. Only S4 catches the lie, which is why the guard runs",
      "S4 unconditionally.",
      "",
      "Nothing derived here is ever written to disk; the committed fixtures are",
      "never edited (PRD-001 §10 gate 4)."
    ]

    mode_gate_lines = [
      "",
      kv("S3 on these bytes", inspect(admits) <> "   <- admitted the forgery"),
      kv("S4 on these bytes", "refused, above")
    ]

    mode_gate_devs =
      if admits == :ok,
        do: [],
        else: [
          "leg 5: APH.require_attestation_mode/2 did not admit the forged label " <>
            "(#{inspect(admits)}); the mandatory admission-then-catch beat no longer holds"
        ]

    cross =
      cross_check(
        "APH.verify_proof_structure/1 on the same bytes",
        APH.verify_proof_structure(forged),
        {:error, refusal_reason(outcome)}
      )

    render_leg(
      "5",
      "LEG 3 — REFUSAL 2/6: a forged PrincipalSigned label (APH_E013)",
      setup,
      outcome,
      %{kind: :refused, code: "APH_E013", refused_at: :s4},
      mode_gate_lines ++ cross.lines,
      mode_gate_devs ++ cross.deviations
    )
  end

  defp leg_mode_absent(corpus) do
    outcome = drive(Demo.Agents.Gateway, notarized_signal(corpus.mode_absent))
    structure = APH.verify_proof_structure(corpus.mode_absent)
    policy = corpus.mode_absent_map["credentialSubject"]["policy"]

    setup = [
      "examples/#{@mode_absent_file}, untampered. Its policy carries no",
      "attestationMode key at all, and an absent mode normatively means",
      "NotaryAttested (§7.1.7) — weaker than the configured PrincipalSigned",
      "policy, so §8.3.1 step 1a refuses it up front instead of silently",
      "downgrading to whatever the envelope offers.",
      "",
      "Its structure is sound, so the refusal is the mode policy and nothing else."
    ]

    structure_lines = [
      "",
      kv("S4 on these bytes", inspect(structure) <> "   <- the structure is sound"),
      kv("policy.decision", inspect(policy["decision"])),
      "",
      "  That decision field records the human's STANDING CONFIGURATION — the",
      "  policy mode they chose for this channel — and is never the verdict on this",
      "  act. §7.1.7 is explicit that it \"Records the human's standing",
      "  configuration, NOT the verdict on this act\", the verdict being carried by",
      "  the state the envelope was issued from, so an AskEveryTime envelope",
      "  truthfully carries AskEveryTime after the human said yes.",
      "  \"Implementations that read this field as a per-act decision have shipped",
      "  real defects; do not.\" Nothing in this repo reads it as one: the guard",
      "  never looks at decision, and this refusal is about attestationMode alone."
    ]

    structure_devs =
      if structure == {:ok, "NotaryAttested"},
        do: [],
        else: [
          "leg 6: APH.verify_proof_structure/1 on the mode-absent fixture returned " <>
            "#{inspect(structure)}, so this leg can no longer claim the refusal is " <>
            "the mode gate alone"
        ]

    cross =
      cross_check(
        "APH.require_attestation_mode/2 on the same bytes",
        APH.require_attestation_mode(corpus.mode_absent, "PrincipalSigned"),
        {:error, refusal_reason(outcome)}
      )

    render_leg(
      "6",
      "LEG 4 — REFUSAL 3/6: mode-absent vs a PrincipalSigned policy (APH_E012)",
      setup,
      outcome,
      %{kind: :refused, code: "APH_E012", refused_at: :s3},
      structure_lines ++ cross.lines,
      structure_devs ++ cross.deviations
    )
  end

  defp leg_unknown_field(corpus) do
    tampered =
      corpus.envelope_map
      |> Map.put("jidoAphUnknownField", true)
      |> JSON.encode!()

    outcome = drive(Demo.Agents.Gateway, notarized_signal(tampered))

    setup = [
      "Derived in memory, on this run: the golden with one extra top-level field,",
      "\"jidoAphUnknownField\". §8.3 step 1 parses STRICTLY, with unknown fields",
      "denied, so a key the protocol never defined is a hard refusal rather than a",
      "silently dropped one.",
      "",
      "The refusal carries the parser's own message and no APH_E code — a document",
      "that never parsed reached no protocol rule and may cite none."
    ]

    cross =
      cross_check(
        "APH.parse_envelope_json/1 on the same bytes",
        APH.parse_envelope_json(tampered),
        {:error, refusal_reason(outcome)}
      )

    render_leg(
      "7",
      "LEG 5 — REFUSAL 4/6: an unknown envelope field (strict parse, no code)",
      setup,
      outcome,
      %{kind: :refused, code: :none, refused_at: :s2},
      cross.lines,
      cross.deviations
    )
  end

  defp leg_oversize(corpus) do
    padded = corpus.envelope <> String.duplicate(" ", 70_000)
    outcome = drive(Demo.Agents.Gateway, notarized_signal(padded))
    parse = APH.parse_envelope_json(padded)

    setup = [
      "Derived in memory, on this run: the golden followed by 70,000 spaces —",
      "#{byte_size(padded)} bytes against the #{JidoAph.Guard.max_envelope_bytes()}-byte bound of §7.1.7.1.",
      "",
      "The bound exists because canonicalization happens on UNAUTHENTICATED input,",
      "so it has to be enforced before a parser ever sees the bytes. That ordering",
      "is provable from outside the guard: trailing whitespace is legal JSON, so",
      "the strict parser ADMITS these very bytes."
    ]

    parse_lines = [
      "",
      kv("S2 on these bytes", parse_summary(parse)),
      kv("", "^ the parser would take them, so the refusal"),
      kv("", "  above can only be the byte bound")
    ]

    parse_devs =
      case parse do
        {:ok, _} ->
          []

        other ->
          [
            "leg 8: APH.parse_envelope_json/1 refused the padded bytes " <>
              "(#{inspect(other)}), so this leg can no longer prove the size gate " <>
              "runs before the parse"
          ]
      end

    render_leg(
      "8",
      "LEG 6 — REFUSAL 5/6: over the byte bound, refused before any parse",
      setup,
      outcome,
      %{kind: :refused, code: :none, refused_at: :s1},
      parse_lines,
      parse_devs
    )
  end

  defp parse_summary({:ok, _}), do: "{:ok, <canonical JSON text>}"
  defp parse_summary(other), do: inspect(other)

  # ----------------------------------------------------------------------
  # [9] Leg 7 — the pass-through row
  # ----------------------------------------------------------------------

  defp leg_pass_through(_corpus) do
    outcome = drive(PassThroughGateway, bare_signal())
    expected_tag = %{notarization: :absent, tag: :unverified}

    setup = [
      "The same bare signal as leg [4], sent to a gateway identical to Gateway in",
      "every respect but one: required: false.",
      "",
      "This is the other half of the a2a-extension.md §5 mirror — step 6, the",
      "permissive deployment that \"MAY display a 'Not notarized' UI indicator and",
      "proceed to deliver the message under the recipient's existing trust rules\".",
      "Delivery happens; it happens FLAGGED."
    ]

    facts =
      case outcome.context do
        nil ->
          [kv("context.aph", "ABSENT — the routed action never reported")]

        ctx ->
          [
            # Rendered field by field rather than with inspect/1: Erlang orders
            # small-map keys by atom-table term order, not alphabetically, so
            # `inspect/1` on this two-key map is not stable across VMs and would
            # make the committed transcript churn for no reason.
            kv(
              "context.aph",
              "%{notarization: #{inspect(Map.get(ctx, :notarization))}, " <>
                "tag: #{inspect(Map.get(ctx, :tag))}}"
            ),
            "",
            "  Note what is not there: no verdict, no \"notarization-shaped\", no mode.",
            "  Nothing was examined, so nothing is claimed. The tag rides the RUNTIME",
            "  CONTEXT the receiving guard authored, never the signal — a wire-borne",
            "  tag would be sender-suppliable, and is silently stripped on any VM",
            "  where the extension namespace is unregistered."
          ]
      end

    devs =
      if outcome.context == expected_tag,
        do: [],
        else: [
          "leg 9: expected context.aph == #{inspect(expected_tag)}, " <>
            "got #{inspect(outcome.context)}"
        ]

    render_leg(
      "9",
      "LEG 7 — ROW 6/6: a bare signal under required: false, delivered tagged",
      setup,
      outcome,
      %{kind: :passed_through},
      facts,
      devs
    )
  end

  # ----------------------------------------------------------------------
  # [10] Honesty footer
  # ----------------------------------------------------------------------

  defp footer(corpus) do
    env = corpus.envelope_map
    communication = env["credentialSubject"]["communication"]

    section("10", "HONESTY FOOTER — what this run did not establish") ++
      [
        "Seven signals were gated. One was admitted, five were refused, one was",
        "passed through and tagged. The admission means exactly three things: the",
        "envelope PARSED strictly, its declared attestation mode satisfied the",
        "configured policy without downgrade, and its proof STRUCTURE matched that",
        "label in both directions.",
        "",
        "Here is what it does not mean — about any envelope above, the admitted one",
        "included:",
        "",
        "  N1  No Ed25519 signature was checked. Not the principal's, not the",
        "      notary's, not the two on the embedded delegation mandate. Zero",
        "      cryptography ran on the BEAM (§8.3).",
        "  N2  No key was discovered or resolved: no DNS TXT lookup, no did:web",
        "      fetch, no did:key decode. Nothing on this rail resolves anything",
        "      (§8.4).",
        "  N3  Revocation was never consulted. The golden carries no",
        "      credentialStatus, and no status transport exists in this repo.",
        "  N4  bodySha256 was never recomputed over the #{byte_size(corpus.body)} received bytes. The",
        "      digest quoted in the banner",
        "      (#{communication["bodySha256"]})",
        "      is the envelope's own claim (§8.3 step 8, APH_E009).",
        "  N5  The live notary at did:web:aph-notary.squillo.com was not contacted,",
        "      by anything, at any point. Nothing above reached the network at all.",
        "",
        "  The closed channel and contentClass vocabularies LEFT this list too, and",
        "  for a better reason than the window did: upstream made those sets the",
        "  field TYPES (aph 57431e6), so an envelope naming a channel outside them",
        "  cannot be constructed and S2 refuses it at parse. No op is called and no",
        "  code here enforces it — the guard gained the check by moving its pin.",
        "",
        "  The validity window IS checked, and used not to be — which is why it is",
        "  no longer on this list. Until 2026-08-28 the gate had no window check at",
        "  all, and this demo's happy path admitted a golden that expired",
        "  #{env["validUntil"]}. That check is now S5, it runs by default, and the",
        "  clock it judges against is stated in the banner above rather than",
        "  assumed. Every published example is past its own window today, so the",
        "  demo pins the clock inside the golden's; against the wall clock this",
        "  leg would refuse, and `mix demo.deep_verify` shows exactly that.",
        "",
        "aph-ex says it plainly of the one structural op this gate leans on hardest",
        "(../aph/interpreters/elixir/lib/aph.ex, verify_proof_structure/1):",
        "",
        @aph_ex_quote,
        "",
        "That is the whole reason the verdict reads \"notarization-shaped, mode",
        "policy satisfied\" and never a word stronger, and the reason the guard's own",
        "log lines above are checked by test for those two bare words.",
        "",
        "Cryptographic depth is a different leg, in a second and independent",
        "implementation, and it is not this one:",
        "",
        "    mix demo.deep_verify        (optional, Node >= 20)",
        "",
        rule("=")
      ]
  end

  # ----------------------------------------------------------------------
  # Driving the real agents
  # ----------------------------------------------------------------------

  # Starts one agent, sends it one signal, collects everything that leg
  # produced, stops the agent. Ids are unique per leg so repeated runs in one
  # VM never collide in the instance registry.
  defp drive(agent_module, signal) do
    pid = start_agent!(agent_module)

    try do
      collect(AgentServer.call(pid, signal))
    after
      Demo.Jido.stop_agent(pid)
    end
  end

  # The happy path is the two-agent story, so it runs through Scribe exactly
  # as a reader would drive it: Scribe's action loads the golden, attaches it,
  # and calls Gateway.
  defp drive_scribe_to_gateway do
    gateway = start_agent!(Demo.Agents.Gateway)
    scribe = start_agent!(Demo.Agents.Scribe)

    try do
      signal = Signal.new!("scribe.reply.requested", %{gateway: gateway, reply_to: self()})
      collect(AgentServer.call(scribe, signal))
    after
      Demo.Jido.stop_agent(scribe)
      Demo.Jido.stop_agent(gateway)
    end
  end

  defp start_agent!(agent_module) do
    {:ok, pid} =
      Demo.Jido.start_agent(agent_module,
        id: "#{inspect(agent_module)}-#{System.unique_integer([:positive])}"
      )

    pid
  end

  defp collect(result) do
    events = LogCapture.drain()

    action =
      Enum.find_value(events, fn
        {:action, params, context} -> {params, context}
        _ -> nil
      end)

    %{
      result: result,
      logs: for({:log, level, message} <- events, do: {level, message}),
      action_ran?: action != nil,
      context: action && Map.get(elem(action, 1), :aph)
    }
  end

  defp bare_signal, do: Signal.new!("slack.reply.requested", %{reply_to: self()})

  defp notarized_signal(envelope_json) do
    signal = Signal.new!("slack.reply.requested", %{reply_to: self()})
    {:ok, signal} = JidoAph.attach_notarization(signal, envelope_json)
    signal
  end

  # ----------------------------------------------------------------------
  # Rendering one leg, and checking it against what it claimed it would do
  # ----------------------------------------------------------------------

  defp render_leg(index, title, setup, outcome, expected, extra_facts, extra_deviations) do
    kind = outcome_kind(outcome)
    {ran, refused_at, not_reached} = attribute_steps(kind)

    lines =
      section(index, title) ++
        setup ++
        [""] ++
        log_lines(outcome) ++
        [""] ++
        outcome_lines(outcome, kind) ++
        extra_facts ++
        [""] ++
        step_lines(ran, refused_at, not_reached)

    {lines, check(index, kind, refused_at, outcome, expected) ++ extra_deviations}
  end

  defp log_lines(%{logs: []}), do: ["  (this leg emitted no log line of its own)"]

  # Log messages are reproduced verbatim, soft-wrapped on existing spaces to
  # this transcript's width with a hanging indent. On a real console each of
  # these is one line; nothing but line breaks is added.
  defp log_lines(%{logs: logs}) do
    Enum.flat_map(logs, fn {level, message} ->
      wrap(message, "  log [#{level}] ", "                ")
    end)
  end

  defp outcome_lines(outcome, :admitted) do
    [
      kv("outcome", "ADMITTED — call/2 returned {:ok, %Jido.Agent{}}"),
      kv("routed action", ran_label(outcome))
    ]
  end

  defp outcome_lines(outcome, :passed_through) do
    [
      kv("outcome", "PASSED THROUGH, TAGGED — nothing was examined"),
      kv("routed action", ran_label(outcome))
    ]
  end

  defp outcome_lines(outcome, {:refused, reason}) do
    [
      kv("outcome", "REFUSED before routing"),
      kv("routed action", ran_label(outcome)),
      "  reason, verbatim, as Jido.AgentServer.call/2 handed it back:"
    ] ++ wrap_reason(reason)
  end

  defp outcome_lines(outcome, {:unexpected, result}) do
    [
      kv("outcome", "UNEXPECTED — the demo did not behave as this leg claims"),
      kv("call returned", inspect(result, limit: :infinity)),
      kv("routed action", ran_label(outcome))
    ]
  end

  defp ran_label(%{action_ran?: true}), do: "Demo.Actions.DeliverReply RAN"
  defp ran_label(%{action_ran?: false}), do: "Demo.Actions.DeliverReply did NOT run"

  defp wrap_reason(reason), do: wrap(reason, "      ", "      ")

  # Soft-wraps text on existing spaces only — no hyphenation, no re-flowing
  # inside a word — so every byte the guard produced survives into the
  # transcript, and only line breaks are added.
  defp wrap(text, first_prefix, cont_prefix) do
    limit = @width - String.length(cont_prefix)

    text
    |> String.split(" ")
    |> Enum.reduce([""], fn word, [current | rest] ->
      candidate = if current == "", do: word, else: current <> " " <> word

      if String.length(candidate) > limit and current != "" do
        [word, current | rest]
      else
        [candidate | rest]
      end
    end)
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn
      {line, 0} -> first_prefix <> line
      {line, _} -> cont_prefix <> line
    end)
  end

  defp outcome_kind(%{result: {:ok, %Jido.Agent{}}, context: %{tag: :unverified}}),
    do: :passed_through

  defp outcome_kind(%{result: {:ok, %Jido.Agent{}}}), do: :admitted

  defp outcome_kind(%{
         result:
           {:error,
            %Jido.Error.ExecutionError{
              message: "Plugin prepare_signal failed",
              details: %{plugin: JidoAph.Guard, reason: reason}
            }}
       }),
       do: {:refused, reason}

  defp outcome_kind(%{result: result}), do: {:unexpected, result}

  defp refusal_reason(outcome) do
    case outcome_kind(outcome) do
      {:refused, reason} -> reason
      other -> {:no_refusal, other}
    end
  end

  # Which of S1-S4 ran is DERIVED from the guard's own message, never
  # scripted: the gate short-circuits, so the message identifies the step
  # that stopped it and therefore the steps that preceded it.
  defp attribute_steps(:admitted), do: {@step_order, nil, []}
  defp attribute_steps(:passed_through), do: {[], nil, @step_order}
  defp attribute_steps({:unexpected, _}), do: {[], nil, []}

  defp attribute_steps({:refused, reason}) do
    cond do
      String.contains?(reason, "notarization extension missing") -> {[], nil, @step_order}
      String.contains?(reason, "refused before any parse") -> {[], :s1, [:s2, :s3, :s4]}
      String.starts_with?(reason, "APH_E012") -> {[:s1, :s2], :s3, [:s4]}
      String.starts_with?(reason, "APH_E013") -> {[:s1, :s2, :s3], :s4, []}
      true -> {[:s1], :s2, [:s3, :s4]}
    end
  end

  defp step_lines(ran, refused_at, not_reached) do
    statuses =
      Enum.map(@step_order, fn step ->
        status =
          cond do
            step in ran -> "RAN"
            step == refused_at -> "REFUSED  <- the leg stops here"
            step in not_reached -> "NOT REACHED"
            true -> "not attributable"
          end

        "      " <> String.pad_trailing(@step_labels[step], 20) <> status
      end)

    ["  gate steps, this leg:"] ++
      statuses ++
      [
        "  never run, this or any leg:",
        "      " <> @never_run_line_1,
        "      " <> @never_run_line_2
      ]
  end

  # Each leg declares what it expects; this compares the expectation against
  # what really happened and turns any gap into a deviation the task exits
  # non-zero on. A narrative that renders a story the run did not produce is
  # the one failure mode this task must never have.
  defp check(index, kind, refused_at, outcome, expected) do
    case {kind, expected} do
      {:admitted, %{kind: :admitted}} ->
        action_must_have_run(index, outcome, "admitted")

      {:passed_through, %{kind: :passed_through}} ->
        action_must_have_run(index, outcome, "passed through")

      {{:refused, reason}, %{kind: :refused} = exp} ->
        refusal_checks(index, reason, refused_at, outcome, exp)

      {actual, exp} ->
        ["leg #{index}: expected #{inspect(exp.kind)}, got #{inspect(actual)}"]
    end
  end

  defp action_must_have_run(_index, %{action_ran?: true}, _label), do: []

  defp action_must_have_run(index, %{action_ran?: false}, label),
    do: ["leg #{index}: #{label}, but Demo.Actions.DeliverReply did not run"]

  defp refusal_checks(index, reason, refused_at, outcome, expected) do
    code_dev =
      case expected.code do
        :none ->
          if String.contains?(reason, "APH_E"),
            do: ["leg #{index}: refusal claims an APH_E code it did not earn: #{reason}"],
            else: []

        code ->
          if String.starts_with?(reason, code),
            do: [],
            else: ["leg #{index}: expected a #{code} refusal, got: #{reason}"]
      end

    step_dev =
      if refused_at == expected.refused_at,
        do: [],
        else: [
          "leg #{index}: expected the refusal at #{inspect(expected.refused_at)}, " <>
            "attributed it to #{inspect(refused_at)}"
        ]

    action_dev =
      if outcome.action_ran?,
        do: ["leg #{index}: refused, yet Demo.Actions.DeliverReply RAN"],
        else: []

    code_dev ++ step_dev ++ action_dev
  end

  # A cross-check renders the integration claim a unit test cannot make: the
  # aph-ex message the guard passed through is still byte-identical after the
  # framework wrapped it in an ExecutionError.
  defp cross_check(label, actual, expected) do
    if actual == expected do
      %{
        lines: [
          "",
          kv("cross-check", label),
          kv("", "returns this identical result, byte for byte:"),
          kv("", "the guard passed it through untouched, and the"),
          kv("", "framework's error wrapping did not alter it")
        ],
        deviations: []
      }
    else
      %{
        lines: [
          "",
          kv("cross-check FAILED", label),
          kv("  expected", inspect(expected, limit: :infinity)),
          kv("  got", inspect(actual, limit: :infinity))
        ],
        deviations: [
          "cross-check failed for #{label}: expected " <>
            "#{inspect(expected, limit: :infinity)}, got #{inspect(actual, limit: :infinity)}"
        ]
      }
    end
  end

  # ----------------------------------------------------------------------
  # Small rendering helpers
  # ----------------------------------------------------------------------

  defp section(index, title), do: ["", "", "[#{index}] #{title}", rule("-")]

  defp rule(char), do: String.duplicate(char, @width)

  # A label column wide enough for every label used here. A label that
  # outgrows it still gets one separating space rather than running into its
  # value — a silent `"S3 on these bytes:ok"` is the kind of tiny lie a
  # transcript must not tell.
  defp kv(key, value) do
    if String.length(key) < @label_width do
      "  " <> String.pad_trailing(key, @label_width) <> value
    else
      "  " <> key <> " " <> value
    end
  end
end
