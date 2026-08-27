defmodule Demo.DeepVerifyDegradationTest do
  # Why this module exists, and why it is the only UNTAGGED one in this file:
  # PRD-001 §10 gate 7 requires `mix demo.deep_verify` to exit non-zero WITH
  # INSTRUCTIONS when node or the built dist/ is missing, and that promise is
  # worthless if it is only ever exercised by accident on a broken machine.
  # `--aph-repo` points the leg at a directory that provably has no dist/, so
  # the degradation runs on demand — here, in the core pipeline, where it is
  # the only deep-leg test that runs at all.
  #
  # It lives in its own module rather than alongside the :deep tests below
  # because ExUnit skips a module's setup_all entirely when every test in it is
  # excluded (verified against this VM, not assumed) — which is how the core
  # pipeline avoids building the transcript while the :deep suite still builds
  # it exactly once.
  #
  # What it touches, stated precisely: `availability/1` checks node BEFORE it
  # checks dist/, so on a machine that HAS node this runs `node --version` once
  # and then takes the :dist_missing branch, while on a Node-free machine it
  # takes :node_not_found. It asserts only on strings both branches produce, so
  # it is green either way — and it never runs a verification, builds anything,
  # or needs a dist/.
  #
  # async: false — it runs a Mix task that starts the app.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Demo.DeepVerify

  @moduletag capture_log: true

  # Why this test exists: a setup gap must never print a partial transcript,
  # because a transcript with holes in it reads like a verdict about an
  # envelope — and no envelope was examined at all. So this pins both halves:
  # the non-zero exit with the setup story, and the ABSENCE of any narrative
  # fragment that a reader could mistake for a result.
  test "the leg degrades with setup instructions and a non-zero exit" do
    missing = Path.join(System.tmp_dir!(), "jido_aph_no_such_clone_#{System.unique_integer()}")
    refute File.exists?(missing)

    stdout =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/the deep leg is unavailable/, fn ->
          Mix.Task.rerun("demo.deep_verify", ["--aph-repo", missing])
        end
      end)

    assert stdout =~ "DEEP LEG UNAVAILABLE"
    assert stdout =~ "nothing was verified, and nothing is claimed"
    assert stdout =~ "reason"

    # The Node-free way out is named, so a reader who hit this is not stuck.
    assert stdout =~ "mix demo.run"

    # And no fragment of the real transcript leaked into the failure report.
    refute stdout =~ "[1] PROVENANCE"
    refute stdout =~ "[9] HONESTY FOOTER"
    refute stdout =~ DeepVerify.depth_split_line()
  end
end

defmodule Demo.DeepVerifyTranscriptTest do
  # Why this file exists: it is PRD-001 T13's DONE condition — "a :deep-tagged
  # golden-output test asserts the transcript's pinned-now statement,
  # wall-clock refusal beat, depth-split line, key-sourcing line, and ADDS/
  # STILL-not list" — and the second half of PRD-001 §10 gate 5, which makes
  # the honesty contract MACHINE-CHECKED on both legs rather than merely
  # written down. T16's :deep CI job greps `mix demo.deep_verify`'s stdout for
  # exactly these strings; if this file is green that grep cannot be silently
  # wrong, and if the deep leg ever starts narrating something it did not do,
  # this goes red before a reader is misled.
  #
  # What it pins beyond the five DONE items:
  #
  #   * that the per-leg spec-step enumeration is attributed to the step that
  #     really refused (APH_E003 -> D9, APH_E011 -> D5), not scripted;
  #   * that the GUARD's own captured log lines never contain the bare words
  #     "verified" or "signed", even though this transcript legitimately does —
  #     the deep leg earned those words and the guard did not;
  #   * that the transcript is byte-identical run to run except for the wall
  #     clock, which is what makes the committed artifact worth committing;
  #   * that docs/transcripts/demo_deep_verify.txt still describes the corpus
  #     and the verifier this repo actually reads today.
  #
  # Toolchain: every test here needs Node >= 20 and a built dist/ in the
  # sibling clone, so the whole module is :deep and excluded by default
  # (test/test_helper.exs). Run it with `mix test --include deep` or
  # `APH_DEEP=1 mix test`. Because the tag is a MODULE tag, ExUnit skips the
  # setup_all below entirely in the core pipeline and no node process is ever
  # spawned there.
  #
  # async: false — building the transcript drives the singleton Demo.Jido
  # instance, spawns node subprocesses, and temporarily changes the VM-wide
  # :default logger handler's level.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Demo.DeepVerify

  @moduletag :deep
  @moduletag capture_log: true

  @committed_transcript "../docs/transcripts/demo_deep_verify.txt"

  @envelope_file "principal_signed_envelope.json"
  @body_file "principal_signed_body.txt"

  # Build the transcript ONCE. Every assertion below reads the same run, so
  # this module makes one set of claims about one execution — and the four node
  # subprocesses it costs are paid for once.
  setup_all do
    case DeepVerify.report([]) do
      {:ok, result} ->
        %{transcript: result.transcript, deviations: result.deviations}

      {:unavailable, _block} ->
        # Deliberately not a flunk in setup_all, which would report every test
        # as an error with no message a reader can act on: each test flunks
        # through require_transcript!/1 with the setup story instead.
        %{transcript: nil, deviations: nil}
    end
  end

  # Why this test exists: it is the DONE condition itself — the five items T13
  # names, plus the deviation list, which is the task's own statement that the
  # story it told is the run it made. Every string here is one CI greps for.
  test "the transcript carries the pin, the wall-clock refusal, the split, the keys and both lists",
       %{transcript: transcript, deviations: deviations} do
    transcript = require_transcript!(transcript)

    assert deviations == [],
           "mix demo.deep_verify reported deviations:\n" <> Enum.join(deviations, "\n")

    # 1. The pinned-now statement, said out loud rather than implied.
    assert transcript =~ "[2] THE PIN"
    assert transcript =~ DeepVerify.pin_sentence()
    assert transcript =~ "pinned now            " <> DeepVerify.pinned_now()
    assert transcript =~ "inside the window     yes"
    assert transcript =~ "GOLDEN_EVALUATION_INSTANT"

    # 2. The wall-clock refusal beat.
    assert transcript =~ "[5] LEG 2 — THE WALL-CLOCK BEAT"
    assert transcript =~ "REFUSED on the validity window"
    assert transcript =~ "APH_E003 (MandateExpired)"
    assert transcript =~ "outside the envelope window"

    # 3. The depth-split line, with both halves of the beat around it.
    assert transcript =~ "[6] LEG 3 — THE DEPTH-SPLIT BEAT"
    assert transcript =~ DeepVerify.depth_split_line()
    assert transcript =~ "notarization-shaped, mode policy satisfied (PrincipalSigned)"
    assert transcript =~ "Demo.Actions.DeliverReply RAN"
    assert transcript =~ "APH_E011 (PrincipalSignatureInvalid)"

    # 4. The key-sourcing line, with the numbers it summarises.
    assert transcript =~ "[4] KEY SOURCING"
    assert transcript =~ DeepVerify.key_sourcing_line()
    assert transcript =~ ~r/self-describing\s+1\s+\(did:key/
    assert transcript =~ ~r/supplied out of band\s+1\s/
    assert transcript =~ ~r/fetched\s+0/
    assert transcript =~ "did:web:notary.squillo.com#key-1 is a FIXTURE IDENTIFIER"

    # 5. What it ADDS, and what it STILL does not do.
    assert transcript =~ "[7] WHAT THIS LEG ADDS"
    assert transcript =~ "D5   §8.3 step 1b-1c the PRINCIPAL's Ed25519 signature"
    assert transcript =~ "D6   §7.2.1 step 1e  issuance order"
    assert transcript =~ "D8   §8.3.1 step 1d  the embedded §6.1 delegation mandate"
    assert transcript =~ "D10  §8.3 step 8     bodySha256 recomputed"

    assert transcript =~ "[8] WHAT IT STILL DOES NOT DO"
    assert transcript =~ "X1  NETWORK KEY DISCOVERY (§8.4)"
    assert transcript =~ "X2  REVOCATION (§6.3.3)"
    assert transcript =~ "X3  THE LIVE NOTARY"
    assert transcript =~ "did:web:aph-notary.squillo.com was not contacted"
    assert transcript =~ "nothing here was MINTED"

    assert transcript =~ "[9] HONESTY FOOTER"
  end

  # Why this test exists: PRD-001 §3 asks the transcript to say which checks
  # RAN. That is only a real claim if the enumeration follows what actually
  # stopped each leg, so this pins the two short-circuit points against the two
  # codes: a validity-window refusal reaches D9 with every signature already
  # checked, and a principal-signature refusal stops at D5 with the window and
  # the body hash never reached. Getting these backwards would tell a reader
  # the exact opposite of the depth story.
  test "each leg attributes its refusal to the step that really stopped it",
       %{transcript: transcript} do
    transcript = require_transcript!(transcript)
    legs = String.split(transcript, "\n[")

    golden = find_leg(legs, "LEG 1 — THE GOLDEN")
    assert golden =~ "D1   §7.1.7.1         RAN"
    assert golden =~ "D11  §8.3 step 8a     RAN — credentialStatus absent, so SKIP"
    refute golden =~ "NOT REACHED"
    refute golden =~ "REFUSED"

    wall = find_leg(legs, "THE WALL-CLOCK BEAT")
    assert wall =~ "D8   §8.3.1 step 1d   RAN"
    assert wall =~ "D9   §8.3 step 6      REFUSED"
    assert wall =~ "D10  §8.3 step 8      NOT REACHED"

    split = find_leg(legs, "THE DEPTH-SPLIT BEAT")
    assert split =~ "D4   §7.1.11          RAN"
    assert split =~ "D5   §8.3 step 1b-1c  REFUSED"
    assert split =~ "D9   §8.3 step 6      NOT REACHED"
    assert split =~ "D10  §8.3 step 8      NOT REACHED"
  end

  # Why this test exists: this transcript is the one artifact in the repository
  # that MAY say "verified" and "signed" — the deep leg earned those words. The
  # guard did not, and PRD-001 §8 makes it a hard rule that its logs never use
  # them as bare words. Both voices appear in this file, so a blanket ban would
  # be wrong and a blanket permission would be worse: the assertion is scoped
  # to the guard's own captured log lines, which is exactly where the rule
  # binds. Asserting they are present FIRST keeps the refutations from passing
  # trivially on an empty selection.
  test "the guard's own log lines never use the bare words this transcript may use",
       %{transcript: transcript} do
    transcript = require_transcript!(transcript)

    # The transcript as a whole legitimately says both, about the deep leg.
    assert transcript =~ ~r/\bverified\b/i
    assert transcript =~ ~r/\bsigned\b/i

    logs = captured_log_block(transcript)

    assert logs =~ "aph_guard: notarization-shaped, mode policy satisfied"
    assert logs =~ "deliver_reply: would deliver (no channel adapter)"
    refute logs =~ "(this leg emitted no log line of its own)"

    refute logs =~ ~r/\bverified\b/i
    refute logs =~ ~r/\bsigned\b/i

    # The closed-vocabulary literal must survive the bare-word rule, in the
    # guard's voice, or the rule is testing the wrong thing.
    assert logs =~ "PrincipalSigned"
  end

  # Why this test exists: everything above asserts a STRING built by calling
  # DeepVerify.report/1 directly. T16's CI job greps the TASK's STDOUT, which
  # is a different path through the code. This runs the real task and asserts
  # the strings that gate names, so the CI grep and this suite can never
  # disagree about what `mix demo.deep_verify` prints.
  test "mix demo.deep_verify prints the transcript to stdout" do
    stdout = capture_io(fn -> Mix.Task.rerun("demo.deep_verify") end)

    assert stdout =~ "[1] PROVENANCE"
    assert stdout =~ DeepVerify.pin_sentence()
    assert stdout =~ "APH_E003"
    assert stdout =~ "APH_E011"
    assert stdout =~ DeepVerify.depth_split_line()
    assert stdout =~ DeepVerify.key_sourcing_line()
    assert stdout =~ "[7] WHAT THIS LEG ADDS"
    assert stdout =~ "[8] WHAT IT STILL DOES NOT DO"
    refute stdout =~ "DEVIATIONS"
  end

  # Why this test exists: the committed transcript is what T14 puts in the
  # README beside the guard transcript, and a committed artifact is only worth
  # committing if a second run reproduces it. This pins that the ONLY things
  # that move between runs are the ones the moduledoc says must move — and the
  # wall-clock instant is the interesting one, because a verifier that ignored
  # `now` would make even that line stable and the whole pin story a fiction.
  test "two runs differ only where the transcript says they must",
       %{transcript: first} do
    first = require_transcript!(first)
    {:ok, %{transcript: second}} = DeepVerify.report([])

    refute first == second, "the wall-clock instant did not move between two runs"
    assert redact_clock(first) == redact_clock(second)
  end

  # Why this test exists: the committed transcript is what a reader quotes, and
  # one that quietly describes yesterday's corpus is the exact stale-provenance
  # defect the T2 erratum had to file against upstream. It pins that the file
  # still carries every invariant this suite asserts, and that its fixture
  # identity agrees with the bytes the demo reads TODAY — deliberately WITHOUT
  # pinning the aph SHA, because bumping the sibling pin is a reviewed change
  # and fixture drift is T15's gate, not this one's.
  test "the committed transcript still describes the corpus and verifier read today" do
    path = Path.expand(@committed_transcript, File.cwd!())

    assert File.exists?(path),
           "#{path} is missing; regenerate it with " <>
             "`mix demo.deep_verify --out #{@committed_transcript}` from demo/"

    committed = File.read!(path)

    assert committed =~ ~r/aph HEAD\s+[0-9a-f]{40}/
    assert committed =~ "[1] PROVENANCE"
    assert committed =~ DeepVerify.pin_sentence()
    assert committed =~ "pinned now            " <> DeepVerify.pinned_now()
    assert committed =~ DeepVerify.depth_split_line()
    assert committed =~ DeepVerify.key_sourcing_line()
    assert committed =~ "APH_E003 (MandateExpired)"
    assert committed =~ "APH_E011 (PrincipalSignatureInvalid)"
    assert committed =~ "[7] WHAT THIS LEG ADDS"
    assert committed =~ "[8] WHAT IT STILL DOES NOT DO"
    assert committed =~ "[9] HONESTY FOOTER"

    envelope = Demo.Corpus.example!(@envelope_file)
    body = Demo.Corpus.example!(@body_file)

    # Decoded only to read the fixture's own claims — never on the trust path.
    communication = get_in(JSON.decode!(envelope), ["credentialSubject", "communication"])

    assert committed =~ "bytes               #{byte_size(envelope)}"
    assert committed =~ ~r/bytes on disk\s+#{byte_size(body)}/
    assert committed =~ communication["bodySha256"]
    assert committed =~ "envelope #{byte_size(envelope)} B, body #{byte_size(body)} B"

    # And the verifier the file names must be the one still on this machine.
    assert Demo.DeepVerifier.TsSidecar.availability() == :ok
    assert committed =~ "interpreters/typescript/dist  (inside the clone above)"
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp require_transcript!(nil) do
    flunk("""
    the :deep suite was included but the deep leg is unavailable, so no
    transcript was built. Run `mix demo.deep_verify` for the setup story.
    """)
  end

  defp require_transcript!(transcript), do: transcript

  defp find_leg(legs, name) do
    Enum.find(legs, fn leg -> String.contains?(leg, name) end) ||
      flunk("no leg block containing #{inspect(name)} in the transcript")
  end

  # The guard's voice, isolated: every line the narrative rendered as captured
  # Logger output, plus the wrapped continuations that belong to it. A log line
  # starts with "  log [" and its continuations are indented by exactly 16
  # spaces (Demo.Narrative's convention, mirrored by this task); nothing else
  # in the transcript uses that indent, and any non-matching line ends the
  # block, so a step table or a prose paragraph can never be swept in.
  defp captured_log_block(transcript) do
    continuation = String.duplicate(" ", 16)

    transcript
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {acc, in_log} ->
      cond do
        String.starts_with?(line, "  log [") -> {[line | acc], true}
        in_log and String.starts_with?(line, continuation) -> {[line | acc], true}
        true -> {acc, false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  # Replaces the one thing that MUST move between runs: the wall-clock instant,
  # which appears both on the `now` line and inside the refusal message the
  # verifier quoted it into.
  defp redact_clock(transcript),
    do: String.replace(transcript, ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z/, "<CLOCK>")
end
