defmodule Mix.Tasks.Demo.DeepVerify do
  @shortdoc "Runs the optional deep-verification leg and prints its narrated transcript"

  @moduledoc """
  Runs the optional cryptographic leg of the demo and prints a narrated
  transcript (PRD-001 §3 items 5-8, task T13).

      mix demo.deep_verify
      mix demo.deep_verify --out ../docs/transcripts/demo_deep_verify.txt

  ## What it prints, in order

  1. a **provenance banner** — the sibling clone's HEAD SHA, the node runtime
     and the `dist/` the verdicts below came out of, and the golden fixture's
     identity;
  2. **the pin** — the instant `now` is pinned to, the window it sits inside,
     and why a verifier that read its own clock could not be trusted to tell
     you which instant a verdict rested on;
  3. the **golden verified at that instant**, with every step the borrowed
     verifier ran enumerated by spec clause;
  4. the **key-sourcing story** — one key handed in out of band, one that
     needs none, zero fetched;
  5. the **wall-clock beat** — the same envelope at the real current time,
     refused on the validity window, which is what makes the pin load-bearing
     rather than decorative;
  6. the **depth-split beat** — one runtime-derived envelope, two verdicts:
     admitted by the real `Demo.Agents.Gateway`, refused here;
  7. what this leg **ADDS** over the structural gate, step by step;
  8. what it **STILL does not do**, and then the honesty footer.

  ## Node IS required

  This is the one place in the repository where Node exists (PRD-001 §10 gate
  7). When node or the sibling clone's TypeScript `dist/` is missing, this
  task prints the setup story and exits non-zero **without printing a
  transcript** — a setup gap is never a verdict about an envelope, and a
  transcript with holes in it would read like one.

  ## Exit status

  Zero when every leg did what the transcript says it did. Non-zero, with the
  deviations printed after the transcript, when it did not — and non-zero with
  instructions when the leg could not run at all. Like `mix demo.run`, this
  task is a gate as well as a story, which is why CI can grep its stdout
  (PRD-001 §10 gate 5, in the `:deep` job of T16).

  ## Determinism

  The transcript is byte-identical across runs except in the four places it
  MUST vary, each of which is a fact about this machine and this moment rather
  than about the protocol: the clone's HEAD SHA and worktree cleanliness, the
  node runtime version, and the wall-clock instant of leg [5] (which also
  appears inside that leg's refusal message, because the verifier quotes the
  instant it was handed). No absolute path appears anywhere; the `dist/`
  location is reported relative to the clone the SHA already attributes.

  ## Options

    * `--out PATH` — additionally write the transcript (and only the
      transcript) to `PATH`, creating parent directories as needed. This is
      how `docs/transcripts/demo_deep_verify.txt` is regenerated; run it from
      `demo/`, so the repo-root path is
      `../docs/transcripts/demo_deep_verify.txt`.

    * `--aph-repo PATH` — resolve the sibling clone from `PATH` instead of
      from `config :jido_aph, aph_repo_path`. It exists so the unavailable
      path is testable on a machine where the leg IS available: pointing it at
      a directory with no built `dist/` exercises the degradation this task
      promises. Both the corpus and the verifier come from `PATH` when it is
      given, so a transcript can never describe two different clones.
  """

  use Mix.Task

  alias Demo.DeepVerifier.TsSidecar
  alias Demo.Narrative.LogCapture
  alias Jido.AgentServer
  alias Jido.Signal

  @requirements ["app.start"]

  @width 78
  @label_width 22
  @step_label_width 22

  @envelope_file "principal_signed_envelope.json"
  @body_file "principal_signed_body.txt"

  # The instant every verdict below rests on. Chosen, not read: it is the aph
  # testkit's own GOLDEN_EVALUATION_INSTANT
  # (interpreters/typescript/testkit/golden.ts), which sits inside the golden's
  # 2026-05-21T00:00:00Z .. 2026-05-22T00:00:00Z window — so this demo and its
  # upstream evaluate the same fixture at the same moment.
  @pinned_now "2026-05-21T12:00:00Z"

  @require_mode "PrincipalSigned"

  # The golden's notary verification method: a fixture identifier, never a live
  # service, never contacted. Its key is handed to the verifier as a parameter.
  @notary_method "did:web:notary.squillo.com#key-1"

  # JidoAph.Guard's fixed verdict wording, spelled here so a drift in the guard
  # fails this transcript loudly instead of quietly changing what leg [6]
  # claims the guard said.
  @guard_verdict "notarization-shaped, mode policy satisfied (PrincipalSigned)"

  # The three sentences PRD-001 T13 requires this transcript to state out loud,
  # and which its golden-output test asserts. Each is rendered as a single line
  # so the assertion is on the sentence and not on a wrapping.
  @pin_sentence "`now` is pinned because the window is fixed, not because time is negotiable."
  @depth_split_line "This is why structural validity is never called verification."
  @key_sourcing_line "One key handed in out of band, one that needs none, and zero fetched."

  # The steps the borrowed verifier runs, in the order src/verify.ts really
  # runs them (verifyEnvelope, read at aph f01e347). D1-D4 are the four
  # JidoAph.Guard also runs; D5-D11 are what this leg ADDS.
  @step_order [:d1, :d2, :d3, :d4, :d5, :d6, :d7, :d8, :d9, :d10, :d11]

  @step_labels %{
    d1: "D1   §7.1.7.1",
    d2: "D2   §8.3 step 1",
    d3: "D3   §8.3.1 step 1a",
    d4: "D4   §7.1.11",
    d5: "D5   §8.3 step 1b-1c",
    d6: "D6   §7.2.1 step 1e",
    d7: "D7   §8.3 steps 2-5",
    d8: "D8   §8.3.1 step 1d",
    d9: "D9   §8.3 step 6",
    d10: "D10  §8.3 step 8",
    d11: "D11  §8.3 step 8a"
  }

  @doc """
  The instant the golden is evaluated against, pinned rather than read.
  """
  @spec pinned_now() :: String.t()
  def pinned_now, do: @pinned_now

  @doc """
  The transcript's statement that `now` is a pin, byte for byte.
  """
  @spec pin_sentence() :: String.t()
  def pin_sentence, do: @pin_sentence

  @doc """
  The depth-split sentence — the reason this repository never writes
  "structurally valid" as "verified".
  """
  @spec depth_split_line() :: String.t()
  def depth_split_line, do: @depth_split_line

  @doc """
  The key-sourcing sentence, byte for byte.
  """
  @spec key_sourcing_line() :: String.t()
  def key_sourcing_line, do: @key_sourcing_line

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [out: :string, aph_repo: :string])

    case report(aph_repo_path: opts[:aph_repo]) do
      {:ok, %{transcript: transcript, deviations: deviations}} ->
        IO.write(transcript)
        write_out(opts[:out], transcript)
        report_deviations(deviations)

      {:unavailable, block} ->
        IO.write(block)

        Mix.raise(
          "mix demo.deep_verify: the deep leg is unavailable, so nothing was verified " <>
            "and no transcript was printed; the setup instructions are above"
        )
    end
  end

  @doc """
  Runs the deep leg and returns its transcript, or the unavailability report.

  `{:ok, %{transcript: String.t(), deviations: [String.t()]}}` when the leg
  ran. A non-empty `:deviations` means the transcript describes something
  other than what this run did, and the caller must fail.

  `{:unavailable, String.t()}` when node or the built `dist/` is missing: the
  second element is the rendered setup story, and no envelope was examined.

  Options: `:aph_repo_path`, as `--aph-repo`.
  """
  @spec report(keyword()) ::
          {:ok, %{transcript: String.t(), deviations: [String.t()]}} | {:unavailable, String.t()}
  def report(opts \\ []) do
    repo_override = Keyword.get(opts, :aph_repo_path)

    case TsSidecar.availability(repo_override) do
      :ok -> {:ok, build(repo_override)}
      {:error, %{kind: :unavailable} = error} -> {:unavailable, unavailable_block(error)}
    end
  end

  # ----------------------------------------------------------------------
  # Unavailable
  # ----------------------------------------------------------------------

  defp unavailable_block(error) do
    Enum.join(
      [
        rule("="),
        "jido_aph — mix demo.deep_verify",
        "",
        "DEEP LEG UNAVAILABLE — nothing was verified, and nothing is claimed.",
        rule("="),
        "",
        kv("reason", to_string(error.reason)),
        "",
        error.message,
        "",
        "That is a setup gap, never a verdict about any envelope. Until it is closed",
        "this task prints no transcript at all: a transcript with holes in it reads",
        "like a verdict, and this one would be a verdict nobody earned.",
        "",
        "The core demo needs none of this and is unaffected by it — no Node, no",
        "network, nothing but the BEAM and the sibling clone's fixtures:",
        "",
        "    mix demo.run",
        "",
        "(PRD-001 §10 gate 7: the core pipeline never sees Node. This leg is the",
        "optional one, and its absence must never be read as a failed check.)",
        rule("="),
        ""
      ],
      "\n"
    )
  end

  # ----------------------------------------------------------------------
  # Transcript assembly
  # ----------------------------------------------------------------------

  # Every subprocess run this transcript reports on happens HERE, once, in the
  # order the narrative describes them — so no section can quietly re-run the
  # verifier to make its own prose come true.
  defp build(repo_override) do
    corpus = read_corpus(repo_override)

    pinned = verify(corpus.envelope, @pinned_now, repo_override, corpus.body)

    wall_now = DateTime.utc_now() |> DateTime.to_iso8601()
    wall = verify(corpus.envelope, wall_now, repo_override, corpus.body)

    forged = forge(corpus)
    gate = guard_gate(forged)

    token = LogCapture.install(self())

    gateway =
      try do
        drive_gateway(forged)
      after
        LogCapture.uninstall(token)
      end

    deep = verify(forged, @pinned_now, repo_override, corpus.body)
    control = verify(corpus.envelope, @pinned_now, repo_override, corpus.body)

    legs = [
      leg_pinned(corpus, pinned),
      leg_key_sourcing(pinned),
      leg_wall_clock(corpus, wall_now, wall),
      leg_depth_split(forged, gate, gateway, deep, control)
    ]

    lines =
      List.flatten([
        title(),
        provenance(corpus, pinned),
        the_pin(corpus),
        Enum.map(legs, & &1.lines),
        adds(),
        still_not(corpus),
        footer()
      ])

    %{
      transcript: Enum.join(lines, "\n") <> "\n",
      deviations: Enum.flat_map(legs, & &1.deviations)
    }
  end

  # Every fixture is read ONCE, up front, so the banner and the legs provably
  # talk about the same bytes. Envelopes are held as JSON TEXT and handed to
  # the verifier unparsed; the decoded map exists only to quote the fixture's
  # own claims and to derive the leg [6] forgery in memory.
  defp read_corpus(repo_override) do
    envelope = example!(repo_override, @envelope_file)
    body = example!(repo_override, @body_file)

    %{
      envelope: envelope,
      envelope_map: JSON.decode!(envelope),
      body: body,
      repo: repo_path(repo_override)
    }
  end

  defp example!(nil, name), do: Demo.Corpus.example!(name)

  defp example!(repo, name),
    do: File.read!(Path.join([Path.expand(repo, File.cwd!()), "examples", name]))

  defp repo_path(nil), do: Demo.Corpus.repo_path!()
  defp repo_path(path), do: Path.expand(path, File.cwd!())

  defp title do
    [
      rule("="),
      "jido_aph — mix demo.deep_verify",
      "",
      "The optional second leg. The same golden envelope `mix demo.run` gated",
      "STRUCTURALLY is handed here to an independent implementation of the same",
      "specification — the aph repo's TypeScript verifier, running under node — which",
      "checks every signature. Read [7] and [8] before quoting anything from the",
      "middle: this leg adds a great deal, and there are still three things it does",
      "not do.",
      rule("=")
    ]
  end

  # ----------------------------------------------------------------------
  # [1] Provenance
  # ----------------------------------------------------------------------

  defp provenance(corpus, pinned) do
    env = corpus.envelope_map
    subject = env["credentialSubject"]
    communication = subject["communication"]

    {head, worktree, typescript} = git_provenance(corpus.repo)
    {node_version, dist} = verifier_identity(corpus.repo, pinned)

    section("1", "PROVENANCE — the bytes, and the verifier that ruled on them") ++
      [
        "Nothing here is vendored: neither the fixtures nor the verifier. Both are",
        "read at runtime from a sibling clone of the aph repo (PRD-001 D5/D7), so the",
        "SHA below is what attributes every verdict in this transcript to bytes a",
        "reader can fetch and re-run for themselves.",
        "",
        kv("corpus + verifier", "one sibling aph clone, resolved at runtime"),
        kv("aph HEAD", head),
        kv("aph worktree", worktree),
        kv("aph typescript/", typescript),
        "",
        "  That last line is about SOURCE, and it is worth saying what it does not",
        "  cover: `dist/` is a build artifact, git-ignored upstream, so nothing here",
        "  can prove the built JavaScript was compiled from the source at that SHA.",
        "  Rebuilding it is one command, named in this task's own failure message,",
        "  and CI's :deep job builds it fresh at the pinned SHA (PRD-001 T16).",
        "",
        kv("verifier", "interpreters/typescript, under node"),
        kv("  entry point", "demo/priv/node/verify.mjs"),
        kv("  calls", "dist/src/verify.js  verifyEnvelope (§8.3 + §8.3.1)"),
        kv("  dist", dist),
        kv("  node runtime", node_version),
        "",
        "  The verifier runs in a SUBPROCESS, not on the BEAM. Zero cryptography runs",
        "  on the BEAM anywhere in this repository (PRD-001 §5), and aph-ex — the NIF",
        "  the guard is built on — exposes four structural operations and no signature",
        "  check at all, on purpose and parity-locked.",
        "",
        kv("golden envelope", "examples/" <> @envelope_file),
        kv("  bytes", "#{byte_size(corpus.envelope)}"),
        kv("  id", env["id"]),
        kv("  aphVersion", env["aphVersion"]),
        kv("  channel.kind", "#{subject["channel"]["kind"]}  (closed vocabulary, §7.1.5)"),
        kv("  contentClass", "#{communication["contentClass"]}  (closed vocabulary, §7.1.6)"),
        kv("  attestationMode", "#{subject["policy"]["attestationMode"]}  (§7.1.7)"),
        kv("  proof", "#{length(env["proof"])}-element chain"),
        kv("  mandate", mandate_label(subject["policy"]["delegationMandate"])),
        kv("  credentialStatus", credential_status_label(env)),
        "",
        kv("authorized body", "examples/" <> @body_file),
        kv("  bytes on disk", "#{byte_size(corpus.body)}"),
        kv("  envelope claims", "bodySize #{communication["bodySize"]}"),
        kv("  envelope claims", "bodySha256"),
        "      " <> communication["bodySha256"],
        "",
        "  `mix demo.run` quotes that digest and says plainly that it never recomputes",
        "  it. This leg does recompute it — inside node, over the body bytes as the",
        "  sidecar received them, never over a re-serialization of a parsed object",
        "  (§8.3 step 8). Leg [3] reports whether that check actually ran."
      ]
  end

  defp mandate_label(nil), do: "none embedded"

  defp mandate_label(mandate),
    do: "embedded §6.1 mandate, allowedChannels #{inspect(mandate["allowedChannels"])}"

  defp credential_status_label(env) do
    case Map.get(env, "credentialStatus") do
      nil -> "absent — §6.3.3.4 case 1, SKIP (not a pass)"
      _ -> "PRESENT — this verifier has no status transport"
    end
  end

  # Provenance is read from the clone at runtime with `git -C`. A clone without
  # git metadata, or a dirty worktree, is REPORTED rather than papered over: a
  # transcript that claims a SHA it cannot show is worse than one that admits
  # it does not have one.
  defp git_provenance(repo) do
    head =
      case git(repo, ["rev-parse", "HEAD"]) do
        {:ok, sha} -> sha
        {:error, why} -> "unavailable (#{why}) — provenance unverifiable"
      end

    {head, dirt_report(repo, ["."], "clean at HEAD"),
     dirt_report(repo, ["interpreters/typescript"], "source clean at HEAD")}
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

  # The node version and the dist location are REPORTED BY THE SUBPROCESS
  # ITSELF, on the real verification leg [3] narrates, rather than probed
  # separately: what matters is which runtime produced the verdicts below, not
  # which one happens to be first on PATH. The dist path is rendered relative
  # to the clone — an absolute path would pin this transcript to one machine's
  # home directory without adding a single verifiable fact.
  defp verifier_identity(repo, {:ok, %{verifier: %{runtime: runtime, dist: dist}}}),
    do: {runtime, Path.relative_to(dist, repo) <> "  (inside the clone above)"}

  defp verifier_identity(_repo, _other),
    do: {"unreported — the golden did not verify; see leg [3]", "unreported"}

  # ----------------------------------------------------------------------
  # [2] The pin
  # ----------------------------------------------------------------------

  defp the_pin(corpus) do
    env = corpus.envelope_map

    section("2", "THE PIN — the instant every verdict below rests on") ++
      [
        "The borrowed verifier takes `now` as a PARAMETER and reads no clock. Its own",
        "source says why, at the top of src/verify.ts: \"this verifier parses bytes it",
        "is handed and NEVER fetches\", and separately, of `now`: \"Required — this",
        "module reads no clock\", because \"a library that read its own clock could not",
        "be tested deterministically\".",
        "",
        "So the caller pins the instant. This task pins it out loud:",
        "",
        kv("pinned now", @pinned_now),
        kv("envelope validFrom", env["validFrom"]),
        kv("envelope validUntil", env["validUntil"]),
        kv("inside the window", window_check_label(env)),
        kv("clock skew", "60 s, the §8.3 RECOMMENDED default"),
        kv("", "(DEFAULT_CLOCK_SKEW_SECONDS, src/types.ts)"),
        "",
        @pin_sentence,
        "",
        "  The instant is not invented either: it is the aph repo's own",
        "  GOLDEN_EVALUATION_INSTANT (interpreters/typescript/testkit/golden.ts), so",
        "  this demo and its upstream evaluate the same fixture at the same moment.",
        "",
        "  A verifier that quietly read the wall clock would do two dishonest things",
        "  at once: it would pass today and fail tomorrow for reasons no reader could",
        "  see, and it would hide which instant a verdict rested on. Leg [5] runs the",
        "  same envelope against the real clock and is refused — which is what makes",
        "  this pin load-bearing rather than decorative."
      ]
  end

  defp window_check_label(env) do
    with {:ok, now, _} <- DateTime.from_iso8601(@pinned_now),
         {:ok, from, _} <- DateTime.from_iso8601(env["validFrom"]),
         {:ok, until, _} <- DateTime.from_iso8601(env["validUntil"]) do
      if DateTime.compare(now, from) != :lt and DateTime.compare(now, until) != :gt,
        do: "yes — compared on this run, not asserted",
        else: "NO — the pin falls outside the fixture's own window"
    else
      _ -> "not comparable — a timestamp did not parse"
    end
  end

  # ----------------------------------------------------------------------
  # [3] The golden, at the pinned instant
  # ----------------------------------------------------------------------

  defp leg_pinned(corpus, result) do
    setup = [
      "The whole golden envelope — #{byte_size(corpus.envelope)} bytes of JSON TEXT, unparsed, exactly as",
      "it sits in the clone — plus the #{byte_size(corpus.body)} authorized body bytes, plus the pinned",
      "instant, plus one key. Handed across a process boundary to verifyEnvelope and",
      "asked for the full §8.3 / §8.3.1 procedure.",
      "",
      kv("require_mode", inspect(@require_mode)),
      kv("now", @pinned_now),
      kv("body bytes supplied", "yes, #{byte_size(corpus.body)} — so §8.3 step 8 can run")
    ]

    {lines, deviations} = pinned_outcome(corpus, result)

    %{
      lines: section("3", "LEG 1 — THE GOLDEN, VERIFIED AT THE PINNED INSTANT") ++ setup ++ lines,
      deviations: deviations
    }
  end

  defp pinned_outcome(corpus, {:ok, result}) do
    verified = result.verified

    expected = %{
      attestationMode: @require_mode,
      bodyHashChecked: true,
      embeddedMandateChecked: true
    }

    lines =
      [
        "",
        kv("outcome", "VERIFIED — verifyEnvelope returned a VerifiedEnvelope"),
        "",
        "  what it reports, in its own field names (src/verify.ts):",
        field("attestationMode", inspect(verified.attestationMode)),
        field("bodyHashChecked", inspect(verified.bodyHashChecked)),
        field("embeddedMandateChecked", inspect(verified.embeddedMandateChecked)),
        "",
        "  Those last two are reports of what RAN, not of what is possible.",
        "  `bodyHashChecked: true` means §8.3 step 8 hashed the delivered bytes and",
        "  they matched the envelope's bodySha256. `embeddedMandateChecked: true`",
        "  means the §6.1 mandate embedded in this envelope's policy was checked —",
        "  its bindings to this human and this agent, its allowedChannels, its window",
        "  around the envelope's own, and BOTH of its signatures.",
        "",
        kv(
          "  transport",
          "envelope #{result.transport.envelope_bytes} B, body #{result.transport.body_bytes} B"
        ),
        kv("", "measured by the verifier on the far side of the"),
        kv("", "process boundary, and equal to what was handed in"),
        "",
        "  Four Ed25519 signatures were checked in total: the principal's and the",
        "  notary's over the envelope, and the mandate's principalSignature and",
        "  notarySignature over their own §6.1 bases. `mix demo.run` checked none.",
        ""
      ] ++ step_lines(:ok)

    deviations =
      List.flatten([
        if(verified == expected,
          do: [],
          else: ["leg [3]: expected #{inspect(expected)}, got #{inspect(verified)}"]
        ),
        if(result.transport.envelope_bytes == byte_size(corpus.envelope),
          do: [],
          else: [
            "leg [3]: the verifier measured #{result.transport.envelope_bytes} envelope " <>
              "bytes, #{byte_size(corpus.envelope)} were handed in"
          ]
        ),
        if(result.transport.body_bytes == byte_size(corpus.body),
          do: [],
          else: [
            "leg [3]: the verifier measured #{inspect(result.transport.body_bytes)} body " <>
              "bytes, #{byte_size(corpus.body)} were handed in"
          ]
        ),
        if(result.evaluated_at == @pinned_now,
          do: [],
          else: ["leg [3]: evaluated at #{inspect(result.evaluated_at)}, not the pinned instant"]
        )
      ])

    {lines, deviations}
  end

  defp pinned_outcome(_corpus, {:error, error}) do
    {[
       "",
       kv("outcome", "REFUSED — the golden did not verify"),
       "  the verifier's own words:"
     ] ++ wrap(error_message(error), "      ", "      "),
     ["leg [3]: the golden was expected to verify and did not: #{error_message(error)}"]}
  end

  # ----------------------------------------------------------------------
  # [4] Key sourcing
  # ----------------------------------------------------------------------

  defp leg_key_sourcing(result) do
    intro = [
      "The golden's two proofs are anchored two different ways, and the difference is",
      "the entire §8.4 story — the one this repository does not implement.",
      "",
      @key_sourcing_line,
      ""
    ]

    {lines, deviations} = key_sourcing_outcome(result)

    %{
      lines: section("4", "KEY SOURCING — where each verifying key came from") ++ intro ++ lines,
      deviations: deviations
    }
  end

  defp key_sourcing_outcome({:ok, result}) do
    keys = result.key_sourcing

    lines =
      [kv("self-describing", "#{length(keys.self_describing)}  (did:key — §8.4.3)")] ++
        Enum.map(keys.self_describing, &("      " <> &1)) ++
        [
          "",
          kv(
            "supplied out of band",
            "#{length(keys.supplied_out_of_band)}  (§8.4.4 would fetch; nothing here does)"
          )
        ] ++
        Enum.map(keys.supplied_out_of_band, &("      " <> &1)) ++
        [
          "",
          kv("fetched", "#{length(keys.fetched)}"),
          "",
          "  The human principal is a `did:key`: the identifier IS the public key,",
          "  base58-encoded behind a multicodec prefix, so it decodes offline and needs",
          "  nothing handed in. Its bytes travelled inside the envelope, on the signal,",
          "  through the guard, into node.",
          "",
          "  The notary is a `did:web`. A `did:web` key is published at a .well-known",
          "  document a verifier would FETCH (§8.4.4), and this leg fetches nothing — so",
          "  its key arrives as a parameter. Those bytes are neither invented nor",
          "  transcribed into this repository: demo/priv/node/verify.mjs imports",
          "  RFC8032_TEST_3 from the aph clone's own testkit — the published RFC 8032",
          "  §7.1 TEST 3 vector that examples/README.md names as the notary's seed",
          "  throughout that corpus. Anyone can re-derive it; nobody has to trust this",
          "  repository for it.",
          "",
          "  " <> @notary_method <> " is a FIXTURE IDENTIFIER.",
          "  It was not resolved, not fetched and not contacted, here or anywhere else",
          "  in this repository. A verdict above rests on a key a human handed the",
          "  verifier, and saying so is the whole purpose of this section.",
          "",
          "  The two lists together are the entire proof chain, because there is no",
          "  third source: resolveVerifyingKey (src/verify.ts) decodes a did:key or",
          "  reads the supplied map, and throws AphKeyUnavailableError for anything",
          "  else — so a method resolved by some other route could not have reached",
          "  this report."
        ]

    deviations =
      List.flatten([
        if(keys.fetched == [],
          do: [],
          else: ["leg [4]: the verifier reported fetched keys: #{inspect(keys.fetched)}"]
        ),
        if(keys.supplied == [@notary_method] and keys.supplied_out_of_band == [@notary_method],
          do: [],
          else: [
            "leg [4]: expected exactly #{inspect([@notary_method])} supplied out of band, " <>
              "got supplied=#{inspect(keys.supplied)} used=#{inspect(keys.supplied_out_of_band)}"
          ]
        ),
        case keys.self_describing do
          [one] ->
            if String.starts_with?(one, "did:key:z"),
              do: [],
              else: ["leg [4]: the self-describing method is not a did:key: #{inspect(one)}"]

          other ->
            ["leg [4]: expected exactly one self-describing method, got #{inspect(other)}"]
        end
      ])

    {lines, deviations}
  end

  defp key_sourcing_outcome({:error, error}) do
    {[kv("outcome", "UNREPORTED — the golden did not verify; see leg [3]")],
     [
       "leg [4]: no key-sourcing report, because the golden did not verify: " <>
         error_message(error)
     ]}
  end

  # ----------------------------------------------------------------------
  # [5] The wall-clock beat
  # ----------------------------------------------------------------------

  defp leg_wall_clock(corpus, wall_now, result) do
    env = corpus.envelope_map

    setup = [
      "The same bytes, the same key, the same everything — with `now` read from this",
      "machine's clock instead of pinned.",
      "",
      kv("now", wall_now <> "   <- varies every run"),
      kv("envelope window", "#{env["validFrom"]} .. #{env["validUntil"]}"),
      ""
    ]

    {lines, deviations} = wall_clock_outcome(result)

    %{
      lines:
        section("5", "LEG 2 — THE WALL-CLOCK BEAT: the same envelope, right now") ++
          setup ++ lines,
      deviations: deviations
    }
  end

  defp wall_clock_outcome({:error, %{kind: :refusal, code: "APH_E003"} = refusal}) do
    lines =
      [
        kv("outcome", "REFUSED on the validity window"),
        kv("code", refusal.code),
        "  the verifier's own words, verbatim:"
      ] ++
        wrap(refusal.message, "      ", "      ") ++
        [
          "",
          "  Read that as the good news it is. The golden's window closed on",
          "  2026-05-22, so a fixture minted in May cannot be presented as authority",
          "  in August. §8.3 step 6 is exactly the rule that says so, with 60 seconds",
          "  of skew tolerance and not a day more.",
          "",
          "  It is also the proof that leg [3]'s pin is doing work. If `now` were",
          "  ignored, or defaulted, or quietly widened, this call would have returned",
          "  the same VerifiedEnvelope as leg [3]. It did not. The pin is stated in",
          "  section [2] rather than hidden precisely so this refusal can be shown",
          "  next to it instead of explained away.",
          "",
          "  Note what this refusal is NOT: it is not a signature problem. §8.3 step 6",
          "  runs at D9, after every signature in the document has already verified —",
          "  the enumeration below says so.",
          ""
        ] ++ step_lines({:refusal, refusal.code, refusal.message})

    {lines, []}
  end

  defp wall_clock_outcome({:ok, _result}) do
    {[
       kv("outcome", "VERIFIED — the wall clock currently falls inside the window"),
       "",
       "  This beat cannot be demonstrated at this instant: the golden's window has",
       "  not closed yet on this machine's clock, so pinned and unpinned agree. The",
       "  transcript says so rather than narrate a refusal that did not happen."
     ],
     [
       "leg [5]: the wall-clock run was expected to be refused on the validity " <>
         "window and was admitted instead"
     ]}
  end

  defp wall_clock_outcome({:error, error}) do
    {[
       kv("outcome", "REFUSED, but not on the window"),
       "  the verifier's own words:"
     ] ++ wrap(error_message(error), "      ", "      "),
     ["leg [5]: expected an APH_E003 validity-window refusal, got: " <> error_message(error)]}
  end

  # ----------------------------------------------------------------------
  # [6] The depth-split beat
  # ----------------------------------------------------------------------

  defp leg_depth_split(forged, gate, gateway, deep, control) do
    setup = [
      "Derived in memory, on this run, and written nowhere: the golden with the",
      "principal's proofValue replaced by the NOTARY's own. That is not a corrupted",
      "field — it is a genuine 64-byte Ed25519 signature in the same multibase",
      "base58btc spelling, over the wrong bytes. Nothing about the document's SHAPE",
      "is wrong: two-element proof chain, both DataIntegrityProof/eddsa-jcs-2022,",
      "both verificationMethods untouched, the PrincipalSigned label still matching",
      "the carriage §7.1.11 requires for it.",
      "",
      "The only thing wrong with it is that the human never signed it.",
      "",
      "Committed fixtures are never text-edited and derived negatives are never",
      "committed (PRD-001 §10 gate 4).",
      "",
      "HALF ONE — every check JidoAph.Guard runs, run on these exact bytes:",
      "",
      kv(
        "  S1 §7.1.7.1",
        "#{byte_size(forged)} B under the #{JidoAph.Guard.max_envelope_bytes()} B bound: #{pass_label(gate.size)}"
      ),
      kv("  S2 §8.3 step 1", "strict parse: #{pass_label(gate.parse)}"),
      kv("  S3 §8.3.1 step 1a", "mode gate: #{inspect(gate.mode)}"),
      kv("  S4 §7.1.11", "proof structure: #{inspect(gate.structure)}"),
      "",
      "...and the composite, through the agent stack the demo actually ships. The",
      "real Demo.Agents.Gateway, mounting JidoAph.Guard with required: true and",
      "require_mode: \"PrincipalSigned\", was started and handed the forgery on a",
      "\"slack.reply.requested\" signal:",
      ""
    ]

    gateway_lines =
      log_lines(gateway) ++
        [
          "",
          kv("  call/2 returned", call_label(gateway.result)),
          kv("  routed action", action_label(gateway.action_ran?)),
          "    context.aph.verdict",
          "        " <> inspect(gateway.verdict),
          "",
          "  The message would have gone out.",
          ""
        ]

    {deep_lines, deep_devs} = depth_split_outcome(deep, control)

    %{
      lines:
        section("6", "LEG 3 — THE DEPTH-SPLIT BEAT: one envelope, two verdicts") ++
          setup ++ gateway_lines ++ deep_lines,
      deviations: gate_deviations(gate) ++ gateway_deviations(gateway) ++ deep_devs
    }
  end

  # The forgery is a proofValue TRANSPLANT, not a character flip. A flipped
  # character risks a 63- or 65-byte multibase decode, which the verifier's
  # fixed-width gate rejects before any curve work — and "malformed signature"
  # is a far weaker beat than "a real signature that is not this human's".
  defp forge(corpus) do
    [principal, notary] = corpus.envelope_map["proof"]

    corpus.envelope_map
    |> Map.put("proof", [Map.put(principal, "proofValue", notary["proofValue"]), notary])
    |> JSON.encode!()
  end

  defp guard_gate(envelope_json) do
    %{
      size: byte_size(envelope_json) <= JidoAph.Guard.max_envelope_bytes(),
      parse: match?({:ok, _}, APH.parse_envelope_json(envelope_json)),
      mode: APH.require_attestation_mode(envelope_json, @require_mode),
      structure: APH.verify_proof_structure(envelope_json)
    }
  end

  defp depth_split_outcome({:error, %{kind: :refusal, code: "APH_E011"} = refusal}, control) do
    lines =
      [
        "HALF TWO — the same bytes, this leg:",
        "",
        kv("outcome", "REFUSED"),
        kv("code", refusal.code),
        "  the verifier's own words, verbatim:"
      ] ++
        wrap(refusal.message, "      ", "      ") ++
        [
          "",
          kv("control", control_label(control)),
          kv("", "the untampered golden, same call, same instant, run"),
          kv("", "after the forgery — so the refusal above is the"),
          kv("", "forgery's doing and not the harness's"),
          "",
          "  One envelope. The structural gate admitted it and the action ran; the",
          "  signature check refused it. Both are correct, and the guard was never",
          "  wrong, because the guard never claimed this: its verdict says",
          "  \"notarization-shaped, mode policy satisfied\" and stops there, and aph-ex",
          "  says of the very operation it leans on hardest that a successful return",
          "  \"says NOTHING about whether any signature verifies\".",
          "",
          @depth_split_line,
          "",
          "  It is also why a deployment running only the guard is not thereby broken:",
          "  it is a deployment that has chosen depth 0-1, and the honest thing is to",
          "  say which depth ran, in the log line, every time.",
          ""
        ] ++ step_lines({:refusal, refusal.code, refusal.message})

    {lines, control_deviations(control)}
  end

  defp depth_split_outcome({:ok, _}, control) do
    {[
       "HALF TWO — the same bytes, this leg:",
       "",
       kv("outcome", "VERIFIED — the forgery was NOT caught"),
       "",
       "  This is the one outcome that would invalidate the whole beat, and the task",
       "  exits non-zero on it rather than narrate around it."
     ],
     ["leg [6]: the forged envelope verified; the depth-split beat does not hold"] ++
       control_deviations(control)}
  end

  defp depth_split_outcome({:error, error}, control) do
    {[
       "HALF TWO — the same bytes, this leg:",
       "",
       kv("outcome", "REFUSED, but not on the principal signature"),
       "  the verifier's own words:"
     ] ++ wrap(error_message(error), "      ", "      "),
     ["leg [6]: expected an APH_E011 principal-signature refusal, got: " <> error_message(error)] ++
       control_deviations(control)}
  end

  defp control_label({:ok, %{verified: %{attestationMode: mode}}}),
    do: "still verifies (attestationMode #{inspect(mode)})"

  defp control_label({:error, error}), do: "DID NOT VERIFY: " <> error_message(error)

  defp control_deviations({:ok, _}), do: []

  defp control_deviations({:error, error}),
    do: [
      "leg [6]: the untampered golden did not verify under the identical call " <>
        "(#{error_message(error)}), so the forgery's refusal proves nothing"
    ]

  defp pass_label(true), do: "PASSES"
  defp pass_label(false), do: "FAILS"

  defp call_label({:ok, %Jido.Agent{}}), do: "{:ok, %Jido.Agent{}} — ADMITTED"
  defp call_label(other), do: inspect(other, limit: :infinity)

  defp action_label(true), do: "Demo.Actions.DeliverReply RAN"
  defp action_label(false), do: "Demo.Actions.DeliverReply did NOT run"

  defp gate_deviations(gate) do
    List.flatten([
      if(gate.size, do: [], else: ["leg [6]: the forgery is over the guard's byte bound"]),
      if(gate.parse, do: [], else: ["leg [6]: the forgery did not strict-parse"]),
      if(gate.mode == :ok,
        do: [],
        else: ["leg [6]: the guard's mode gate refused the forgery: #{inspect(gate.mode)}"]
      ),
      if(gate.structure == {:ok, @require_mode},
        do: [],
        else: [
          "leg [6]: the guard's structure gate refused the forgery: #{inspect(gate.structure)}"
        ]
      )
    ])
  end

  defp gateway_deviations(gateway) do
    List.flatten([
      if(match?({:ok, %Jido.Agent{}}, gateway.result),
        do: [],
        else: [
          "leg [6]: Demo.Agents.Gateway did not admit the forgery: " <>
            inspect(gateway.result, limit: :infinity)
        ]
      ),
      if(gateway.action_ran?,
        do: [],
        else: ["leg [6]: the gateway admitted the forgery but the routed action did not run"]
      ),
      if(gateway.verdict == @guard_verdict,
        do: [],
        else: [
          "leg [6]: expected the guard verdict #{inspect(@guard_verdict)}, " <>
            "got #{inspect(gateway.verdict)}"
        ]
      )
    ])
  end

  # ----------------------------------------------------------------------
  # [7] What this leg adds
  # ----------------------------------------------------------------------

  defp adds do
    section("7", "WHAT THIS LEG ADDS over the structural gate") ++
      [
        "The eleven steps below are what verifyEnvelope really runs, in the order",
        "src/verify.ts runs them. D1-D4 are the same four JidoAph.Guard runs — the",
        "value there is not novelty but INDEPENDENCE: a second implementation, in a",
        "second language, reaching the same structural verdict. D5-D11 are the ones",
        "the guard cannot reach at all, because no cryptography runs on the BEAM.",
        "",
        "  D1   §7.1.7.1        envelope byte bound, before any parse",
        "  D2   §8.3 step 1     strict parse, unknown fields denied — and, unlike the",
        "                       guard's S2, the CLOSED channel and contentClass",
        "                       vocabularies of §7.1.5 / §7.1.6 enforced here",
        "  D3   §8.3.1 step 1a  attestation-mode policy (APH_E012)",
        "  D4   §7.1.11         label versus proof structure, both directions",
        "                       (APH_E013)",
        "  ------------------   everything below this line is new -----------------",
        "  D5   §8.3 step 1b-1c the PRINCIPAL's Ed25519 signature over its §7.2.1",
        "                       base — the envelope with the notary proof discarded,",
        "                       `proof` kept as a ONE-ELEMENT ARRAY, and the",
        "                       principal's own proofValue emptied (APH_E011)",
        "  D6   §7.2.1 step 1e  issuance order: the notary's decisionTimestamp, then",
        "                       the principal's proof, then the notary's — each",
        "                       signature covering only bytes that existed when it",
        "                       was made (APH_E013)",
        "  D7   §8.3 steps 2-5  the NOTARY's Ed25519 signature over its own §7.2.1",
        "                       base (APH_E001)",
        "  D8   §8.3.1 step 1d  the embedded §6.1 delegation mandate: bound to this",
        "                       human and this agent, its allowedChannels covering",
        "                       this channel, its window enclosing the envelope's,",
        "                       and its OWN two signatures — principalSignature",
        "                       (APH_E011) and notarySignature (APH_E006)",
        "  D9   §8.3 step 6     the validity window against the pinned `now`, 60 s",
        "                       skew (APH_E003)",
        "  D10  §8.3 step 8     bodySha256 recomputed over the body bytes AS",
        "                       RECEIVED — never over a re-serialization of a parsed",
        "                       object, because two JSON texts that parse equal can",
        "                       hash differently (APH_E009)",
        "  D11  §8.3 step 8a    credentialStatus. Absent here, so §6.3.3.4 case 1:",
        "                       SKIP. Present would be case 2 — REFUSED, APH_E008 —",
        "                       because a verifier with no status transport must not",
        "                       let an attacker who can break the status check",
        "                       thereby choose that it is skipped",
        "",
        "All canonicalization is JCS / RFC 8785. Four Ed25519 signatures in total,",
        "and every one of them sits in `mix demo.run`'s not-checked column."
      ]
  end

  # ----------------------------------------------------------------------
  # [8] What it still does not do
  # ----------------------------------------------------------------------

  defp still_not(corpus) do
    section("8", "WHAT IT STILL DOES NOT DO") ++
      [
        "Three things, and none of them is an oversight. Each is a network act, and",
        "this whole rail is offline by construction.",
        "",
        "  X1  NETWORK KEY DISCOVERY (§8.4). The borrowed verifier never fetches;",
        "      that is the first sentence of its own source. Nothing resolved a",
        "      did:web document, queried a DNS TXT record, or opened a socket. This",
        "      is exactly why the notary's key had to be handed in as a parameter —",
        "      section [4] names it, counts it and says where its bytes came from,",
        "      rather than letting a verdict quietly rest on an anchor nobody",
        "      declared.",
        "",
        "  X2  REVOCATION (§6.3.3). No status was consulted, because no status",
        "      transport exists in this repository at all. The golden carries no",
        "      credentialStatus member, so D11 skipped — correctly, and by the",
        "      specification's own trichotomy. An envelope that DID carry one would",
        "      be refused APH_E008 here, never waved through.",
        "",
        "  X3  THE LIVE NOTARY. #{@notary_method} is a",
        "      fixture identifier and was never contacted. The live surface",
        "      did:web:aph-notary.squillo.com was not contacted either, by anything,",
        "      at any point.",
        "",
        "And one more, which is not about depth at all: nothing here was MINTED. The",
        "envelope is a pre-minted committed golden — #{byte_size(corpus.envelope)} bytes that were sitting",
        "in the clone before this task started — so running it asserts nothing",
        "whatsoever about whether a human authorized anything today. What it asserts",
        "is that the signatures on a document from May 2026 are the signatures that",
        "document claims, evaluated at an instant this transcript prints in full."
      ]
  end

  # ----------------------------------------------------------------------
  # [9] Honesty footer
  # ----------------------------------------------------------------------

  defp footer do
    section("9", "HONESTY FOOTER — what to say, and what not to, about this run") ++
      [
        "Say this: the golden envelope independently passes full offline §8.3 in a",
        "second implementation of the specification — all four Ed25519 signatures",
        "over their RFC 8785 canonical bases, issuance order, the embedded mandate's",
        "bindings and both of its signatures, the validity window against a PINNED",
        "instant that this transcript prints, and bodySha256 recomputed over the body",
        "bytes as received — with exactly one key supplied out of band, named in",
        "section [4].",
        "",
        "Do not say this: that any key was discovered, that any revocation status was",
        "checked, that any notary was contacted, or that anything was minted.",
        "",
        "And do not read leg [6] backwards. The structural gate admitted a forgery and",
        "was not thereby wrong: it answered the question it was asked, in the words it",
        "was allowed to use. The failure mode this repository is built to avoid is not",
        "a shallow check — it is a shallow check DESCRIBED as a deep one.",
        "",
        "The structural leg, which needs no Node and reaches no network:",
        "",
        "    mix demo.run",
        "",
        rule("=")
      ]
  end

  # ----------------------------------------------------------------------
  # Running the verifier and the agent
  # ----------------------------------------------------------------------

  defp verify(envelope_json, now, repo_override, body) do
    TsSidecar.verify(
      envelope_json,
      [now: now, require_mode: @require_mode, body_bytes: body] ++
        if(repo_override, do: [aph_repo_path: repo_override], else: [])
    )
  end

  # Drives the REAL shipped Gateway, exactly as a reader would: start it under
  # Demo.Jido, attach the envelope with JidoAph.attach_notarization/3, hand it
  # over with Jido.AgentServer.call/2, and collect what the guard logged and
  # what the routed action received.
  defp drive_gateway(envelope_json) do
    {:ok, pid} =
      Demo.Jido.start_agent(Demo.Agents.Gateway,
        id: "deep-verify-gateway-#{System.unique_integer([:positive])}"
      )

    result =
      try do
        signal = Signal.new!("slack.reply.requested", %{reply_to: self()})
        {:ok, signal} = JidoAph.attach_notarization(signal, envelope_json)
        AgentServer.call(pid, signal)
      after
        Demo.Jido.stop_agent(pid)
      end

    events = LogCapture.drain()

    context =
      Enum.find_value(events, fn
        {:action, _params, action_context} -> action_context
        _ -> nil
      end)

    %{
      result: result,
      logs: for({:log, level, message} <- events, do: {level, message}),
      action_ran?: context != nil,
      verdict: context && get_in(context, [:aph, :verdict])
    }
  end

  defp log_lines(%{logs: []}), do: ["  (this leg emitted no log line of its own)"]

  # Log messages are reproduced verbatim, soft-wrapped on existing spaces only.
  # On a real console each is one line; nothing but line breaks is added.
  defp log_lines(%{logs: logs}) do
    Enum.flat_map(logs, fn {level, message} ->
      wrap(message, "  log [#{level}] ", "                ")
    end)
  end

  defp error_message(%{message: message}), do: message
  defp error_message(other), do: inspect(other, limit: :infinity)

  # ----------------------------------------------------------------------
  # Step attribution
  # ----------------------------------------------------------------------

  # Which of D1-D11 ran is DERIVED from the verifier's own code and message,
  # never scripted: verifyEnvelope short-circuits, so a refusal identifies the
  # step that stopped it and therefore the steps that preceded it. The mapping
  # below has one entry per `throw` site in src/verify.ts; only the two this run
  # actually produces are exercised, and each leg separately declares which one
  # it expects, so a mismatch becomes a deviation rather than a quiet
  # re-narration.
  defp step_lines(:ok), do: render_steps(@step_order, nil, [])

  defp step_lines({:refusal, code, message}) do
    case refused_step(code, message) do
      nil ->
        ["  verifier steps: not attributable from #{inspect(code)} — see the message above"]

      step ->
        {ran, [^step | not_reached]} = Enum.split_while(@step_order, &(&1 != step))
        render_steps(ran, step, not_reached)
    end
  end

  defp refused_step("APH_E012", _message), do: :d3
  defp refused_step("APH_E006", _message), do: :d8
  defp refused_step("APH_E001", _message), do: :d7
  defp refused_step("APH_E003", _message), do: :d9
  defp refused_step("APH_E009", _message), do: :d10
  defp refused_step("APH_E008", _message), do: :d11

  # APH_E011 is raised at two sites: the envelope's principal proof (D5) and the
  # embedded mandate's own principalSignature (D8). The message distinguishes
  # them; the code alone does not.
  defp refused_step("APH_E011", message) do
    if String.contains?(message, "embedded mandate"), do: :d8, else: :d5
  end

  # APH_E013 likewise: label-versus-structure (D4) and issuance order (D6). Both
  # issuance-order messages say a proof is dated "before the" something.
  defp refused_step("APH_E013", message) do
    if String.contains?(message, "before the"), do: :d6, else: :d4
  end

  defp refused_step(_code, _message), do: nil

  defp render_steps(ran, refused_at, not_reached) do
    ["  verifier steps, this leg:"] ++
      Enum.map(@step_order, fn step ->
        status =
          cond do
            step == refused_at -> "REFUSED  <- the leg stops here"
            step == :d11 and step in ran -> "RAN — credentialStatus absent, so SKIP"
            step in ran -> "RAN"
            step in not_reached -> "NOT REACHED"
            true -> "not attributable"
          end

        "      " <> String.pad_trailing(@step_labels[step], @step_label_width) <> status
      end)
  end

  # ----------------------------------------------------------------------
  # Output
  # ----------------------------------------------------------------------

  defp write_out(nil, _transcript), do: :ok

  defp write_out(path, transcript) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, transcript)
    IO.puts("\ntranscript written to #{path}")
  end

  defp report_deviations([]), do: :ok

  defp report_deviations(deviations) do
    IO.puts("\n" <> String.duplicate("!", @width))
    IO.puts("DEVIATIONS — the deep leg did not do what the transcript above narrates:")
    IO.puts(String.duplicate("!", @width))
    Enum.each(deviations, fn deviation -> IO.puts("  - " <> deviation) end)

    Mix.raise(
      "mix demo.deep_verify found #{length(deviations)} deviation(s); the transcript is " <>
        "not a truthful record of this run"
    )
  end

  # ----------------------------------------------------------------------
  # Rendering helpers
  # ----------------------------------------------------------------------
  #
  # Deliberately duplicated from Demo.Narrative rather than extracted into a
  # shared module: the two transcripts are separate committed artifacts with
  # separate golden-output tests, and a shared formatter would let a cosmetic
  # change to one of them silently rewrite the committed bytes of the other.

  defp section(index, title), do: ["", "", "[#{index}] #{title}", rule("-")]

  defp rule(char), do: String.duplicate(char, @width)

  # A one-level-deeper column than kv/2, for the verifier's own field names —
  # `embeddedMandateChecked` outgrows the kv label column and would otherwise
  # print out of line with its two siblings.
  defp field(label, value), do: "      " <> String.pad_trailing(label, 24) <> value

  # A label column wide enough for every label used here. A label that outgrows
  # it still gets one separating space rather than running into its value.
  defp kv(key, value) do
    if String.length(key) < @label_width do
      "  " <> String.pad_trailing(key, @label_width) <> value
    else
      "  " <> key <> " " <> value
    end
  end

  # Soft-wraps on existing spaces only — no hyphenation, no re-flowing inside a
  # word — so every byte the verifier produced survives into the transcript and
  # only line breaks are added.
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
end
